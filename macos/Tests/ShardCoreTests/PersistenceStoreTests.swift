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

    let newerDuplicate = QueryRun(
        documentID: UUID(),
        script: "\n\(document.script)\n",
        database: document.database,
        startedAt: Date(timeIntervalSince1970: 1_700_000_001),
        elapsedMilliseconds: 21,
        result: .array([.object(["ok": .number(2)])]),
        resultCount: 1
    )
    try await store.appendHistory(newerDuplicate)
    #expect(try await store.loadHistory() == [newerDuplicate])

    try await store.removeHistoryRun(id: run.id)
    #expect(try await store.loadHistory() == [newerDuplicate])
    try await store.removeHistoryRun(id: newerDuplicate.id)
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

    let renamedDuplicate = FavoriteQuery(
        title: "Renamed duplicate",
        script: "\n\(favorite.script)\n",
        database: favorite.database,
        createdAt: Date(timeIntervalSince1970: 1_700_000_101)
    )
    try await store.saveFavoriteQueries([renamedDuplicate, favorite])
    #expect(try await store.loadFavoriteQueries() == [renamedDuplicate])

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
func queryLibraryKeepsMatchingQueriesFromDifferentConnections() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try PersistenceStore(url: directory.appendingPathComponent("test.sqlite"))
    let firstConnectionID = UUID()
    let secondConnectionID = UUID()
    let script = #"db.getCollection("orders").find({})"#
    let firstRun = QueryRun(
        connectionID: firstConnectionID,
        documentID: UUID(),
        script: script,
        database: "app",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        elapsedMilliseconds: 10,
        result: .array([])
    )
    let secondRun = QueryRun(
        connectionID: secondConnectionID,
        documentID: UUID(),
        script: script,
        database: "app",
        startedAt: Date(timeIntervalSince1970: 1_700_000_001),
        elapsedMilliseconds: 11,
        result: .array([])
    )

    try await store.appendHistory(firstRun)
    try await store.appendHistory(secondRun)
    #expect(try await store.loadHistory() == [secondRun, firstRun])

    let firstFavorite = FavoriteQuery(
        connectionID: firstConnectionID,
        title: "First orders",
        script: script,
        database: "app"
    )
    let secondFavorite = FavoriteQuery(
        connectionID: secondConnectionID,
        title: "Second orders",
        script: script,
        database: "app"
    )
    try await store.saveFavoriteQueries([firstFavorite, secondFavorite])
    #expect(try await store.loadFavoriteQueries() == [firstFavorite, secondFavorite])
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
func connectionImportMapsAuthenticationSSHAndTLS() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = directory.appendingPathComponent("connections.json")
    let fixture: [String: Any] = [
        "connections": [
            [
                "connectionName": "Imported Stage",
                "serverHost": "db.example.test",
                "serverPort": 27_018,
                "defaultDatabase": "catalog",
                "credentials": [
                    [
                        "enabled": true,
                        "userName": "reader",
                        "userPassword": "local-fixture-password",
                        "databaseName": "admin",
                        "mechanism": "SCRAM-SHA-256"
                    ]
                ],
                "ssh": [
                    "enabled": true,
                    "host": "bastion.example.test",
                    "port": 22,
                    "userName": "deploy",
                    "method": "password",
                    "userPassword": "local-fixture-ssh-password"
                ],
                "ssl": [
                    "sslEnabled": true,
                    "allowInvalidCertificates": false,
                    "allowInvalidHostnames": false
                ]
            ]
        ]
    ]
    try JSONSerialization.data(
        withJSONObject: fixture,
        options: [.prettyPrinted]
    ).write(to: configuration)

    let result = try ConnectionImportService().importConnections(
        from: configuration
    )
    let imported = try #require(result.connections.first)
    #expect(imported.profile.name == "Imported Stage")
    #expect(imported.profile.host == "db.example.test")
    #expect(imported.profile.port == 27_018)
    #expect(imported.profile.authentication == .scramSHA256)
    #expect(imported.profile.ssh.enabled)
    #expect(imported.profile.ssh.authentication == .password)
    #expect(imported.profile.tls.enabled)
    #expect(imported.secrets.mongodbPassword == "local-fixture-password")
    #expect(imported.secrets.sshPassword == "local-fixture-ssh-password")
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
