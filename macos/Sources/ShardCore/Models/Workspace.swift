import Foundation

public enum ResultViewMode: String, Codable, CaseIterable, Sendable {
    case tree
    case table
    case json
}

public struct QueryDocument: Codable, Identifiable, Equatable, Sendable {
    public static let newQueryScript = #"db.getCollection("")"#
    public static let newQueryCursorLocation =
        (newQueryScript as NSString).range(of: "\"\"").location + 1

    public let id: UUID
    public var title: String
    public var script: String
    public var database: String
    public var collectionName: String?
    public var filePath: String?
    public var isDirty: Bool

    public init(
        id: UUID = UUID(),
        title: String = "Query",
        script: String = QueryDocument.newQueryScript,
        database: String = "test",
        collectionName: String? = nil,
        filePath: String? = nil,
        isDirty: Bool = false
    ) {
        self.id = id
        self.title = title
        self.script = script
        self.database = database
        self.collectionName = collectionName
        self.filePath = filePath
        self.isDirty = isDirty
    }
}

public struct QueryRun: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let connectionID: UUID?
    public let documentID: UUID
    public let script: String
    public let database: String
    public let startedAt: Date
    public let elapsedMilliseconds: Int
    public let result: JSONValue
    public let resultCount: Int?
    public let cursorID: String?
    public let hasMore: Bool

    public var queryIdentity: QueryIdentity {
        QueryIdentity(
            script: script,
            database: database,
            connectionID: connectionID
        )
    }

    public init(
        id: UUID = UUID(),
        connectionID: UUID? = nil,
        documentID: UUID,
        script: String,
        database: String,
        startedAt: Date,
        elapsedMilliseconds: Int,
        result: JSONValue,
        resultCount: Int? = nil,
        cursorID: String? = nil,
        hasMore: Bool = false
    ) {
        self.id = id
        self.connectionID = connectionID
        self.documentID = documentID
        self.script = script
        self.database = database
        self.startedAt = startedAt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.result = result
        self.resultCount = resultCount
        self.cursorID = cursorID
        self.hasMore = hasMore
    }
}

public struct QueryIdentity: Hashable, Sendable {
    public let script: String
    public let database: String
    public let connectionID: UUID?

    public init(
        script: String,
        database: String,
        connectionID: UUID? = nil
    ) {
        self.script = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        self.connectionID = connectionID
    }
}

public struct CollectionHistoryDocumentChange: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let beforeDocument: JSONValue?
    public let afterDocument: JSONValue?

    public init(
        id: UUID = UUID(),
        beforeDocument: JSONValue? = nil,
        afterDocument: JSONValue? = nil
    ) {
        self.id = id
        self.beforeDocument = beforeDocument
        self.afterDocument = afterDocument
    }
}

public struct CollectionHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case insert
        case update
        case delete
    }

    public let id: UUID
    public let connectionID: UUID
    public let database: String
    public let collection: String
    public let action: Action
    public let occurredAt: Date
    public let beforeDocument: JSONValue?
    public let afterDocument: JSONValue?
    public let documents: [CollectionHistoryDocumentChange]?
    public var restoredAt: Date?

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        database: String,
        collection: String,
        action: Action,
        occurredAt: Date = Date(),
        beforeDocument: JSONValue? = nil,
        afterDocument: JSONValue? = nil,
        documents: [CollectionHistoryDocumentChange]? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.collection = collection
        self.action = action
        self.occurredAt = occurredAt
        self.beforeDocument = beforeDocument
        self.afterDocument = afterDocument
        self.documents = documents
        self.restoredAt = restoredAt
    }

    public var documentChanges: [CollectionHistoryDocumentChange] {
        if let documents, !documents.isEmpty {
            return documents
        }
        if beforeDocument != nil || afterDocument != nil {
            return [
                CollectionHistoryDocumentChange(
                    id: id,
                    beforeDocument: beforeDocument,
                    afterDocument: afterDocument
                )
            ]
        }
        return []
    }

    public var documentCount: Int {
        documentChanges.count
    }
}

