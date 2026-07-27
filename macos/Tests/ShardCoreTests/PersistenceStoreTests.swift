import Foundation
import Testing
@testable import ShardCore

@Test
func newQueriesStartAtTheCollectionName() {
    let document = QueryDocument()

    #expect(document.script == #"db.getCollection("")"#)
    #expect(
        QueryDocument.newQueryCursorLocation
            == (document.script as NSString).range(of: "\"\"").location + 1
    )
}

@Test
func persistenceRoundTripsWorkspaceAndHistory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try PersistenceStore(url: directory.appendingPathComponent("test.sqlite"))
    var workspace = Workspace(name: "Test Workspace")
    workspace.selectedDatabase = "sample_mflix"
    try await store.saveWorkspace(workspace)

    let restored = try await store.loadActiveWorkspace()
    #expect(restored == workspace)

    let document = try #require(workspace.documents.first)
    let run = QueryRun(
        documentID: document.id,
        script: document.script,
        database: document.database,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        elapsedMilliseconds: 42,
        result: .array([.object(["ok": .number(1)])]),
        resultCount: 1
    )
    try await store.appendHistory(run)

    let history = try await store.loadHistory()
    #expect(history == [run])
    try await store.removeHistoryRun(id: run.id)
    #expect(try await store.loadHistory().isEmpty)
    try await store.appendHistory(run)
    try await store.clearHistory()
    #expect(try await store.loadHistory().isEmpty)

    let connectionID = UUID()
    let collectionEntry = CollectionHistoryEntry(
        connectionID: connectionID,
        database: "sample_mflix",
        collection: "movies",
        action: .update,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_050),
        beforeDocument: .object(["_id": .number(1), "title": .string("Old")]),
        afterDocument: .object(["_id": .number(1), "title": .string("New")])
    )
    try await store.saveCollectionHistoryEntry(collectionEntry)
    #expect(
        try await store.loadCollectionHistory(
            connectionID: connectionID,
            database: "sample_mflix",
            collection: "movies"
        ) == [collectionEntry]
    )

    var restoredEntry = collectionEntry
    restoredEntry.restoredAt = Date(timeIntervalSince1970: 1_700_000_075)
    try await store.saveCollectionHistoryEntry(restoredEntry)
    #expect(
        try await store.loadCollectionHistory(
            connectionID: connectionID,
            database: "sample_mflix",
            collection: "movies"
        ) == [restoredEntry]
    )
    try await store.removeCollectionHistoryEntry(id: collectionEntry.id)
    #expect(
        try await store.loadCollectionHistory(
            connectionID: connectionID,
            database: "sample_mflix",
            collection: "movies"
        ).isEmpty
    )

    let groupedEntry = CollectionHistoryEntry(
        connectionID: connectionID,
        database: "sample_mflix",
        collection: "movies",
        action: .update,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_090),
        documents: [
            CollectionHistoryDocumentChange(
                beforeDocument: .object(["_id": .number(1), "title": .string("One")]),
                afterDocument: .object(["_id": .number(1), "title": .string("First")])
            ),
            CollectionHistoryDocumentChange(
                beforeDocument: .object(["_id": .number(2), "title": .string("Two")]),
                afterDocument: .object(["_id": .number(2), "title": .string("Second")])
            )
        ]
    )
    try await store.saveCollectionHistoryEntry(groupedEntry)
    let groupedHistory = try await store.loadCollectionHistory(
        connectionID: connectionID,
        database: "sample_mflix",
        collection: "movies"
    )
    #expect(groupedHistory == [groupedEntry])
    #expect(groupedHistory.first?.documentCount == 2)

    let favorite = FavoriteQuery(
        title: "Movies",
        script: #"db.getCollection("movies").find({})"#,
        database: "sample_mflix",
        collectionName: "movies",
        createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await store.saveFavoriteQueries([favorite])
    #expect(try await store.loadFavoriteQueries() == [favorite])

    let location = CollectionLocation(
        connectionID: connectionID,
        database: "sample_mflix",
        collection: "movies"
    )
    let savedView = SavedCollectionView(
        location: location,
        title: "Recent movies",
        script: #"db.getCollection("movies").find({ year: { $gte: 2020 } })"#,
        createdAt: Date(timeIntervalSince1970: 1_700_000_120)
    )
    try await store.saveCollectionViews([savedView])
    #expect(try await store.loadCollectionViews() == [savedView])
}

