import AppKit
import Combine
import Foundation
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum FieldQueryAction {
        case equals
        case notEquals
        case exists
        case missing
        case sortAscending
        case sortDescending
    }

    struct DestructiveQueryConfirmation: Identifiable {
        let id = UUID()
        let document: QueryDocument

        var target: String {
            document.collectionName.map {
                "\(document.database).\($0)"
            } ?? document.database
        }
    }

    struct IndexManagerTarget: Identifiable, Equatable {
        let database: String
        let collection: String

        var id: String { "\(database)/\(collection)" }
    }

    struct CollectionHistoryTarget: Identifiable, Equatable {
        let connectionID: UUID
        let database: String
        let collection: String

        var id: String {
            "\(connectionID.uuidString)/\(database)/\(collection)"
        }
    }

    struct ExplainPresentation: Identifiable, Equatable {
        let id = UUID()
        let plan: ExplainPlan
        let database: String
        let collection: String?
        let suggestedIndexFields: [String]
    }

    struct SavedViewEditorTarget: Identifiable, Equatable {
        let location: CollectionLocation
        let initialScript: String

        var id: String { location.id }
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(version: String?)
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case let .connected(version): return version.map { "MongoDB \($0)" } ?? "Connected"
            case .failed: return "Connection failed"
            }
        }

        var symbol: String {
            switch self {
            case .disconnected: return "bolt.slash"
            case .connecting: return "arrow.trianglehead.2.clockwise.rotate.90"
            case .connected: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var isConnected: Bool {
            if case .connected = self {
                return true
            }
            return false
        }
    }

    @Published var connections: [ConnectionProfile] = [ConnectionProfile()]
    @Published var selectedConnectionID: ConnectionProfile.ID?
    @Published var workspace = Workspace()
    @Published var explorerNodes: [ExplorerNode] = []
    @Published var selectedExplorerNodeID: ExplorerNode.ID?
    @Published var expandedExplorerNodeIDs: Set<ExplorerNode.ID> = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var activeRun: QueryRun?
    @Published var isExecuting = false
    @Published var sidebarVisible = true
    @Published var showingDocumentSheet = false
    @Published var inspectedDocument: JSONValue?
    @Published var inspectedDocumentID: JSONValue?
    @Published var inspectorDraft = ""
    @Published var inspectorIsEditing = false
    @Published var inspectorFocusRequest = 0
    @Published var inspectorFindRequest = 0
    @Published var queryEditorFocusDocumentID: QueryDocument.ID?
    @Published var queryEditorFocusRequest = 0
    @Published var queryEditorCursorLocation: Int?
    @Published var showingConnectionManager = true
    @Published var showingConnectionEditor = false
    @Published var showingCommandPalette = false
    @Published var showingCollectionQuickOpen = false
    @Published var showingQueryHistory = false
    @Published var queryHistory: [QueryRun] = []
    @Published var favoriteQueries: [FavoriteQuery] = []
    @Published var savedCollectionViews: [SavedCollectionView] = []
    @Published var savedViewEditorTarget: SavedViewEditorTarget?
    @Published var autocompleteSuggestions: [String] = []
    @Published var sampledFieldPaths: [String] = []
    @Published var sampledDatabaseFields: [DatabaseField] = []
    @Published var isSamplingSchema = false
    @Published var destructiveQueryConfirmation: DestructiveQueryConfirmation?
    @Published var indexManagerTarget: IndexManagerTarget?
    @Published var indexes: [DatabaseIndex] = []
    @Published var isLoadingIndexes = false
    @Published var collectionHistoryTarget: CollectionHistoryTarget?
    @Published var collectionHistoryEntries: [CollectionHistoryEntry] = []
    @Published var isLoadingCollectionHistory = false
    @Published var explainPresentation: ExplainPresentation?
    @Published var isExplaining = false
    @Published var connectionImportReport: String?
    @Published var lastError: String?

    private let persistence: PersistenceStore?
    private let secrets: KeychainStore
    private var session: DatabaseSession?
    private var connectionAttemptID = UUID()
    private var schemaSampleTarget: String?

    init() {
        secrets = KeychainStore()
        if let url = try? PersistenceStore.applicationStoreURL() {
            persistence = try? PersistenceStore(url: url)
        } else {
            persistence = nil
        }
        selectedConnectionID = connections.first?.id
        rebuildExplorer(databases: [], collections: [:])

        Task { [weak self] in
            await self?.restore()
        }
    }

    var selectedConnection: ConnectionProfile? {
        connections.first { $0.id == selectedConnectionID }
    }

    var currentConnectionID: ConnectionProfile.ID? {
        switch connectionState {
        case .connecting, .connected:
            return workspace.connectionID ?? selectedConnectionID
        case .disconnected, .failed:
            return selectedConnectionID
        }
    }

    var currentConnection: ConnectionProfile? {
        connections.first { $0.id == currentConnectionID }
    }

    var currentQueryHistory: [QueryRun] {
        guard let connectionID = currentConnectionID else { return [] }
        return queryHistory.filter { $0.connectionID == connectionID }
    }

    var currentFavoriteQueries: [FavoriteQuery] {
        guard let connectionID = currentConnectionID else { return [] }
        return favoriteQueries.filter { $0.connectionID == connectionID }
    }

    var selectedDocument: QueryDocument? {
        workspace.documents.first { $0.id == workspace.selectedDocumentID }
    }

    var selectedDocumentBinding: Binding<QueryDocument>? {
        guard let id = workspace.selectedDocumentID,
              workspace.documents.contains(where: { $0.id == id }) else {
            return nil
        }
        return Binding(
            get: { [weak self] in
                self?.workspace.documents.first(where: { $0.id == id }) ?? QueryDocument()
            },
            set: { [weak self] document in
                guard let self,
                      let currentIndex = self.workspace.documents.firstIndex(where: { $0.id == id })
                else { return }
                self.workspace.documents[currentIndex] = document
                self.workspace.documents[currentIndex].isDirty = true
                self.saveWorkspace()
            }
        )
    }

    var queryEditorCompletions: [String] {
        let schemaCompletions = sampledDatabaseFields.flatMap {
            Self.completions(for: $0)
        }
        return Array(
            Set(
                autocompleteSuggestions
                    + sampledFieldPaths
                    + schemaCompletions
                    + Self.mongoShellCompletions
            )
        )
        .sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func addQuery() {
        let number = workspace.documents.count + 1
        let document = QueryDocument(
            title: "Query \(number)",
            database: workspace.selectedDatabase ?? selectedConnection?.defaultDatabase ?? "test"
        )
        workspace.documents.append(document)
        workspace.selectedDocumentID = document.id
        queryEditorFocusDocumentID = document.id
        queryEditorCursorLocation = QueryDocument.newQueryCursorLocation
        queryEditorFocusRequest += 1
        clearSampledSchema()
        saveWorkspace()
    }

    func selectQuery(_ id: QueryDocument.ID) {
        workspace.selectedDocumentID = id
        guard let document = selectedDocument,
              let collection = document.collectionName
                ?? collectionName(in: document.script) else {
            clearSampledSchema()
            return
        }
        loadCollectionSchema(
            database: document.database,
            collection: collection
        )
    }

    func refreshSelectedQuerySchema() {
        guard let document = selectedDocument,
              let collection = document.collectionName
                ?? collectionName(in: document.script) else {
            return
        }
        loadCollectionSchema(
            database: document.database,
            collection: collection,
            force: true
        )
    }

    func showCollectionQuickOpen() {
        showingCollectionQuickOpen = true
        if connectionState.isConnected, explorerNodes.isEmpty {
            Task { await refreshExplorer() }
        }
    }

    func showQueryHistory() {
        showingQueryHistory = true
    }

    func showIndexManager(for node: ExplorerNode) {
        guard node.kind == .collection else { return }
        let parts = node.id.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        let target = IndexManagerTarget(
            database: parts[1],
            collection: parts[2]
        )
        indexes = []
        indexManagerTarget = target
        loadIndexes(for: target)
    }

    func showCollectionHistory(for node: ExplorerNode) {
        guard node.kind == .collection,
              let connectionID = currentConnectionID else {
            return
        }
        let parts = node.id.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        let target = CollectionHistoryTarget(
            connectionID: connectionID,
            database: parts[1],
            collection: parts[2]
        )
        collectionHistoryEntries = []
        collectionHistoryTarget = target
        loadCollectionHistory(for: target)
    }

    func loadCollectionHistory(for target: CollectionHistoryTarget) {
        guard let persistence else { return }
        isLoadingCollectionHistory = true
        Task {
            do {
                let entries = try await persistence.loadCollectionHistory(
                    connectionID: target.connectionID,
                    database: target.database,
                    collection: target.collection
                )
                if collectionHistoryTarget == target {
                    collectionHistoryEntries = entries
                }
            } catch {
                lastError = error.localizedDescription
            }
            isLoadingCollectionHistory = false
        }
    }

    func removeCollectionHistoryEntry(_ entry: CollectionHistoryEntry) {
        collectionHistoryEntries.removeAll { $0.id == entry.id }
        Task {
            do {
                try await persistence?.removeCollectionHistoryEntry(id: entry.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearCollectionHistory(for target: CollectionHistoryTarget) {
        collectionHistoryEntries = []
        Task {
            do {
                try await persistence?.clearCollectionHistory(
                    connectionID: target.connectionID,
                    database: target.database,
                    collection: target.collection
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func restoreCollectionHistoryEntry(_ entry: CollectionHistoryEntry) {
        guard entry.restoredAt == nil,
              entry.connectionID == currentConnectionID,
              allowDocumentMutation(),
              let session else {
            return
        }
        isExecuting = true
        lastError = nil
        Task {
            do {
                let current = try await currentDocument(
                    for: entry,
                    session: session
                )
                let script = try restorationScript(for: entry, current: current)
                _ = try await session.execute(
                    document: QueryDocument(
                        title: "Restore Collection History",
                        script: script,
                        database: entry.database,
                        collectionName: entry.collection
                    )
                )
                var restoredEntry = entry
                restoredEntry.restoredAt = Date()
                try await persistence?.saveCollectionHistoryEntry(restoredEntry)
                if let index = collectionHistoryEntries.firstIndex(where: {
                    $0.id == restoredEntry.id
                }) {
                    collectionHistoryEntries[index] = restoredEntry
                }
                if let selectedDocument,
                   selectedDocument.database == entry.database,
                   selectedDocument.collectionName == entry.collection {
                    activeRun = try await session.execute(document: selectedDocument)
                }
            } catch {
                lastError = error.localizedDescription
            }
            isExecuting = false
        }
    }

    func loadIndexes(for target: IndexManagerTarget) {
        guard let session else {
            lastError = "Connect to MongoDB before viewing indexes."
            return
        }
        isLoadingIndexes = true
        Task {
            do {
                let values = try await session.listIndexes(
                    database: target.database,
                    collection: target.collection
                )
                if indexManagerTarget == target {
                    indexes = values
                }
            } catch {
                lastError = error.localizedDescription
            }
            isLoadingIndexes = false
        }
    }

    func createIndex(
        for target: IndexManagerTarget,
        field: String,
        direction: Int,
        unique: Bool
    ) {
        guard allowDocumentMutation(), let session else { return }
        isLoadingIndexes = true
        Task {
            do {
                try await session.createIndex(
                    database: target.database,
                    collection: target.collection,
                    field: field,
                    direction: direction,
                    unique: unique
                )
                indexes = try await session.listIndexes(
                    database: target.database,
                    collection: target.collection
                )
            } catch {
                lastError = error.localizedDescription
            }
            isLoadingIndexes = false
        }
    }

    func dropIndex(_ index: DatabaseIndex, from target: IndexManagerTarget) {
        guard index.name != "_id_", allowDocumentMutation(), let session else {
            return
        }
        isLoadingIndexes = true
        Task {
            do {
                try await session.dropIndex(
                    database: target.database,
                    collection: target.collection,
                    name: index.name
                )
                indexes = try await session.listIndexes(
                    database: target.database,
                    collection: target.collection
                )
            } catch {
                lastError = error.localizedDescription
            }
            isLoadingIndexes = false
        }
    }

    func openHistoryRun(_ run: QueryRun) {
        openGeneratedQuery(
            title: "History",
            script: run.script,
            database: run.database,
            collection: collectionName(in: run.script),
            execute: false
        )
        showingQueryHistory = false
    }

    func removeHistoryRun(_ run: QueryRun) {
        queryHistory.removeAll { $0.id == run.id }
        Task {
            do {
                try await persistence?.removeHistoryRun(id: run.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearQueryHistory() {
        guard let connectionID = currentConnectionID else { return }
        let removedRuns = queryHistory.filter { $0.connectionID == connectionID }
        queryHistory.removeAll { $0.connectionID == connectionID }
        Task {
            do {
                for run in removedRuns {
                    try await persistence?.removeHistoryRun(id: run.id)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openFavoriteQuery(_ favorite: FavoriteQuery) {
        openGeneratedQuery(
            title: favorite.title,
            script: favorite.script,
            database: favorite.database,
            collection: favorite.collectionName,
            execute: false
        )
        showingQueryHistory = false
    }

    func toggleFavorite(run: QueryRun) {
        toggleFavorite(
            title: collectionName(in: run.script) ?? "Saved Query",
            script: run.script,
            database: run.database,
            collection: collectionName(in: run.script)
        )
    }

    func toggleFavorite(_ favorite: FavoriteQuery) {
        toggleFavorite(
            title: favorite.title,
            script: favorite.script,
            database: favorite.database,
            collection: favorite.collectionName
        )
    }

    func renameFavorite(_ favorite: FavoriteQuery, to proposedTitle: String) {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let index = favoriteQueries.firstIndex(where: { $0.id == favorite.id })
        else {
            return
        }
        favoriteQueries[index].title = title
        persistFavoriteQueries()
    }

    func clearFavoriteQueries() {
        guard let connectionID = currentConnectionID else { return }
        favoriteQueries.removeAll { $0.connectionID == connectionID }
        persistFavoriteQueries()
    }

    func toggleSelectedQueryFavorite() {
        guard let document = selectedDocument else { return }
        toggleFavorite(
            title: document.collectionName ?? document.title,
            script: document.script,
            database: document.database,
            collection: document.collectionName ?? collectionName(in: document.script)
        )
    }

    func isFavorite(script: String, database: String) -> Bool {
        let identity = QueryIdentity(
            script: script,
            database: database,
            connectionID: currentConnectionID
        )
        return favoriteQueries.contains { $0.queryIdentity == identity }
    }

    func openQueryFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "js") ?? .plainText,
            .plainText
        ]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                do {
                    let script = try await Task.detached {
                        try String(contentsOf: url, encoding: .utf8)
                    }.value
                    let document = QueryDocument(
                        title: url.lastPathComponent,
                        script: script,
                        database: self?.workspace.selectedDatabase ?? "test",
                        filePath: url.path,
                        isDirty: false
                    )
                    self?.workspace.documents.append(document)
                    self?.workspace.selectedDocumentID = document.id
                    self?.saveWorkspace()
                } catch {
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func saveSelectedQuery() {
        guard let document = selectedDocument else { return }
        if let filePath = document.filePath {
            save(document, to: URL(fileURLWithPath: filePath))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        panel.nameFieldStringValue = document.title.hasSuffix(".js")
            ? document.title
            : "\(document.title).js"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.save(document, to: url)
        }
    }

    func closeQuery(_ id: QueryDocument.ID) {
        guard let index = workspace.documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasSelected = workspace.selectedDocumentID == id
        workspace.documents.remove(at: index)
        if wasSelected {
            let nextIndex = min(index, workspace.documents.count - 1)
            workspace.selectedDocumentID = nextIndex >= 0
                ? workspace.documents[nextIndex].id
                : nil
        }
        saveWorkspace()
    }

    func closeSelectedQuery() {
        guard let id = workspace.selectedDocumentID else { return }
        closeQuery(id)
    }

    func saveConnection(
        _ profile: ConnectionProfile,
        secrets connectionSecrets: ConnectionEditorSecrets
    ) {
        var saved = profile
        do {
            if let password = connectionSecrets.mongodbPassword, !password.isEmpty {
                let reference = profile.secretReference
                    ?? "connection.\(profile.id.uuidString).password"
                try secrets.set(password, for: reference)
                saved.secretReference = reference
            }
            if let password = connectionSecrets.sshPassword, !password.isEmpty {
                let reference = profile.ssh.passwordSecretReference
                    ?? "connection.\(profile.id.uuidString).ssh-password"
                try secrets.set(password, for: reference)
                saved.ssh.passwordSecretReference = reference
            }
            if let passphrase = connectionSecrets.sshPrivateKeyPassphrase,
               !passphrase.isEmpty {
                let reference = profile.ssh.privateKeyPassphraseReference
                    ?? "connection.\(profile.id.uuidString).ssh-key-passphrase"
                try secrets.set(passphrase, for: reference)
                saved.ssh.privateKeyPassphraseReference = reference
            }
            if let passphrase = connectionSecrets.tlsCertificatePassphrase,
               !passphrase.isEmpty {
                let reference = profile.tls.certificatePassphraseReference
                    ?? "connection.\(profile.id.uuidString).tls-passphrase"
                try secrets.set(passphrase, for: reference)
                saved.tls.certificatePassphraseReference = reference
            }
        } catch {
            lastError = error.localizedDescription
            return
        }

        if let index = connections.firstIndex(where: { $0.id == saved.id }) {
            connections[index] = saved
        } else {
            connections.append(saved)
        }
        selectedConnectionID = saved.id
        showingConnectionEditor = false
        persistConnections()
    }

    func importConnections() {
        let importer = ConnectionImportService()
        let configurationURL: URL
        if let discovered = importer.discoverConfiguration() {
            configurationURL = discovered
        } else {
            let panel = NSOpenPanel()
            panel.title = "Import Connections"
            panel.message = "Select a JSON connection configuration. Press ⌘⇧. to show hidden folders."
            panel.prompt = "Import"
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let selectedURL = panel.url else {
                return
            }
            configurationURL = selectedURL
        }

        do {
            let result = try importer.importConnections(from: configurationURL)
            var importedCount = 0
            var duplicateCount = 0
            var warnings = result.warnings

            for imported in result.connections {
                guard !connections.contains(where: {
                    connectionMatches($0, imported.profile)
                }) else {
                    duplicateCount += 1
                    continue
                }

                var profile = imported.profile
                do {
                    profile.secretReference = try storeImportedSecret(
                        imported.secrets.mongodbPassword,
                        reference: "connection.\(profile.id.uuidString).password"
                    )
                    profile.ssh.passwordSecretReference = try storeImportedSecret(
                        imported.secrets.sshPassword,
                        reference: "connection.\(profile.id.uuidString).ssh-password"
                    )
                    profile.ssh.privateKeyPassphraseReference = try storeImportedSecret(
                        imported.secrets.sshPrivateKeyPassphrase,
                        reference: "connection.\(profile.id.uuidString).ssh-key-passphrase"
                    )
                    profile.tls.certificatePassphraseReference = try storeImportedSecret(
                        imported.secrets.tlsCertificatePassphrase,
                        reference: "connection.\(profile.id.uuidString).tls-passphrase"
                    )
                } catch {
                    warnings.append(
                        "\(profile.name): one or more secrets could not be stored in Keychain."
                    )
                }
                connections.append(profile)
                selectedConnectionID = profile.id
                importedCount += 1
            }

            if importedCount > 0 {
                persistConnections()
            }
            connectionImportReport = importReport(
                importedCount: importedCount,
                duplicateCount: duplicateCount,
                warnings: warnings
            )
        } catch {
            connectionImportReport = error.localizedDescription
        }
    }

    func testConnection(
        _ profile: ConnectionProfile,
        secrets connectionSecrets: ConnectionEditorSecrets
    ) async throws -> String {
        let configuration = try SidecarLocator.configuration()
        let testSession = DatabaseSession(configuration: configuration)
        let mongodbPassword = try connectionSecret(
            enteredValue: connectionSecrets.mongodbPassword,
            reference: profile.secretReference
        )
        let sshPassword = try connectionSecret(
            enteredValue: connectionSecrets.sshPassword,
            reference: profile.ssh.passwordSecretReference
        )
        let sshPrivateKeyPassphrase = try connectionSecret(
            enteredValue: connectionSecrets.sshPrivateKeyPassphrase,
            reference: profile.ssh.privateKeyPassphraseReference
        )
        let tlsCertificatePassphrase = try connectionSecret(
            enteredValue: connectionSecrets.tlsCertificatePassphrase,
            reference: profile.tls.certificatePassphraseReference
        )

        do {
            try await testSession.connect(
                profile: profile,
                password: mongodbPassword,
                sshPassword: sshPassword,
                sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
                tlsCertificatePassphrase: tlsCertificatePassphrase
            )
            try await testSession.ping()
            let state = await testSession.currentState()
            await testSession.disconnect()
            if case let .connected(version) = state, let version {
                return "Connected · MongoDB \(version)"
            }
            return "Connection successful"
        } catch {
            await testSession.disconnect()
            throw error
        }
    }

    func duplicateSelectedConnection() {
        guard let id = selectedConnectionID else { return }
        duplicateConnection(id)
    }

    func duplicateConnection(_ id: ConnectionProfile.ID) {
        guard let source = connections.first(where: { $0.id == id }) else { return }
        var copy = ConnectionProfile(
            name: "\(source.name) Copy",
            host: source.host,
            port: source.port,
            defaultDatabase: source.defaultDatabase
        )
        copy.connectionString = source.connectionString
        copy.replicaSet = source.replicaSet
        copy.directConnection = source.directConnection
        copy.authentication = source.authentication
        copy.username = source.username
        copy.authenticationDatabase = source.authenticationDatabase
        copy.tls = source.tls
        copy.ssh = source.ssh
        copy.environment = source.environment
        copy.readOnly = source.readOnly
        // Secrets are deliberately not shared with a duplicate profile.
        copy.secretReference = nil
        copy.tls.certificatePassphraseReference = nil
        copy.ssh.passwordSecretReference = nil
        copy.ssh.privateKeyPassphraseReference = nil
        connections.append(copy)
        selectedConnectionID = copy.id
        persistConnections()
    }

    func deleteSelectedConnection() {
        guard let id = selectedConnectionID else { return }
        deleteConnection(id)
    }

    func deleteConnection(_ id: ConnectionProfile.ID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        let removedActiveConnection = workspace.connectionID == id
        let references = [
            connection.secretReference,
            connection.ssh.passwordSecretReference,
            connection.ssh.privateKeyPassphraseReference,
            connection.tls.certificatePassphraseReference
        ].compactMap { $0 }
        for reference in references {
            try? secrets.remove(reference)
        }
        connections.removeAll { $0.id == id }
        selectedConnectionID = connections.first?.id
        persistConnections()
        if removedActiveConnection {
            workspace.connectionID = nil
            disconnect()
            saveWorkspace()
        }
    }

    func connect() {
        guard let profile = selectedConnection else { return }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        connectionState = .connecting
        lastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try SidecarLocator.configuration()
                let databaseSession = DatabaseSession(configuration: configuration)
                let password: String?
                if let reference = profile.secretReference {
                    password = try secrets.get(reference)
                } else {
                    password = nil
                }
                let sshPassword = try profile.ssh.passwordSecretReference.flatMap {
                    try secrets.get($0)
                }
                let sshPrivateKeyPassphrase =
                    try profile.ssh.privateKeyPassphraseReference.flatMap {
                        try secrets.get($0)
                    }
                let tlsCertificatePassphrase =
                    try profile.tls.certificatePassphraseReference.flatMap {
                        try secrets.get($0)
                    }
                try await databaseSession.connect(
                    profile: profile,
                    password: password,
                    sshPassword: sshPassword,
                    sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
                    tlsCertificatePassphrase: tlsCertificatePassphrase
                )
                guard connectionAttemptID == attemptID else {
                    await databaseSession.disconnect()
                    return
                }
                session = databaseSession

                let state = await databaseSession.currentState()
                if case let .connected(version) = state {
                    connectionState = .connected(version: version)
                }
                workspace.connectionID = profile.id
                workspace.selectedDatabase = profile.defaultDatabase
                await refreshExplorer()
                showingConnectionManager = false
                saveWorkspace()
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectionState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    func disconnect() {
        connectionAttemptID = UUID()
        let current = session
        session = nil
        connectionState = .disconnected
        selectedExplorerNodeID = nil
        expandedExplorerNodeIDs.removeAll()
        clearSampledSchema()
        rebuildExplorer(databases: [], collections: [:])
        Task {
            await current?.disconnect()
        }
    }

    func switchConnection(to id: ConnectionProfile.ID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        if workspace.connectionID == id, connectionState.isConnected {
            showingConnectionManager = false
            return
        }

        disconnect()
        selectedConnectionID = id
        workspace.connectionID = id
        activeRun = nil
        closeInspectedDocument()
        saveWorkspace()
        connect()
    }

    func connectionState(for id: ConnectionProfile.ID) -> ConnectionState {
        switch connectionState {
        case .connecting, .connected:
            return id == workspace.connectionID ? connectionState : .disconnected
        case .failed:
            return id == selectedConnectionID ? connectionState : .disconnected
        case .disconnected:
            return .disconnected
        }
    }

    func disconnectConnection(_ id: ConnectionProfile.ID) {
        guard id == workspace.connectionID else { return }
        disconnect()
    }

    func refreshExplorer() async {
        guard let session else { return }
        do {
            let databases = try await session.listDatabases()
            var collections: [String: [String]] = [:]
            for database in databases {
                collections[database] = try await session.listCollections(database: database)
            }
            rebuildExplorer(databases: databases, collections: collections)
            let database = workspace.selectedDatabase
                ?? currentConnection?.defaultDatabase
                ?? databases.first
                ?? "test"
            autocompleteSuggestions = try await session.autocomplete(
                prefix: "",
                database: database
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectExplorerNode(_ node: ExplorerNode) {
        selectedExplorerNodeID = node.id
        if node.kind == .database {
            toggleExplorerNode(node)
            workspace.selectedDatabase = node.name
            updateSelectedDocumentDatabase(node.name)
        } else if node.kind == .collection {
            let parts = node.id.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            workspace.selectedDatabase = parts[1]
            updateSelectedDocumentDatabase(parts[1])
        }
    }

    func openCollection(_ node: ExplorerNode) {
        guard let location = collectionLocation(for: node) else { return }
        openCollection(location)
    }

    func openCollection(_ location: CollectionLocation) {
        guard location.connectionID == currentConnectionID else {
            lastError = "Switch to the saved collection’s connection before opening it."
            return
        }
        let script = "db.getCollection(\(quoted(location.collection))).find({})"
        selectedExplorerNodeID = "collection/\(location.database)/\(location.collection)"
        openGeneratedQuery(
            title: location.collection,
            script: script,
            database: location.database,
            collection: location.collection,
            execute: true
        )
    }

    func openSavedCollectionView(_ view: SavedCollectionView) {
        guard view.location.connectionID == currentConnectionID else {
            lastError = "Switch to the saved view’s connection before opening it."
            return
        }
        selectedExplorerNodeID =
            "collection/\(view.location.database)/\(view.location.collection)"
        openGeneratedQuery(
            title: view.title,
            script: view.script,
            database: view.location.database,
            collection: view.location.collection,
            execute: true
        )
    }

    func showSavedViewEditor(for node: ExplorerNode) {
        guard let location = collectionLocation(for: node) else { return }
        showSavedViewEditor(for: location)
    }

    func showSavedViewEditor(for location: CollectionLocation) {
        let selectedScript: String?
        if selectedDocument?.database == location.database,
           selectedDocument?.collectionName == location.collection {
            selectedScript = selectedDocument?.script
        } else {
            selectedScript = nil
        }
        savedViewEditorTarget = SavedViewEditorTarget(
            location: location,
            initialScript: selectedScript
                ?? "db.getCollection(\(quoted(location.collection))).find({})"
        )
    }

    func saveCollectionView(
        title: String,
        script: String,
        location: CollectionLocation
    ) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !script.isEmpty else { return }
        savedCollectionViews.insert(
            SavedCollectionView(
                location: location,
                title: title,
                script: script
            ),
            at: 0
        )
        persistCollectionViews()
        savedViewEditorTarget = nil
    }

    func removeCollectionView(_ view: SavedCollectionView) {
        savedCollectionViews.removeAll { $0.id == view.id }
        persistCollectionViews()
    }

    private func loadCollectionSchema(
        database: String,
        collection: String,
        force: Bool = false
    ) {
        guard let connectionID = currentConnectionID,
              let session else {
            return
        }
        let target = "\(connectionID.uuidString)/\(database)/\(collection)"
        guard force || schemaSampleTarget != target else { return }
        schemaSampleTarget = target
        sampledDatabaseFields = []
        isSamplingSchema = true
        Task {
            do {
                let fields = try await session.sampleSchema(
                    database: database,
                    collection: collection
                )
                if schemaSampleTarget == target {
                    sampledDatabaseFields = fields
                }
            } catch {
                if schemaSampleTarget == target {
                    sampledDatabaseFields = []
                }
            }
            if schemaSampleTarget == target {
                isSamplingSchema = false
            }
        }
    }

    private func clearSampledSchema() {
        schemaSampleTarget = nil
        sampledDatabaseFields = []
        isSamplingSchema = false
    }

    func openFieldQuery(
        path: String,
        value: BSONValue,
        action: FieldQueryAction
    ) {
        guard let document = selectedDocument,
              let collection = document.collectionName else {
            lastError = "Open a collection query before filtering by a field."
            return
        }

        let field = quoted(path)
        let filter: String
        let suffix: String
        switch action {
        case .equals:
            filter = "{ \(field): \(value.shellFormatted) }"
            suffix = ""
        case .notEquals:
            filter = "{ \(field): { $ne: \(value.shellFormatted) } }"
            suffix = ""
        case .exists:
            filter = "{ \(field): { $exists: true } }"
            suffix = ""
        case .missing:
            filter = "{ \(field): { $exists: false } }"
            suffix = ""
        case .sortAscending:
            filter = "{}"
            suffix = ".sort({ \(field): 1 })"
        case .sortDescending:
            filter = "{}"
            suffix = ".sort({ \(field): -1 })"
        }

        openGeneratedQuery(
            title: collection,
            script: "db.getCollection(\(quoted(collection))).find(\(filter))\(suffix)",
            database: document.database,
            collection: collection,
            execute: true
        )
    }

    func insertDocument(_ documentJSON: JSONValue) {
        guard allowDocumentMutation() else { return }
        guard let document = selectedDocument,
              let collection = document.collectionName else {
            lastError = "Open a collection query before inserting a document."
            return
        }
        switch documentJSON {
        case .object:
            let script = """
            db.getCollection(\(quoted(collection))).insertOne(
              EJSON.deserialize(\(documentJSON.prettyPrinted))
            )
            """
            executeMutation(script, database: document.database) { [weak self] run in
                self?.recordCollectionChange(
                    action: .insert,
                    database: document.database,
                    collection: collection,
                    before: nil,
                    after: Self.insertedDocument(
                        documentJSON,
                        using: run.result
                    )
                )
            }
        case let .array(documents):
            guard !documents.isEmpty,
                  documents.allSatisfy({
                      if case .object = $0 { return true }
                      return false
                  }) else {
                lastError = "Insert Many requires a non-empty array of documents."
                return
            }
            let script = """
            db.getCollection(\(quoted(collection))).insertMany(
              EJSON.deserialize(\(documentJSON.prettyPrinted))
            )
            """
            executeMutation(script, database: document.database) { [weak self] run in
                let insertedDocuments = Self.insertedDocuments(
                    documents,
                    using: run.result
                )
                self?.recordCollectionChanges(
                    action: .insert,
                    database: document.database,
                    collection: collection,
                    changes: insertedDocuments.map {
                        CollectionHistoryDocumentChange(afterDocument: $0)
                    }
                )
            }
        default:
            lastError = "Enter one document or an array of documents."
        }
    }

    func deleteDocument(_ documentJSON: JSONValue) {
        guard allowDocumentMutation() else { return }
        guard let document = selectedDocument,
              let collection = document.collectionName else {
            lastError = "Open a collection query before deleting a document."
            return
        }
        guard let identifier = Self.documentID(in: documentJSON) else {
            lastError = "This document does not have an _id field."
            return
        }
        let script = """
        db.getCollection(\(quoted(collection))).deleteOne(
          { _id: EJSON.deserialize(\(identifier.prettyPrinted)) }
        )
        """
        executeMutation(script, database: document.database) { [weak self] _ in
            self?.recordCollectionChange(
                action: .delete,
                database: document.database,
                collection: collection,
                before: documentJSON,
                after: nil
            )
            self?.inspectedDocument = nil
            self?.inspectedDocumentID = nil
            self?.inspectorDraft = ""
            self?.inspectorIsEditing = false
        }
    }

    func inspectDocument(
        _ document: JSONValue,
        editing: Bool = false
    ) {
        guard case let .object(fields) = document else { return }
        inspectedDocument = document
        inspectedDocumentID = fields["_id"]
        inspectorDraft = BSONValue(extendedJSON: document).shellFormatted
        inspectorIsEditing = editing
        inspectorFocusRequest += 1
        inspectorFindRequest = 0
        showingDocumentSheet = true
    }

    func beginEditingInspectedDocument() {
        guard let inspectedDocument else { return }
        inspectorDraft = BSONValue(extendedJSON: inspectedDocument).shellFormatted
        inspectorIsEditing = true
        inspectorFocusRequest += 1
    }

    func findInDocumentSheet() {
        guard showingDocumentSheet, inspectedDocument != nil else { return }
        inspectorFocusRequest += 1
        inspectorFindRequest += 1
    }

    func cancelEditingInspectedDocument() {
        inspectorDraft = inspectedDocument.map {
            BSONValue(extendedJSON: $0).shellFormatted
        } ?? ""
        inspectorIsEditing = false
    }

    func closeInspectedDocument() {
        showingDocumentSheet = false
        inspectedDocument = nil
        inspectedDocumentID = nil
        inspectorDraft = ""
        inspectorIsEditing = false
        inspectorFocusRequest = 0
        inspectorFindRequest = 0
    }

    func saveInspectedDocument() {
        guard allowDocumentMutation() else { return }
        guard let identifier = inspectedDocumentID,
              let original = inspectedDocument,
              let session else { return }
        let source = inspectorDraft
        Task {
            do {
                let replacement = try await session.parseShellDocument(source)
                guard case .object = replacement else {
                    lastError = "A MongoDB document must be a JSON object."
                    return
                }
                guard let document = selectedDocument,
                      let collection = document.collectionName else {
                    lastError = "Open a collection query before editing a document."
                    return
                }
                let script = """
                db.getCollection(\(quoted(collection))).replaceOne(
                  { _id: EJSON.deserialize(\(identifier.prettyPrinted)) },
                  EJSON.deserialize(\(replacement.prettyPrinted))
                )
                """
                executeMutation(script, database: document.database) { [weak self] _ in
                    self?.recordCollectionChange(
                        action: .update,
                        database: document.database,
                        collection: collection,
                        before: original,
                        after: replacement
                    )
                    self?.inspectedDocument = replacement
                    self?.inspectedDocumentID = {
                        guard case let .object(fields) = replacement else { return nil }
                        return fields["_id"]
                    }()
                    self?.inspectorDraft = BSONValue(
                        extendedJSON: replacement
                    ).shellFormatted
                    self?.inspectorIsEditing = false
                }
            } catch {
                lastError = "Invalid MongoDB document: \(error.localizedDescription)"
            }
        }
    }

    func toggleExplorerNode(_ node: ExplorerNode) {
        if expandedExplorerNodeIDs.contains(node.id) {
            expandedExplorerNodeIDs.remove(node.id)
        } else {
            expandedExplorerNodeIDs.insert(node.id)
        }
    }

    func executeSelectedQuery() {
        guard let document = selectedDocument, session != nil else {
            lastError = "Connect to a MongoDB server before running a query."
            return
        }
        if currentConnection?.isReadOnly == true,
           QuerySafety.isMutation(document.script) {
            lastError = "This connection is read-only. Write operations are blocked."
            return
        }
        if currentConnection?.effectiveEnvironment == .production,
           QuerySafety.requiresProductionConfirmation(document.script) {
            destructiveQueryConfirmation = DestructiveQueryConfirmation(
                document: document
            )
            return
        }
        execute(document)
    }

    func explainSelectedQuery() {
        guard let document = selectedDocument,
              let session else {
            lastError = "Connect to MongoDB before explaining a query."
            return
        }
        guard !QuerySafety.isMutation(document.script) else {
            lastError = "Explain is available only for read queries. Shard will never execute a write while explaining."
            return
        }
        guard document.script.range(
            of: #"\.(?:find|aggregate)\s*\("#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            lastError = "Explain currently supports find() and aggregate() queries."
            return
        }

        isExplaining = true
        lastError = nil
        Task {
            do {
                let plan = try await session.explain(document: document)
                explainPresentation = ExplainPresentation(
                    plan: plan,
                    database: document.database,
                    collection: document.collectionName
                        ?? collectionName(in: document.script),
                    suggestedIndexFields: Self.queryFieldNames(
                        in: document.script
                    )
                )
            } catch {
                lastError = error.localizedDescription
            }
            isExplaining = false
        }
    }

    func confirmDestructiveQuery() {
        guard let confirmation = destructiveQueryConfirmation else { return }
        destructiveQueryConfirmation = nil
        execute(confirmation.document)
    }

    func cancelDestructiveQuery() {
        destructiveQueryConfirmation = nil
    }

    private func execute(_ document: QueryDocument) {
        guard let session, let connectionID = currentConnectionID else { return }
        isExecuting = true
        lastError = nil

        Task {
            do {
                let unscopedRun = try await session.execute(document: document)
                guard currentConnectionID == connectionID else {
                    isExecuting = false
                    return
                }
                let run = QueryRun(
                    id: unscopedRun.id,
                    connectionID: connectionID,
                    documentID: unscopedRun.documentID,
                    script: unscopedRun.script,
                    database: unscopedRun.database,
                    startedAt: unscopedRun.startedAt,
                    elapsedMilliseconds: unscopedRun.elapsedMilliseconds,
                    result: unscopedRun.result,
                    resultCount: unscopedRun.resultCount,
                    cursorID: unscopedRun.cursorID,
                    hasMore: unscopedRun.hasMore
                )
                activeRun = run
                queryHistory.removeAll {
                    $0.queryIdentity == run.queryIdentity
                }
                queryHistory.insert(run, at: 0)
                let maximumEntries = maximumHistoryEntries
                if queryHistory.count > maximumEntries {
                    queryHistory.removeLast(queryHistory.count - maximumEntries)
                }
                try await persistence?.appendHistory(
                    run,
                    maximumEntries: maximumEntries
                )
                sampledFieldPaths = Self.fieldPaths(in: run.result)
                if let collection = document.collectionName
                    ?? collectionName(in: document.script) {
                    loadCollectionSchema(
                        database: document.database,
                        collection: collection
                    )
                }
            } catch {
                lastError = error.localizedDescription
            }
            isExecuting = false
        }
    }

    func stopExecution() {
        guard let session else { return }
        Task {
            await session.cancel()
            self.session = nil
            self.isExecuting = false
            self.connectionState = .disconnected
            self.lastError = "Execution stopped. Reconnect to create a fresh shell session."
        }
    }

    func loadMoreResults() {
        guard let run = activeRun,
              let cursorID = run.cursorID,
              let session else { return }
        isExecuting = true
        Task {
            do {
                let page = try await session.fetchNextPage(cursorID: cursorID)
                let oldDocuments: [JSONValue]
                if case let .array(values) = run.result {
                    oldDocuments = values
                } else {
                    oldDocuments = [run.result]
                }
                let newDocuments: [JSONValue]
                if case let .array(values) = page.documents {
                    newDocuments = values
                } else {
                    newDocuments = [page.documents]
                }
                activeRun = QueryRun(
                    id: run.id,
                    connectionID: run.connectionID,
                    documentID: run.documentID,
                    script: run.script,
                    database: run.database,
                    startedAt: run.startedAt,
                    elapsedMilliseconds: run.elapsedMilliseconds,
                    result: .array(oldDocuments + newDocuments),
                    resultCount: oldDocuments.count + newDocuments.count,
                    cursorID: page.cursorID,
                    hasMore: page.hasMore
                )
            } catch {
                lastError = error.localizedDescription
            }
            isExecuting = false
        }
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    private func restore() async {
        guard let persistence else { return }
        do {
            let savedConnections = try await persistence.loadConnections()
            if !savedConnections.isEmpty {
                connections = savedConnections
                selectedConnectionID = savedConnections.first?.id
            }
            if let savedWorkspace = try await persistence.loadActiveWorkspace() {
                workspace = savedWorkspace
                selectedConnectionID = savedWorkspace.connectionID ?? selectedConnectionID
            }
            let restoredConnectionID = workspace.connectionID ?? selectedConnectionID
            queryHistory = try await persistence.loadHistory(
                limit: maximumHistoryEntries
            ).map { run in
                guard run.connectionID == nil else { return run }
                return QueryRun(
                    id: run.id,
                    connectionID: restoredConnectionID,
                    documentID: run.documentID,
                    script: run.script,
                    database: run.database,
                    startedAt: run.startedAt,
                    elapsedMilliseconds: run.elapsedMilliseconds,
                    result: run.result,
                    resultCount: run.resultCount,
                    cursorID: run.cursorID,
                    hasMore: run.hasMore
                )
            }
            favoriteQueries = try await persistence.loadFavoriteQueries().map { favorite in
                guard favorite.connectionID == nil else { return favorite }
                var migrated = favorite
                migrated.connectionID = restoredConnectionID
                return migrated
            }
            savedCollectionViews = try await persistence.loadCollectionViews()
            for run in queryHistory {
                try await persistence.appendHistory(
                    run,
                    maximumEntries: maximumHistoryEntries
                )
            }
            try await persistence.saveFavoriteQueries(favoriteQueries)
            rebuildExplorer(databases: [], collections: [:])
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistConnections() {
        let value = connections
        Task {
            try? await persistence?.saveConnections(value)
        }
    }

    private func storeImportedSecret(
        _ value: String?,
        reference: String
    ) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        try secrets.set(value, for: reference)
        return reference
    }

    private func connectionMatches(
        _ lhs: ConnectionProfile,
        _ rhs: ConnectionProfile
    ) -> Bool {
        lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.port == rhs.port
            && lhs.username == rhs.username
            && lhs.authenticationDatabase == rhs.authenticationDatabase
            && lhs.authentication == rhs.authentication
            && lhs.replicaSet == rhs.replicaSet
            && lhs.ssh.enabled == rhs.ssh.enabled
            && lhs.ssh.host.localizedCaseInsensitiveCompare(rhs.ssh.host) == .orderedSame
            && lhs.ssh.port == rhs.ssh.port
    }

    private func importReport(
        importedCount: Int,
        duplicateCount: Int,
        warnings: [String]
    ) -> String {
        var lines = [
            "\(importedCount) connection\(importedCount == 1 ? "" : "s") imported."
        ]
        if duplicateCount > 0 {
            lines.append(
                "\(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s") skipped."
            )
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Review needed:")
            lines.append(contentsOf: warnings.prefix(8).map { "• \($0)" })
            if warnings.count > 8 {
                lines.append("• \(warnings.count - 8) more warning(s)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var maximumHistoryEntries: Int {
        let configured = UserDefaults.standard.integer(
            forKey: "history.maximumEntries"
        )
        return min(100, max(10, configured > 0 ? configured : 50))
    }

    private func connectionSecret(
        enteredValue: String?,
        reference: String?
    ) throws -> String? {
        if let enteredValue, !enteredValue.isEmpty {
            return enteredValue
        }
        guard let reference else { return nil }
        return try secrets.get(reference)
    }

    private func saveWorkspace() {
        let value = workspace
        Task {
            try? await persistence?.saveWorkspace(value)
        }
    }

    private func collectionLocation(
        for node: ExplorerNode
    ) -> CollectionLocation? {
        guard node.kind == .collection,
              let connectionID = currentConnectionID else {
            return nil
        }
        let parts = node.id.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return CollectionLocation(
            connectionID: connectionID,
            database: parts[1],
            collection: parts[2]
        )
    }

    private func persistCollectionViews() {
        let value = savedCollectionViews
        Task {
            try? await persistence?.saveCollectionViews(value)
        }
    }

    private func rebuildExplorer(
        databases: [String],
        collections: [String: [String]]
    ) {
        explorerNodes = databases.map { database in
            ExplorerNode(
                id: "database/\(database)",
                name: database,
                kind: .database,
                children: (collections[database] ?? []).map { collection in
                    ExplorerNode(
                        id: "collection/\(database)/\(collection)",
                        name: collection,
                        kind: .collection
                    )
                }
            )
        }
    }

    private func updateSelectedDocumentDatabase(_ database: String) {
        guard let id = workspace.selectedDocumentID,
              let index = workspace.documents.firstIndex(where: { $0.id == id }) else { return }
        workspace.documents[index].database = database
        saveWorkspace()
    }

    private func quoted(_ value: String) -> String {
        let encoded = try? JSONEncoder().encode(value)
        return encoded.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private func executeMutation(
        _ script: String,
        database: String,
        onSuccess: ((QueryRun) -> Void)? = nil
    ) {
        guard allowDocumentMutation() else { return }
        guard let session, let query = selectedDocument else { return }
        isExecuting = true
        lastError = nil
        Task {
            do {
                let mutationRun = try await session.execute(
                    document: QueryDocument(
                        title: "Document Mutation",
                        script: script,
                        database: database
                    )
                )
                activeRun = try await session.execute(document: query)
                onSuccess?(mutationRun)
            } catch {
                lastError = error.localizedDescription
            }
            isExecuting = false
        }
    }

    private func recordCollectionChange(
        action: CollectionHistoryEntry.Action,
        database: String,
        collection: String,
        before: JSONValue?,
        after: JSONValue?
    ) {
        guard let connectionID = currentConnectionID else { return }
        let entry = CollectionHistoryEntry(
            connectionID: connectionID,
            database: database,
            collection: collection,
            action: action,
            beforeDocument: before,
            afterDocument: after
        )
        if collectionHistoryTarget == CollectionHistoryTarget(
            connectionID: connectionID,
            database: database,
            collection: collection
        ) {
            collectionHistoryEntries.insert(entry, at: 0)
        }
        Task {
            do {
                try await persistence?.saveCollectionHistoryEntry(entry)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func recordCollectionChanges(
        action: CollectionHistoryEntry.Action,
        database: String,
        collection: String,
        changes: [CollectionHistoryDocumentChange]
    ) {
        guard let connectionID = currentConnectionID, !changes.isEmpty else { return }
        let entry = CollectionHistoryEntry(
            connectionID: connectionID,
            database: database,
            collection: collection,
            action: action,
            documents: changes
        )
        if collectionHistoryTarget == CollectionHistoryTarget(
            connectionID: connectionID,
            database: database,
            collection: collection
        ) {
            collectionHistoryEntries.insert(entry, at: 0)
        }
        Task {
            do {
                try await persistence?.saveCollectionHistoryEntry(entry)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func currentDocument(
        for entry: CollectionHistoryEntry,
        session: DatabaseSession
    ) async throws -> JSONValue? {
        guard entry.documentCount == 1,
              let change = entry.documentChanges.first else {
            throw CollectionHistoryRestoreError.missingSnapshot
        }
        guard let identifier = Self.documentID(
            in: change.afterDocument ?? change.beforeDocument
        ) else {
            throw CollectionHistoryRestoreError.missingIdentifier
        }
        let script = """
        db.getCollection(\(quoted(entry.collection))).findOne(
          { _id: EJSON.deserialize(\(identifier.prettyPrinted)) }
        )
        """
        let run = try await session.execute(
            document: QueryDocument(
                title: "Check Collection History",
                script: script,
                database: entry.database,
                collectionName: entry.collection
            )
        )
        if case .null = run.result {
            return nil
        }
        return run.result
    }

    private func restorationScript(
        for entry: CollectionHistoryEntry,
        current: JSONValue?
    ) throws -> String {
        guard entry.documentCount == 1,
              let change = entry.documentChanges.first else {
            throw CollectionHistoryRestoreError.missingSnapshot
        }
        switch entry.action {
        case .insert:
            guard let inserted = change.afterDocument else {
                throw CollectionHistoryRestoreError.missingSnapshot
            }
            guard current == inserted else {
                throw CollectionHistoryRestoreError.documentChanged
            }
            guard let identifier = Self.documentID(in: inserted) else {
                throw CollectionHistoryRestoreError.missingIdentifier
            }
            return """
            db.getCollection(\(quoted(entry.collection))).deleteOne(
              { _id: EJSON.deserialize(\(identifier.prettyPrinted)) }
            )
            """
        case .update:
            guard let before = change.beforeDocument,
                  let after = change.afterDocument else {
                throw CollectionHistoryRestoreError.missingSnapshot
            }
            guard current == after else {
                throw CollectionHistoryRestoreError.documentChanged
            }
            guard let identifier = Self.documentID(in: after) else {
                throw CollectionHistoryRestoreError.missingIdentifier
            }
            return """
            db.getCollection(\(quoted(entry.collection))).replaceOne(
              { _id: EJSON.deserialize(\(identifier.prettyPrinted)) },
              EJSON.deserialize(\(before.prettyPrinted))
            )
            """
        case .delete:
            guard let deleted = change.beforeDocument else {
                throw CollectionHistoryRestoreError.missingSnapshot
            }
            guard current == nil else {
                throw CollectionHistoryRestoreError.documentChanged
            }
            return """
            db.getCollection(\(quoted(entry.collection))).insertOne(
              EJSON.deserialize(\(deleted.prettyPrinted))
            )
            """
        }
    }

    private static func documentID(in document: JSONValue?) -> JSONValue? {
        guard case let .object(fields) = document else { return nil }
        return fields["_id"]
    }

    private static func insertedDocument(
        _ document: JSONValue,
        using mutationResult: JSONValue
    ) -> JSONValue {
        guard case var .object(fields) = document,
              fields["_id"] == nil,
              case let .object(resultFields) = mutationResult,
              let insertedID = resultFields["insertedId"] else {
            return document
        }
        fields["_id"] = insertedID
        return .object(fields)
    }

    private static func insertedDocuments(
        _ documents: [JSONValue],
        using mutationResult: JSONValue
    ) -> [JSONValue] {
        guard case let .object(resultFields) = mutationResult,
              case let .object(insertedIDs)? = resultFields["insertedIds"] else {
            return documents
        }
        return documents.enumerated().map { index, document in
            guard case var .object(fields) = document,
                  fields["_id"] == nil,
                  let insertedID = insertedIDs[String(index)] else {
                return document
            }
            fields["_id"] = insertedID
            return .object(fields)
        }
    }

    private func toggleFavorite(
        title: String,
        script: String,
        database: String,
        collection: String?
    ) {
        let identity = QueryIdentity(
            script: script,
            database: database,
            connectionID: currentConnectionID
        )
        if favoriteQueries.contains(where: { $0.queryIdentity == identity }) {
            favoriteQueries.removeAll { $0.queryIdentity == identity }
        } else {
            favoriteQueries.insert(
                FavoriteQuery(
                    connectionID: currentConnectionID,
                    title: title,
                    script: script,
                    database: database,
                    collectionName: collection
                ),
                at: 0
            )
        }
        persistFavoriteQueries()
    }

    private func persistFavoriteQueries() {
        let value = favoriteQueries
        Task {
            try? await persistence?.saveFavoriteQueries(value)
        }
    }

    private func openGeneratedQuery(
        title: String,
        script: String,
        database: String,
        collection: String?,
        execute shouldExecute: Bool
    ) {
        let document = QueryDocument(
            title: title,
            script: script,
            database: database,
            collectionName: collection
        )
        workspace.documents.append(document)
        workspace.selectedDocumentID = document.id
        workspace.selectedDatabase = database
        activeRun = nil
        saveWorkspace()
        if let collection {
            loadCollectionSchema(
                database: database,
                collection: collection
            )
        } else {
            clearSampledSchema()
        }
        if shouldExecute {
            executeSelectedQuery()
        }
    }

    private func allowDocumentMutation() -> Bool {
        guard currentConnection?.isReadOnly != true else {
            lastError = "This connection is read-only. Document changes are blocked."
            return false
        }
        return true
    }

    private func collectionName(in script: String) -> String? {
        let pattern = #"getCollection\(\s*["']([^"']+)["']\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: script,
                range: NSRange(script.startIndex..., in: script)
              ),
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return String(script[range])
    }

    private static func queryFieldNames(in script: String) -> [String] {
        let pattern = #"(?<![$\w])["']?([A-Za-z_][\w.]*)["']?\s*:"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        var fields: [String] = []
        let range = NSRange(script.startIndex..., in: script)
        for match in expression.matches(in: script, range: range) {
            guard let fieldRange = Range(match.range(at: 1), in: script) else {
                continue
            }
            let field = String(script[fieldRange])
            if !fields.contains(field) {
                fields.append(field)
            }
        }
        return Array(fields.prefix(4))
    }

    private static func completions(for field: DatabaseField) -> [String] {
        let path = field.path
        let types = Set(field.types + field.elementTypes)
        var values = [path, "\(path): "]

        if types.contains("ObjectId") {
            values.append("\(path): ObjectId(\"\")")
        }
        if types.contains("Date") {
            values.append("\(path): { $gte: ISODate(\"\") }")
        }
        if types.contains("String") {
            values.append(contentsOf: [
                "\(path): \"\"",
                "\(path): { $regex: \"\", $options: \"i\" }"
            ])
        }
        if types.contains("Boolean") {
            values.append("\(path): true")
        }
        if !types.isDisjoint(
            with: ["Integer", "Double", "Int32", "Long", "Decimal128"]
        ) {
            values.append("\(path): { $gte: 0 }")
        }
        if field.types.contains("Array") {
            values.append("\(path): { $elemMatch: {} }")
        }
        if field.isIndexed {
            values.append("\(path): 1")
        }
        return values
    }

    private static func fieldPaths(in value: JSONValue) -> [String] {
        var paths = Set<String>()

        func visit(_ value: JSONValue, prefix: String) {
            guard paths.count < 300 else { return }
            switch value {
            case let .array(values):
                for child in values.prefix(20) {
                    visit(child, prefix: prefix)
                }
            case let .object(fields):
                if fields.keys.contains(where: { $0.hasPrefix("$") }) {
                    return
                }
                for (key, child) in fields {
                    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                    paths.insert(path)
                    visit(child, prefix: path)
                }
            default:
                break
            }
        }

        visit(value, prefix: "")
        return paths.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static let mongoShellCompletions = [
        "ObjectId()", "ISODate()", "NumberInt()", "NumberLong()",
        "NumberDecimal()", "EJSON.serialize()", "EJSON.deserialize()",
        "db.getCollectionNames()", "db.getSiblingDB()", "db.runCommand()",
        ".find({})", ".findOne({})", ".aggregate([])", ".countDocuments({})",
        ".insertOne({})", ".updateOne({}, {})", ".deleteOne({})",
        ".sort({})", ".limit()", ".project({})", ".explain(\"executionStats\")",
        "$match", "$project", "$group", "$sort", "$limit", "$lookup",
        "$unwind", "$set", "$unset"
    ]

    private func save(_ document: QueryDocument, to url: URL) {
        Task {
            do {
                try await Task.detached {
                    try document.script.write(to: url, atomically: true, encoding: .utf8)
                }.value
                guard let index = workspace.documents.firstIndex(where: {
                    $0.id == document.id
                }) else { return }
                workspace.documents[index].filePath = url.path
                workspace.documents[index].title = url.lastPathComponent
                workspace.documents[index].isDirty = false
                saveWorkspace()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

private enum CollectionHistoryRestoreError: LocalizedError {
    case documentChanged
    case missingIdentifier
    case missingSnapshot

    var errorDescription: String? {
        switch self {
        case .documentChanged:
            return "This document changed after the recorded action. "
                + "Restore was stopped to avoid overwriting newer data."
        case .missingIdentifier:
            return "This history entry cannot be restored because its document has no _id."
        case .missingSnapshot:
            return "This history entry does not contain the document snapshot needed to restore it."
        }
    }
}
