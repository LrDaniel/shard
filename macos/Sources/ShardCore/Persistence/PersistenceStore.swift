import CSQLite
import Foundation

public actor PersistenceStore {
    public enum StoreError: LocalizedError {
        case open(String)
        case execute(String)
        case encode(String)
        case decode(String)

        public var errorDescription: String? {
            switch self {
            case let .open(message): return "Could not open the workspace database: \(message)"
            case let .execute(message): return "Workspace database operation failed: \(message)"
            case let .encode(message): return "Could not encode workspace data: \(message)"
            case let .decode(message): return "Could not decode workspace data: \(message)"
            }
        }
    }

    nonisolated(unsafe) private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        database = handle
        try Self.configure(handle)
    }

    deinit {
        sqlite3_close(database)
    }

    public static func applicationStoreURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory
            .appendingPathComponent("Shard", isDirectory: true)
            .appendingPathComponent("shard.sqlite", isDirectory: false)
    }

    public func saveConnections(_ connections: [ConnectionProfile]) throws {
        try save(key: "connections", value: connections)
    }

    public func loadConnections() throws -> [ConnectionProfile] {
        try load(key: "connections") ?? []
    }

    public func saveWorkspace(_ workspace: Workspace) throws {
        try save(key: "workspace.\(workspace.id.uuidString)", value: workspace)
        try save(key: "workspace.active", value: workspace.id)
    }

    public func loadActiveWorkspace() throws -> Workspace? {
        guard let id: UUID = try load(key: "workspace.active") else {
            return nil
        }
        return try load(key: "workspace.\(id.uuidString)")
    }

    public func appendHistory(_ run: QueryRun, maximumEntries: Int = 1_000) throws {
        for id in try historyRunIDs(matching: run.queryIdentity) where id != run.id {
            try removeHistoryRun(id: id)
        }

        let data: Data
        do {
            data = try encoder.encode(run)
        } catch {
            throw StoreError.encode(error.localizedDescription)
        }

        let sql = "INSERT OR REPLACE INTO query_history(id, started_at, payload) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, run.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, run.startedAt.timeIntervalSince1970)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }

        try execute(
            """
            DELETE FROM query_history
            WHERE id NOT IN (
                SELECT id FROM query_history ORDER BY started_at DESC LIMIT \(max(1, maximumEntries))
            );
            """
        )
    }

    public func loadHistory(limit: Int = 100) throws -> [QueryRun] {
        let sql = "SELECT id, payload FROM query_history ORDER BY started_at DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }

        var runs: [QueryRun] = []
        var identities = Set<QueryIdentity>()
        var duplicateIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idBytes = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idBytes)),
                let bytes = sqlite3_column_blob(statement, 1)
            else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            do {
                let run = try decoder.decode(
                    QueryRun.self,
                    from: Data(bytes: bytes, count: count)
                )
                if identities.insert(run.queryIdentity).inserted {
                    if runs.count < max(1, limit) {
                        runs.append(run)
                    }
                } else {
                    duplicateIDs.append(id)
                }
            } catch {
                sqlite3_finalize(statement)
                throw StoreError.decode(error.localizedDescription)
            }
        }
        sqlite3_finalize(statement)
        for id in duplicateIDs {
            try removeHistoryRun(id: id)
        }
        return runs
    }

    public func removeHistoryRun(id: UUID) throws {
        let sql = "DELETE FROM query_history WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }
    }

    public func clearHistory() throws {
        try execute("DELETE FROM query_history;")
    }

    public func saveCollectionHistoryEntry(
        _ entry: CollectionHistoryEntry
    ) throws {
        let data: Data
        do {
            data = try encoder.encode(entry)
        } catch {
            throw StoreError.encode(error.localizedDescription)
        }

        let sql = """
        INSERT OR REPLACE INTO collection_history(
            id, connection_id, database_name, collection_name, occurred_at, payload
        ) VALUES (?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, entry.connectionID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, entry.database, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, entry.collection, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 5, entry.occurredAt.timeIntervalSince1970)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }
    }

    public func loadCollectionHistory(
        connectionID: UUID,
        database databaseName: String,
        collection collectionName: String
    ) throws -> [CollectionHistoryEntry] {
        let sql = """
        SELECT payload FROM collection_history
        WHERE connection_id = ? AND database_name = ? AND collection_name = ?
        ORDER BY occurred_at DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, connectionID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, databaseName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, collectionName, -1, SQLITE_TRANSIENT)

        var entries: [CollectionHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(
                bytes: bytes,
                count: Int(sqlite3_column_bytes(statement, 0))
            )
            do {
                entries.append(
                    try decoder.decode(CollectionHistoryEntry.self, from: data)
                )
            } catch {
                throw StoreError.decode(error.localizedDescription)
            }
        }
        return entries
    }

    public func removeCollectionHistoryEntry(id: UUID) throws {
        let sql = "DELETE FROM collection_history WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }
    }

    public func clearCollectionHistory(
        connectionID: UUID,
        database databaseName: String,
        collection collectionName: String
    ) throws {
        let sql = """
        DELETE FROM collection_history
        WHERE connection_id = ? AND database_name = ? AND collection_name = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, connectionID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, databaseName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, collectionName, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }
    }

    public func saveFavoriteQueries(_ favorites: [FavoriteQuery]) throws {
        try save(
            key: "query.favorites",
            value: Self.deduplicatedFavorites(favorites)
        )
    }

    public func loadFavoriteQueries() throws -> [FavoriteQuery] {
        let stored: [FavoriteQuery] = try load(key: "query.favorites") ?? []
        let favorites = Self.deduplicatedFavorites(stored)
        if favorites != stored {
            try saveFavoriteQueries(favorites)
        }
        return favorites
    }

    public func saveCollectionViews(
        _ views: [SavedCollectionView]
    ) throws {
        try save(key: "sidebar.collectionViews", value: views)
    }

    public func loadCollectionViews() throws -> [SavedCollectionView] {
        try load(key: "sidebar.collectionViews") ?? []
    }

    private static func configure(_ database: OpaquePointer) throws {
        let statements = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA foreign_keys = ON;",
            "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, payload BLOB NOT NULL);",
            """
            CREATE TABLE IF NOT EXISTS query_history (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS query_history_started_at ON query_history(started_at DESC);",
            """
            CREATE TABLE IF NOT EXISTS collection_history (
                id TEXT PRIMARY KEY,
                connection_id TEXT NOT NULL,
                database_name TEXT NOT NULL,
                collection_name TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS collection_history_target
            ON collection_history(
                connection_id, database_name, collection_name, occurred_at DESC
            );
            """,
            "PRAGMA user_version = 2;"
        ]
        for sql in statements {
            var errorMessage: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
                sqlite3_free(errorMessage)
                throw StoreError.execute(message)
            }
        }
    }

    private func save<Value: Encodable>(key: String, value: Value) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StoreError.encode(error.localizedDescription)
        }

        let sql = "INSERT OR REPLACE INTO metadata(key, payload) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }
    }

    private func load<Value: Decodable>(key: String) throws -> Value? {
        let sql = "SELECT payload FROM metadata WHERE key = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else {
            return nil
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw StoreError.decode(error.localizedDescription)
        }
    }

    private func historyRunIDs(
        matching identity: QueryIdentity
    ) throws -> [UUID] {
        let sql = "SELECT id, payload FROM query_history;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execute(lastError)
        }
        defer { sqlite3_finalize(statement) }

        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idBytes = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idBytes)),
                let bytes = sqlite3_column_blob(statement, 1)
            else { continue }
            let data = Data(
                bytes: bytes,
                count: Int(sqlite3_column_bytes(statement, 1))
            )
            do {
                if try decoder.decode(QueryRun.self, from: data).queryIdentity == identity {
                    ids.append(id)
                }
            } catch {
                throw StoreError.decode(error.localizedDescription)
            }
        }
        return ids
    }

    private static func deduplicatedFavorites(
        _ favorites: [FavoriteQuery]
    ) -> [FavoriteQuery] {
        var identities = Set<QueryIdentity>()
        return favorites.filter {
            identities.insert($0.queryIdentity).inserted
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorMessage)
            throw StoreError.execute(message)
        }
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