public struct ExplainPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let raw: JSONValue
    public let executionTimeMilliseconds: Int?
    public let returnedDocuments: Int?
    public let examinedDocuments: Int?
    public let examinedKeys: Int?
    public let indexNames: [String]
    public let hasCollectionScan: Bool
    public let winningPlan: JSONValue?
    public let rejectedPlans: [JSONValue]

    public init(id: UUID = UUID(), raw: JSONValue) {
        self.id = id
        self.raw = raw

        let executionStats = Self.firstValue(
            named: "executionStats",
            in: raw
        )
        executionTimeMilliseconds = Self.integer(
            Self.firstValue(
                named: "executionTimeMillis",
                in: executionStats ?? raw
            )
        )
        returnedDocuments = Self.integer(
            Self.firstValue(named: "nReturned", in: executionStats ?? raw)
        )
        examinedDocuments = Self.integer(
            Self.firstValue(
                named: "totalDocsExamined",
                in: executionStats ?? raw
            )
        )
        examinedKeys = Self.integer(
            Self.firstValue(
                named: "totalKeysExamined",
                in: executionStats ?? raw
            )
        )

        winningPlan = Self.firstValue(named: "winningPlan", in: raw)
        let analyzedPlan = winningPlan ?? raw
        indexNames = Array(
            Set(Self.stringValues(named: "indexName", in: analyzedPlan))
        )
        .sorted()
        hasCollectionScan = Self.stringValues(
            named: "stage",
            in: analyzedPlan
        )
        .contains { $0.uppercased() == "COLLSCAN" }
        rejectedPlans = Self.arrayValues(named: "rejectedPlans", in: raw)
    }

    private static func firstValue(
        named name: String,
        in value: JSONValue
    ) -> JSONValue? {
        switch value {
        case let .array(values):
            return values.lazy.compactMap {
                firstValue(named: name, in: $0)
            }.first
        case let .object(fields):
            if let value = fields[name] {
                return value
            }
            return fields.values.lazy.compactMap {
                firstValue(named: name, in: $0)
            }.first
        default:
            return nil
        }
    }

    private static func stringValues(
        named name: String,
        in value: JSONValue
    ) -> [String] {
        switch value {
        case let .array(values):
            return values.flatMap { stringValues(named: name, in: $0) }
        case let .object(fields):
            var matches: [String] = []
            if case let .string(value) = fields[name] {
                matches.append(value)
            }
            return matches + fields.values.flatMap {
                stringValues(named: name, in: $0)
            }
        default:
            return []
        }
    }

    private static func arrayValues(
        named name: String,
        in value: JSONValue
    ) -> [JSONValue] {
        switch value {
        case let .array(values):
            return values.flatMap { arrayValues(named: name, in: $0) }
        case let .object(fields):
            var matches: [JSONValue] = []
            if case let .array(values) = fields[name] {
                matches.append(contentsOf: values)
            }
            return matches + fields.values.flatMap {
                arrayValues(named: name, in: $0)
            }
        default:
            return []
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case let .number(number):
            return Int(number)
        case let .string(string):
            return Int(string)
        case let .object(fields):
            return fields.values.lazy.compactMap(integer).first
        case .array, .bool, .null, .none:
            return nil
        }
    }
}

public struct FavoriteQuery: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var connectionID: UUID?
    public var title: String
    public var script: String
    public var database: String
    public var collectionName: String?
    public let createdAt: Date

    public var queryIdentity: QueryIdentity {
        QueryIdentity(
            script: script,
            database: database,
            connectionID: connectionID
        )
    }

    public init(
        id: UUID = UUID(),
        connectionID: UUID? = nil,
        title: String,
        script: String,
        database: String,
        collectionName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.connectionID = connectionID
        self.title = title
        self.script = script
        self.database = database
        self.collectionName = collectionName
        self.createdAt = createdAt
    }
}

public struct CollectionLocation: Codable, Identifiable, Hashable, Sendable {
    public let connectionID: UUID
    public let database: String
    public let collection: String

    public var id: String {
        "\(connectionID.uuidString)/\(database)/\(collection)"
    }

    public init(
        connectionID: UUID,
        database: String,
        collection: String
    ) {
        self.connectionID = connectionID
        self.database = database
        self.collection = collection
    }
}

public struct SavedCollectionView: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let location: CollectionLocation
    public var title: String
    public var script: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        location: CollectionLocation,
        title: String,
        script: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.location = location
        self.title = title
        self.script = script
        self.createdAt = createdAt
    }
}

public enum FuzzyMatcher {
    public static func score(
        query: String,
        candidate: String
    ) -> Int? {
        let query = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidate = candidate.lowercased()
        guard !query.isEmpty else { return 0 }

        if query == candidate {
            return 10_000
        }
        if candidate.hasPrefix(query) {
            return 8_000 - (candidate.count - query.count)
        }
        if let range = candidate.range(of: query) {
            let offset = candidate.distance(
                from: candidate.startIndex,
                to: range.lowerBound
            )
            return 6_000 - (offset * 10) - (candidate.count - query.count)
        }

        var candidateIndex = candidate.startIndex
        var previousMatch: String.Index?
        var gapCount = 0
        for character in query {
            guard let match = candidate[candidateIndex...]
                .firstIndex(of: character) else {
                return nil
            }
            if let previousMatch {
                gapCount += candidate.distance(
                    from: candidate.index(after: previousMatch),
                    to: match
                )
            }
            previousMatch = match
            candidateIndex = candidate.index(after: match)
        }
        return 4_000 - (gapCount * 20) - candidate.count
    }
}

public enum QuerySafety {
    public static func isMutation(_ script: String) -> Bool {
        script.range(
            of: #"\.(?:insertOne|insertMany|updateOne|updateMany|replaceOne|deleteOne|deleteMany|bulkWrite|findOneAndUpdate|findOneAndReplace|findOneAndDelete|createIndex|dropIndex|dropIndexes|drop|renameCollection)\s*\(|\bdb\.(?:createCollection|dropDatabase)\s*\(|\$(?:out|merge)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func requiresProductionConfirmation(_ script: String) -> Bool {
        script.range(
            of: #"\.(?:updateMany|deleteMany|drop|dropIndex|dropIndexes|renameCollection|bulkWrite)\s*\(|\bdb\.(?:dropDatabase|createCollection)\s*\(|\$(?:out|merge)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

public struct Workspace: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var connectionID: UUID?
    public var documents: [QueryDocument]
    public var selectedDocumentID: UUID?
    public var selectedDatabase: String?
    public var resultViewMode: ResultViewMode

    public init(id: UUID = UUID(), name: String = "Workspace") {
        let document = QueryDocument()
        self.id = id
        self.name = name
        connectionID = nil
        documents = [document]
        selectedDocumentID = document.id
        selectedDatabase = nil
        resultViewMode = .tree
    }
}