@Test
func collectionHistoryDecodesLegacySingleDocumentEntries() throws {
    let id = UUID()
    let connectionID = UUID()
    let json = """
    {
      "id": "\(id.uuidString)",
      "connectionID": "\(connectionID.uuidString)",
      "database": "sample_mflix",
      "collection": "movies",
      "action": "update",
      "occurredAt": 0,
      "beforeDocument": {"_id": 1, "title": "Before"},
      "afterDocument": {"_id": 1, "title": "After"}
    }
    """

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let entry = try decoder.decode(
        CollectionHistoryEntry.self,
        from: Data(json.utf8)
    )

    #expect(entry.documents == nil)
    #expect(entry.documentCount == 1)
    #expect(entry.documentChanges.first?.beforeDocument == .object([
        "_id": .number(1),
        "title": .string("Before")
    ]))
}

@Test(arguments: [
    ("dvcmp", "deviceCompatibilityCatalogs"),
    ("invoice", "invoices"),
    ("pvwe", "providerWebhookEvents")
])
func fuzzyMatcherFindsCompactCollectionQueries(
    query: String,
    candidate: String
) {
    #expect(FuzzyMatcher.score(query: query, candidate: candidate) != nil)
}

@Test
func fuzzyMatcherRanksExactAndPrefixMatchesFirst() throws {
    let exact = try #require(
        FuzzyMatcher.score(query: "users", candidate: "users")
    )
    let prefix = try #require(
        FuzzyMatcher.score(query: "users", candidate: "usersArchive")
    )
    let subsequence = try #require(
        FuzzyMatcher.score(query: "users", candidate: "userEventsStore")
    )

    #expect(exact > prefix)
    #expect(prefix > subsequence)
    #expect(FuzzyMatcher.score(query: "xyz", candidate: "users") == nil)
}

@Test
func connectionProfilesDecodeBeforeSSHAuthenticationWasAdded() throws {
    var profile = ConnectionProfile()
    profile.ssh.enabled = true
    profile.ssh.authentication = .password

    let encoded = try JSONEncoder().encode(profile)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var ssh = try #require(object["ssh"] as? [String: Any])
    ssh.removeValue(forKey: "authentication")
    object["ssh"] = ssh
    object.removeValue(forKey: "environment")
    object.removeValue(forKey: "readOnly")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: legacyData)

    #expect(decoded.ssh.enabled)
    #expect(decoded.ssh.authentication == nil)
    #expect(decoded.effectiveEnvironment == .development)
    #expect(!decoded.isReadOnly)
}

@Test
func querySafetyRecognizesWritesAndHighRiskProductionQueries() {
    #expect(!QuerySafety.isMutation(#"db.getCollection("users").find({})"#))
    #expect(QuerySafety.isMutation(#"db.getCollection("users").insertOne({ name: "A" })"#))
    #expect(QuerySafety.isMutation(#"db.getCollection("users").updateMany({}, { $set: { active: true } })"#))
    #expect(!QuerySafety.requiresProductionConfirmation(
        #"db.getCollection("users").updateOne({ _id: 1 }, { $set: { active: true } })"#
    ))
    #expect(QuerySafety.requiresProductionConfirmation(
        #"db.getCollection("users").deleteMany({ inactive: true })"#
    ))
    #expect(QuerySafety.requiresProductionConfirmation("db.dropDatabase()"))
}

@Test
func explainPlanSummarizesExecutionStatsAndIndexUsage() {
    let plan = ExplainPlan(
        raw: .object([
            "queryPlanner": .object([
                "winningPlan": .object([
                    "stage": .string("FETCH"),
                    "inputStage": .object([
                        "stage": .string("IXSCAN"),
                        "indexName": .string("email_1")
                    ])
                ]),
                "rejectedPlans": .array([
                    .object(["stage": .string("COLLSCAN")])
                ])
            ]),
            "executionStats": .object([
                "executionTimeMillis": .number(7),
                "nReturned": .number(2),
                "totalDocsExamined": .number(2),
                "totalKeysExamined": .number(2)
            ])
        ])
    )

    #expect(plan.executionTimeMilliseconds == 7)
    #expect(plan.returnedDocuments == 2)
    #expect(plan.examinedDocuments == 2)
    #expect(plan.examinedKeys == 2)
    #expect(plan.indexNames == ["email_1"])
    #expect(!plan.hasCollectionScan)
    #expect(plan.rejectedPlans.count == 1)
}
