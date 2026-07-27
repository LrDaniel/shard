import AppKit
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

enum ShardTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let selection = Color.accentColor
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            if model.sidebarVisible {
                DatabaseSidebarView()
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 340)
            }

            EditorWorkspaceView()
                .frame(minWidth: 470)
        }
        .toolbar {
            WorkspaceToolbar()
        }
        .background(ShardTheme.canvas)
        .background(WindowChromeConfigurator())
        .background(
            WorkspaceTabKeyboardMonitor(
                newTab: model.addQuery,
                closeTab: {
                    guard model.selectedDocument != nil else { return false }
                    model.closeSelectedQuery()
                    return true
                }
            )
        )
        .sheet(isPresented: $model.showingConnectionManager) {
            ConnectionManagerView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingConnectionEditor) {
            ConnectionEditorView(profile: ConnectionProfile()) { profile, secrets in
                model.saveConnection(profile, secrets: secrets)
            }
        }
        .sheet(isPresented: $model.showingCommandPalette) {
            CommandPaletteView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingCollectionQuickOpen) {
            CollectionQuickOpenView()
                .environmentObject(model)
        }
        .sheet(
            isPresented: $model.showingDocumentSheet,
            onDismiss: model.closeInspectedDocument
        ) {
            DocumentSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingQueryHistory) {
            QueryHistoryView()
                .environmentObject(model)
        }
        .sheet(item: $model.indexManagerTarget) { target in
            IndexManagerView(target: target)
                .environmentObject(model)
        }
        .sheet(item: $model.collectionHistoryTarget) { target in
            CollectionHistoryView(target: target)
                .environmentObject(model)
        }
        .sheet(item: $model.savedViewEditorTarget) { target in
            SavedCollectionViewEditor(target: target)
                .environmentObject(model)
        }
        .sheet(item: $model.explainPresentation) { presentation in
            ExplainPlanView(presentation: presentation)
                .environmentObject(model)
        }
        .alert(
            "Run High-Risk Production Query?",
            isPresented: Binding(
                get: { model.destructiveQueryConfirmation != nil },
                set: { if !$0 { model.cancelDestructiveQuery() } }
            )
        ) {
            Button("Run Query", role: .destructive) {
                model.confirmDestructiveQuery()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDestructiveQuery()
            }
        } message: {
            Text(
                "This query can modify many records or database structure in "
                    + "\(model.destructiveQueryConfirmation?.target ?? "the production database")."
            )
        }
        .alert(
            "Shard",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .visible
            window.toolbarStyle = .unifiedCompact
        }
    }
}

private struct WorkspaceTabKeyboardMonitor: NSViewRepresentable {
    let newTab: () -> Void
    let closeTab: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var parent: WorkspaceTabKeyboardMonitor
        private var monitor: Any?

        init(parent: WorkspaceTabKeyboardMonitor) {
            self.parent = parent
        }

        func install(for view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak view] event in
                guard let self,
                      let window = view?.window,
                      event.window === window else {
                    return event
                }
                let modifiers = event.modifierFlags.intersection(
                    .deviceIndependentFlagsMask
                )
                guard modifiers == .command else { return event }

