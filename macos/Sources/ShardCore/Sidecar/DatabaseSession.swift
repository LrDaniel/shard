import Foundation

public struct DatabaseIndex: Identifiable, Equatable, Sendable {
    public struct Key: Equatable, Sendable {
        public let field: String
        public let direction: String

        public init(field: String, direction: String) {
            self.field = field
            self.direction = direction
        }
    }

    public let name: String
    public let keys: [Key]
    public let unique: Bool
    public let sparse: Bool
    public let expireAfterSeconds: Int?

    public var id: String { name }

    public init(
        name: String,
        keys: [Key],
        unique: Bool = false,
        sparse: Bool = false,
        expireAfterSeconds: Int? = nil
    ) {
        self.name = name
        self.keys = keys
        self.unique = unique
        self.sparse = sparse
        self.expireAfterSeconds = expireAfterSeconds
    }
}

public struct DatabaseField: Identifiable, Equatable, Sendable {
    public let path: String
    public let types: [String]
    public let elementTypes: [String]
    public let indexNames: [String]

    public var id: String { path }
    public var isIndexed: Bool { !indexNames.isEmpty }

    public init(
        path: String,
        types: [String],
        elementTypes: [String] = [],
        indexNames: [String] = []
    ) {
        self.path = path
        self.types = types
        self.elementTypes = elementTypes
        self.indexNames = indexNames
    }
}