                switch event.keyCode {
                case 17:
                    parent.newTab()
                    return nil
                case 13:
                    return parent.closeTab() ? nil : event
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

private struct WorkspaceToolbar: ToolbarContent {
    @EnvironmentObject private var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.toggleSidebar) {
                Label("Database Sidebar", systemImage: "sidebar.left")
            }
            .help(model.sidebarVisible ? "Hide database sidebar" : "Show database sidebar")

            Menu {
                if model.connections.isEmpty {
                    Button("No Saved Connections") {}
                        .disabled(true)
                } else {
                    ForEach(connectionGroups) { group in
                        Section(group.title) {
                            ForEach(group.connections) { connection in
                                Button {
                                    model.switchConnection(to: connection.id)
                                } label: {
                                    Label(
                                        connectionMenuTitle(connection),
                                        systemImage: connection.id == model.currentConnectionID
                                            ? "checkmark.circle.fill"
                                            : "server.rack"
                                    )
                                }
                            }
                        }
                    }
                }

                Divider()

                if model.connectionState.isConnected
                    || model.connectionState == .connecting {
                    Button("Disconnect", action: model.disconnect)
                    Divider()
                }

                Button("Manage Connections…") {
                    model.showingConnectionManager = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(model.currentConnection?.name ?? "No Connection")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .help("\(model.currentConnection?.name ?? "No connection") — \(model.connectionState.label)")
            .accessibilityLabel("Current connection")
            .accessibilityValue(
                "\(model.currentConnection?.name ?? "None"), \(model.connectionState.label)"
            )

            Button(action: model.showCollectionQuickOpen) {
                Label("Find Collection", systemImage: "magnifyingglass")
            }
            .disabled(!model.connectionState.isConnected)
            .help("Find collection (⇧⌘O)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.executeSelectedQuery) {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(
                model.connectionState == .disconnected ||
                model.isExecuting ||
                model.isExplaining
            )
            .help("Run query (⌘R)")

            Button(action: model.explainSelectedQuery) {
                Label("Explain", systemImage: "chart.bar.xaxis")
            }
            .disabled(
                model.connectionState == .disconnected ||
                model.isExecuting ||
                model.isExplaining
            )
            .help("Explain query performance")

            Button(action: model.stopExecution) {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!model.isExecuting)
            .help("Stop execution (⌘.)")

        }
    }

    private var environmentColor: Color {
        guard let connection = model.currentConnection else {
            return .secondary
        }
        switch connection.effectiveEnvironment {
        case .development: return .green
        case .staging: return .orange
        case .production: return .red
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }

    private var connectionGroups: [ConnectionMenuGroup] {
        ConnectionProfile.Environment.allCases.compactMap { environment in
            let connections = model.connections.filter {
                $0.effectiveEnvironment == environment
            }
            guard !connections.isEmpty else { return nil }
            return ConnectionMenuGroup(
                environment: environment,
                connections: connections
            )
        }
    }

    private func connectionMenuTitle(_ connection: ConnectionProfile) -> String {
        "\(connection.name)  ·  \(connection.host):\(connection.port)"
    }
}

private struct ConnectionMenuGroup: Identifiable {
    let environment: ConnectionProfile.Environment
    let connections: [ConnectionProfile]

    var id: ConnectionProfile.Environment { environment }

    var title: String {
        switch environment {
        case .development: return "Development"
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }
}

private struct ExplainPlanView: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: AppModel.ExplainPresentation

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                summary
                    .frame(minWidth: 330, idealWidth: 380)
                rawPlan
                    .frame(minWidth: 440, idealWidth: 560)
            }
            Divider()
            footer
        }
        .frame(width: 980, height: 620)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Explain Plan")
                    .font(.headline)
                Text(targetName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if presentation.plan.hasCollectionScan {
                Label(
                    "Collection Scan",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            } else if !presentation.plan.indexNames.isEmpty {
                Label("Index Used", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Performance")
                    .font(.headline)
                HStack(spacing: 8) {
                    metric(
                        "Execution",
                        presentation.plan.executionTimeMilliseconds,
                        suffix: " ms"
                    )
                    metric("Returned", presentation.plan.returnedDocuments)
                }
                HStack(spacing: 8) {
                    metric("Docs examined", presentation.plan.examinedDocuments)
                    metric("Keys examined", presentation.plan.examinedKeys)
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Winning Plan")
                        .font(.headline)
                    if presentation.plan.indexNames.isEmpty {
                        Text(
                            presentation.plan.hasCollectionScan
                                ? "No index was used."
                                : "MongoDB did not report an index name."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(presentation.plan.indexNames, id: \.self) { index in
                            Label(
                                index,
                                systemImage: "square.stack.3d.up.fill"
                            )
                            .font(.system(.body, design: .monospaced))
                        }
                    }
                    Text(rejectedPlanSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                recommendation
            }
            .padding(14)
        }
    }

    private var recommendation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Advisory",
                systemImage: presentation.plan.hasCollectionScan
                    ? "lightbulb.fill"
                    : "checkmark.seal"
            )
            .font(.headline)

            if presentation.plan.hasCollectionScan {
                Text(
                    "MongoDB scanned the collection. Consider an index beginning "
                        + "with fields used by the filter or sort."
                )
                .foregroundStyle(.secondary)

                if !presentation.suggestedIndexFields.isEmpty {
                    Text("Possible starting fields")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(presentation.suggestedIndexFields.joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let suggestedIndexCommand {
                    HStack {
                        Text(suggestedIndexCommand)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button {
                            copy(suggestedIndexCommand)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy suggested index command")
                    }
                    .padding(8)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: .rect(cornerRadius: 6)
                    )
                }

                Text("Shard never creates a suggested index automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "The winning plan uses an index. Review the examined-to-returned "
                        + "ratio before deciding whether further optimization is needed."
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var rawPlan: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Raw Explain Output")
                    .font(.headline)
                Spacer()
                Button {
                    copy(presentation.plan.raw.prettyPrinted)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .padding(12)
            Divider()
            SyntaxTextEditor(
                text: .constant(presentation.plan.raw.prettyPrinted),
                language: .json,
                isEditable: false,
                fontSize: 11
            )
        }
    }

    private var footer: some View {
        HStack {
            Text(
                presentation.plan.hasCollectionScan
                    ? "Suggestion only — inspect workload and existing indexes first."
                    : "Metrics come directly from MongoDB executionStats."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func metric(
        _ title: String,
        _ value: Int?,
        suffix: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted())\(suffix)" } ?? "—")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: .rect(cornerRadius: 7)
        )
    }

    private var targetName: String {
        presentation.collection.map {
            "\(presentation.database).\($0)"
        } ?? presentation.database
    }

    private var rejectedPlanSummary: String {
        let count = presentation.plan.rejectedPlans.count
        return "\(count) rejected \(count == 1 ? "plan" : "plans")"
    }

    private var suggestedIndexCommand: String? {
        guard let collection = presentation.collection,
              let firstField = presentation.suggestedIndexFields.first else {
            return nil
        }
        return "db.getCollection(\(quoted(collection))).createIndex({ \(quoted(firstField)): 1 })"
    }

    private func quoted(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