public actor DatabaseSession {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(serverVersion: String?)
        case failed(String)
    }

    private let process: SidecarProcess
    private var state: State = .disconnected
    private var sshTunnel: SSHTunnel?

    public init(configuration: SidecarProcess.Configuration) {
        process = SidecarProcess(configuration: configuration)
    }

    public func currentState() -> State {
        state
    }

    public func connect(
        profile: ConnectionProfile,
        password: String?,
        sshPassword: String? = nil,
        sshPrivateKeyPassphrase: String? = nil,
        tlsCertificatePassphrase: String? = nil
    ) async throws {
        state = .connecting
        do {
            var runtimeProfile = profile
            if profile.ssh.enabled {
                let tunnel = SSHTunnel(
                    profile: profile,
                    password: sshPassword,
                    privateKeyPassphrase: sshPrivateKeyPassphrase
                )
                let localPort = try await tunnel.start()
                sshTunnel = tunnel
                runtimeProfile.host = "127.0.0.1"
                runtimeProfile.port = localPort
                runtimeProfile.connectionString = nil
                runtimeProfile.directConnection = true
                runtimeProfile.ssh.enabled = false
            }
            try process.start()
            let response = try await process.request(
                SidecarRequest(
                    operation: .connect,
                    payload: try Self.connectionPayload(
                        profile: runtimeProfile,
                        password: password,
                        tlsCertificatePassphrase: tlsCertificatePassphrase
                    )
                )
            )
            let version: String?
            if case let .object(result)? = response.result,
               case let .string(value)? = result["serverVersion"] {
                version = value
            } else {
                version = nil
            }
            state = .connected(serverVersion: version)
        } catch {
            state = .failed(error.localizedDescription)
            process.stop()
            sshTunnel?.stop()
            sshTunnel = nil
            throw error
        }
    }

    public func disconnect() async {
        if process.isRunning {
            _ = try? await process.request(SidecarRequest(operation: .disconnect))
        }
        process.stop()
        sshTunnel?.stop()
        sshTunnel = nil
        state = .disconnected
    }

    public func listDatabases() async throws -> [String] {
        let response = try await process.request(SidecarRequest(operation: .listDatabases))
        return Self.stringArray(from: response.result)
    }

    public func ping() async throws {
        _ = try await process.request(SidecarRequest(operation: .ping))
    }

    public func listCollections(database: String) async throws -> [String] {
        let response = try await process.request(
            SidecarRequest(
                operation: .listCollections,
                payload: .object(["database": .string(database)])
            )
        )
        return Self.stringArray(from: response.result)
    }

    public func listIndexes(
        database: String,
        collection: String
    ) async throws -> [DatabaseIndex] {
        let response = try await process.request(
            SidecarRequest(
                operation: .listIndexes,
                payload: .object([
                    "database": .string(database),
                    "collection": .string(collection)
                ])
            )
        )
        return Self.indexes(from: response.result)
    }

    public func sampleSchema(
        database: String,
        collection: String,
        sampleSize: Int = 100
    ) async throws -> [DatabaseField] {
        let response = try await process.request(
            SidecarRequest(
                operation: .sampleSchema,
                payload: .object([
                    "database": .string(database),
                    "collection": .string(collection),
                    "sampleSize": .number(Double(sampleSize))
                ])
            )
        )
        return Self.databaseFields(from: response.result)
    }

    public func createIndex(
        database: String,
        collection: String,
        field: String,
        direction: Int,
        unique: Bool
    ) async throws {
        _ = try await process.request(
            SidecarRequest(
                operation: .createIndex,
                payload: .object([
                    "database": .string(database),
                    "collection": .string(collection),
                    "keys": .array([
                        .object([
                            "field": .string(field),
                            "direction": .number(Double(direction))
                        ])
                    ]),
                    "unique": .bool(unique)
                ])
            )
        )
    }

    public func dropIndex(
        database: String,
        collection: String,
        name: String
    ) async throws {
        _ = try await process.request(
            SidecarRequest(
                operation: .dropIndex,
                payload: .object([
                    "database": .string(database),
                    "collection": .string(collection),
                    "name": .string(name)
                ])
            )
        )
    }

    public func execute(
        document: QueryDocument,
        batchSize: Int = 50
    ) async throws -> QueryRun {
        let startedAt = Date()
        let response = try await process.request(
            SidecarRequest(
                operation: .execute,
                payload: .object([
                    "database": .string(document.database),
                    "script": .string(document.script),
                    "batchSize": .number(Double(batchSize))
                ])
            )
        )
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let page = Self.cursorPage(from: response.result)
        let result = page.documents
        let count: Int?
        if case let .array(values) = result {
            count = values.count
        } else {
            count = nil
        }
        return QueryRun(
            documentID: document.id,
            script: document.script,
            database: document.database,
            startedAt: startedAt,
            elapsedMilliseconds: elapsed,
            result: result,
            resultCount: count,
            cursorID: page.cursorID,
            hasMore: page.hasMore
        )
    }

    public func explain(document: QueryDocument) async throws -> ExplainPlan {
        let response = try await process.request(
            SidecarRequest(
                operation: .explain,
                payload: .object([
                    "database": .string(document.database),
                    "script": .string(document.script)
                ])
            )
        )
        guard let result = response.result else {
            throw SidecarClientError.invalidResponse
        }
        return ExplainPlan(raw: result)
    }

    public func fetchNextPage(cursorID: String, batchSize: Int = 50) async throws -> (
        documents: JSONValue,
        cursorID: String?,
        hasMore: Bool
    ) {
        let response = try await process.request(
            SidecarRequest(
                operation: .fetchCursorPage,
                payload: .object([
                    "cursorId": .string(cursorID),
                    "batchSize": .number(Double(batchSize))
                ])
            )
        )
        let page = Self.cursorPage(from: response.result)
        return (page.documents, page.cursorID, page.hasMore)
    }

    public func autocomplete(prefix: String, database: String) async throws -> [String] {
        let response = try await process.request(
            SidecarRequest(
                operation: .autocomplete,
                payload: .object([
                    "database": .string(database),
                    "prefix": .string(prefix)
                ])
            )
        )
        return Self.stringArray(from: response.result)
    }

    public func parseShellDocument(_ source: String) async throws -> JSONValue {
        let response = try await process.request(
            SidecarRequest(
                operation: .parseShellDocument,
                payload: .object(["source": .string(source)])
            )
        )
        guard let result = response.result else {
            throw SidecarClientError.invalidResponse
        }
        return result
    }

    public func cancel() {
        // A blocking JavaScript evaluation cannot consume another protocol message.
        // Terminating this connection is the reliable fallback and does not affect
        // other open database sessions.
        process.stop()
        sshTunnel?.stop()
        sshTunnel = nil
        state = .disconnected
    }

    private static func connectionPayload(
        profile: ConnectionProfile,
        password: String?,
        tlsCertificatePassphrase: String?
    ) throws -> JSONValue {
        var object: [String: JSONValue] = [
            "profile": try JSONDecoder().decode(
                JSONValue.self,
                from: JSONEncoder().encode(profile)
            )
        ]
        if let password {
            object["password"] = .string(password)
        }
        if let tlsCertificatePassphrase {
            object["tlsCertificatePassphrase"] = .string(tlsCertificatePassphrase)
        }
        return .object(object)
    }

    private static func stringArray(from value: JSONValue?) -> [String] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            return value
        }
    }

    private static func indexes(from value: JSONValue?) -> [DatabaseIndex] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap { value in
            guard case let .object(index) = value,
                  case let .string(name)? = index["name"],
                  case let .array(keyValues)? = index["keys"] else {
                return nil
            }
            let keys = keyValues.compactMap { keyValue -> DatabaseIndex.Key? in
                guard case let .object(key) = keyValue,
                      case let .string(field)? = key["field"],
                      case let .string(direction)? = key["direction"] else {
                    return nil
                }
                return DatabaseIndex.Key(field: field, direction: direction)
            }
            let unique = index["unique"] == .bool(true)
            let sparse = index["sparse"] == .bool(true)
            let expireAfterSeconds: Int?
            if case let .number(value)? = index["expireAfterSeconds"] {
                expireAfterSeconds = Int(value)
            } else if case let .string(value)? = index["expireAfterSeconds"] {
                expireAfterSeconds = Int(value)
            } else {
                expireAfterSeconds = nil
            }
            return DatabaseIndex(
                name: name,
                keys: keys,
                unique: unique,
                sparse: sparse,
                expireAfterSeconds: expireAfterSeconds
            )
        }
    }

    private static func databaseFields(
        from value: JSONValue?
    ) -> [DatabaseField] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap { value in
            guard case let .object(field) = value,
                  case let .string(path)? = field["path"] else {
                return nil
            }
            return DatabaseField(
                path: path,
                types: stringArray(from: field["types"]),
                elementTypes: stringArray(from: field["elementTypes"]),
                indexNames: stringArray(from: field["indexNames"])
            )
        }
    }

    private static func cursorPage(from value: JSONValue?) -> (
        documents: JSONValue,
        cursorID: String?,
        hasMore: Bool
    ) {
        guard case let .object(object)? = value,
              let documents = object["documents"] else {
            return (value ?? .null, nil, false)
        }
        let cursorID: String?
        if case let .string(value)? = object["cursorId"] {
            cursorID = value
        } else {
            cursorID = nil
        }
        let hasMore: Bool
        if case let .bool(value)? = object["hasMore"] {
            hasMore = value
        } else {
            hasMore = false
        }
        return (documents, cursorID, hasMore)
    }
}
