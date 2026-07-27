#if canImport(ShardCore)
import ShardCore
#endif
import Foundation
import SwiftUI

struct DatabaseSidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @State private var recentsExpanded = false
    @State private var savedQueriesExpanded = false
    @State private var showingClearRecentsConfirmation = false
    @State private var showingClearSavedQueriesConfirmation = false
    @State private var favoriteRenameTarget: FavoriteQuery?
    @State private var favoriteRenameText = ""

    var body: some View {
        VStack(spacing: 0) {
            explorerContent
            Divider()
            sidebarFooter
        }
        .background(sidebarBackground)
        .alert("Clear Recent Queries?", isPresented: $showingClearRecentsConfirmation) {
            Button("Clear Recents", role: .destructive) {
                model.clearQueryHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all locally stored query history.")
        }
        .alert(
            "Clear Saved Queries?",
            isPresented: $showingClearSavedQueriesConfirmation
        ) {
            Button("Clear Saved Queries", role: .destructive) {
                model.clearFavoriteQueries()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every starred query from Shard.")
        }
        .alert(
            "Rename Saved Query",
            isPresented: Binding(
                get: { favoriteRenameTarget != nil },
                set: { if !$0 { favoriteRenameTarget = nil } }
            )
        ) {
            TextField("Query name", text: $favoriteRenameText)
            Button("Cancel", role: .cancel) {
                favoriteRenameTarget = nil
            }
            Button("Rename") {
                guard let favorite = favoriteRenameTarget else { return }
                model.renameFavorite(favorite, to: favoriteRenameText)
                favoriteRenameTarget = nil
            }
            .disabled(
                favoriteRenameText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        } message: {
            Text("Choose a memorable name for this query.")
        }
    }

    @ViewBuilder
    private var explorerContent: some View {
        if model.connectionState.isConnected {
            if model.explorerNodes.isEmpty {
                sidebarMessage(
                    systemImage: "cylinder",
                    title: "No Databases",
                    detail: "This connection did not return any databases."
                )
            } else {
                List {
                    shortcutSections
                    Section {
                        ForEach(model.explorerNodes) { node in
                            ExplorerTreeNode(
                                node: node,
                                forceExpanded: false
                            )
                        }
                    } header: {
                        sidebarSectionHeader("Databases", systemImage: "cylinder")
                    }
                }
                .listStyle(.plain)
                .controlSize(.small)
                .environment(\.defaultMinListRowHeight, 23)
                .shardSidebarListBackground()
                .background(sidebarBackground)
                .accessibilityLabel("Database explorer")
            }
        } else if model.connectionState == .connecting {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Connecting to MongoDB")
        } else {
            sidebarMessage(
                systemImage: "externaldrive.badge.questionmark",
                title: "No Connection",
                detail: "Choose a connection above."
            )
        }
    }

    @ViewBuilder
    private var shortcutSections: some View {
        if !model.queryHistory.isEmpty {
            Section {
                ForEach(visibleRecentQueries) { run in
                    SidebarQueryShortcutRow(
                        title: queryTitle(run.script),
                        detail: "\(run.database) · \(run.startedAt.formatted(date: .omitted, time: .shortened))",
                        script: run.script,
                        systemImage: "clock",
                        isFavorite: model.isFavorite(
                            script: run.script,
                            database: run.database
                        ),
                        open: { model.openHistoryRun(run) },
                        toggleFavorite: { model.toggleFavorite(run: run) },
                        rename: nil,
                        remove: { model.removeHistoryRun(run) },
                        clearAll: {
                            showingClearRecentsConfirmation = true
                        }
                    )
                }
            } header: {
                querySectionHeader(
                    "Recents",
                    systemImage: "clock",
                    count: model.queryHistory.count,
                    isExpanded: recentsExpanded,
                    toggleExpanded: { recentsExpanded.toggle() },
                    clearAll: {
                        showingClearRecentsConfirmation = true
                    }
                )
            }
        }

        if !model.favoriteQueries.isEmpty {
            Section {
                ForEach(visibleSavedQueries) { favorite in
                    SidebarQueryShortcutRow(
                        title: favorite.title,
                        detail: favorite.database,
                        script: favorite.script,
                        systemImage: "star.fill",
                        isFavorite: true,
                        open: { model.openFavoriteQuery(favorite) },
                        toggleFavorite: {
                            model.toggleFavorite(favorite)
                        },
                        rename: {
                            favoriteRenameText = favorite.title
                            favoriteRenameTarget = favorite
                        },
                        remove: nil,
                        clearAll: {
                            showingClearSavedQueriesConfirmation = true
                        }
                    )
                }
            } header: {
                querySectionHeader(
                    "Saved Queries",
                    systemImage: "star.fill",
                    count: model.favoriteQueries.count,
                    isExpanded: savedQueriesExpanded,
                    toggleExpanded: { savedQueriesExpanded.toggle() },
                    clearAll: {
                        showingClearSavedQueriesConfirmation = true
                    }
                )
            }
        }

        if !currentSavedViews.isEmpty {
            Section {
                ForEach(currentSavedViews) { view in
                    SidebarSavedViewRow(
                        view: view,
                        open: { model.openSavedCollectionView(view) },
                        remove: { model.removeCollectionView(view) }
                    )
                }
            } header: {
                sidebarSectionHeader(
                    "Saved Views",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
        }
    }

    private var visibleRecentQueries: [QueryRun] {
        recentsExpanded
            ? model.queryHistory
            : Array(model.queryHistory.prefix(5))
    }

    private var visibleSavedQueries: [FavoriteQuery] {
        savedQueriesExpanded
            ? model.favoriteQueries
            : Array(model.favoriteQueries.prefix(5))
    }

    private func queryTitle(_ script: String) -> String {
        let pattern = #"getCollection\(\s*["']([^"']+)["']\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: script,
                  range: NSRange(script.startIndex..., in: script)
              ),
              let range = Range(match.range(at: 1), in: script) else {
            return "Query"
        }
        return String(script[range])
    }

    private func querySectionHeader(
        _ title: String,
        systemImage: String,
        count: Int,
        isExpanded: Bool,
        toggleExpanded: @escaping () -> Void,
        clearAll: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Label(title.uppercased(), systemImage: systemImage)
            Text(count.formatted())
                .foregroundStyle(ShardTheme.subtleText)
            Spacer(minLength: 4)
            if count > 5 {
                Button(isExpanded ? "Less" : "All", action: toggleExpanded)
                    .buttonStyle(.plain)
                    .foregroundStyle(ShardTheme.mutedText)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(ShardTheme.subtleText)
        .padding(.top, 5)
        .contextMenu {
            Button("Clear All", role: .destructive, action: clearAll)
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(model.connectionState.label)
                .font(.caption)
                .foregroundStyle(ShardTheme.mutedText)
                .lineLimit(1)

            Spacer(minLength: 4)

            if model.currentConnection?.isReadOnly == true {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Read-only connection")
                    .accessibilityLabel("Read-only connection")
            }

            if let connection = model.currentConnection,
               connection.effectiveEnvironment != .development {
                Text(connection.effectiveEnvironment == .production ? "PROD" : "STAGE")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(environmentColor)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(footerBackground)
        .accessibilityElement(children: .combine)
    }

    private var currentSavedViews: [SavedCollectionView] {
        guard let connectionID = model.currentConnectionID else { return [] }
        return model.savedCollectionViews.filter {
            $0.location.connectionID == connectionID
        }
    }

    private func sidebarSectionHeader(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ShardTheme.subtleText)
            .padding(.top, 5)
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

    private var sidebarBackground: Color {
        ShardTheme.sidebar
    }

    private var footerBackground: Color {
        ShardTheme.raised.opacity(0.72)
    }

    private var environmentColor: Color {
        guard let connection = model.currentConnection else { return .secondary }
        switch connection.effectiveEnvironment {
        case .development: return .green
        case .staging: return .orange
        case .production: return .red
        }
    }

    private func sidebarMessage(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(ShardTheme.subtleText)
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(ShardTheme.mutedText)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExplorerTreeNode: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @State private var isHovered = false

    let node: ExplorerNode
    let forceExpanded: Bool

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(children) { child in
                    ExplorerTreeNode(node: child, forceExpanded: forceExpanded)
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: {
                forceExpanded || model.expandedExplorerNodeIDs.contains(node.id)
            },
            set: { expanded in
                guard !forceExpanded else { return }
                let isExpanded = model.expandedExplorerNodeIDs.contains(node.id)
                guard expanded != isExpanded else { return }
                updateExpansion()
            }
        )
    }

    private var row: some View {
        Button(action: selectNode) {
            HStack(spacing: 6) {
                nodeIcon

                Text(node.name)
                    .font(node.kind == .database ? .callout.weight(.medium) : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if node.kind == .database, let count = node.children?.count {
                    Text(count, format: .number)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(ShardTheme.subtleText)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground, in: .rect(cornerRadius: 5))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            Color.accentColor.opacity(
                                contrast == .increased ? 0.5 : 0.2
                            ),
                            lineWidth: 1
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(
            EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 4)
        )
        .listRowBackground(Color.clear)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(node.name), \(accessibilityKind)")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if node.kind == .collection {
                    model.openCollection(node)
                }
            }
        )
        .contextMenu {
            contextMenu
        }
    }

    private var nodeIcon: some View {
        Image(systemName: node.systemImage)
            .font(.system(size: 12, weight: node.kind == .database ? .medium : .regular))
            .foregroundStyle(iconColor)
            .frame(width: 14)
            .accessibilityHidden(true)
    }

    private var rowBackground: Color {
        if isSelected {
            return ShardTheme.selection.opacity(
                contrast == .increased ? 1 : (colorScheme == .light ? 0.82 : 0.72)
            )
        }
        if isHovered {
            return Color.primary.opacity(contrast == .increased ? 0.1 : 0.045)
        }
        return .clear
    }

    private var iconColor: Color {
        switch node.kind {
        case .database:
            return .secondary
        case .collection:
            return isSelected ? Color.accentColor : ShardTheme.mutedText
        case .category, .connection:
            return .secondary
        }
    }

    private var isSelected: Bool {
        model.selectedExplorerNodeID == node.id
    }

    private func selectNode() {
        if reduceMotion {
            model.selectExplorerNode(node)
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                model.selectExplorerNode(node)
            }
        }
    }

    private func updateExpansion() {
        if reduceMotion {
            model.toggleExplorerNode(node)
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                model.toggleExplorerNode(node)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch node.kind {
        case .collection:
            Button("Open and Run Query") {
                model.openCollection(node)
            }
            Button("Save Query as View…") {
                model.showSavedViewEditor(for: node)
            }
            Divider()
            Button("Manage Indexes…") {
                model.showIndexManager(for: node)
            }
            Button("Collection History…") {
                model.showCollectionHistory(for: node)
            }
            Divider()
            Button("Refresh") {
                Task { await model.refreshExplorer() }
            }
        case .database:
            Button("Open Query") {
                model.selectExplorerNode(node)
            }
            Button("Refresh") {
                Task { await model.refreshExplorer() }
            }
        case .category, .connection:
            EmptyView()
        }
    }

    private var accessibilityKind: String {
        switch node.kind {
        case .database: return "database"
        case .collection: return "collection"
        case .category: return "folder"
        case .connection: return "connection"
        }
    }

    private var accessibilityHint: String {
        switch node.kind {
        case .database:
            return "Press to expand or collapse"
        case .collection:
            return "Double-click to open and run a query"
        case .category, .connection:
            return ""
        }
    }
}

private struct SidebarQueryShortcutRow: View {
    @State private var isHovered = false

    let title: String
    let detail: String
    let script: String
    let systemImage: String
    let isFavorite: Bool
    let open: () -> Void
    let toggleFavorite: () -> Void
    let rename: (() -> Void)?
    let remove: (() -> Void)?
    let clearAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isFavorite ? ShardTheme.favorite : ShardTheme.mutedText
                        )
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.callout)
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(ShardTheme.subtleText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(script)

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(isFavorite ? ShardTheme.favorite : Color.gray)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || isFavorite ? 1 : 0.55)
            .help(isFavorite ? "Remove saved query" : "Save query")
            .accessibilityLabel(
                isFavorite ? "Remove saved query" : "Save query"
            )
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
        .listRowInsets(
            EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 4)
        )
        .listRowBackground(Color.clear)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", action: open)
            if let rename {
                Button("Rename…", action: rename)
            }
            Button(
                isFavorite ? "Remove Saved Query" : "Save Query",
                action: toggleFavorite
            )
            if let remove {
                Divider()
                Button("Remove from Recents", role: .destructive, action: remove)
            }
            Divider()
            Button("Clear All", role: .destructive, action: clearAll)
        }
    }
}

private struct SidebarSavedViewRow: View {
    @State private var isHovered = false

    let view: SavedCollectionView
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(view.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(view.location.database).\(view.location.collection)")
                        .font(.caption2)
                        .foregroundStyle(ShardTheme.subtleText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isHovered {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(
            EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 4)
        )
        .listRowBackground(Color.clear)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open and Run", action: open)
            Divider()
            Button("Remove Saved View", role: .destructive, action: remove)
        }
    }
}

private extension View {
    @ViewBuilder
    func shardSidebarListBackground() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

struct SavedCollectionViewEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var script: String

    let target: AppModel.SavedViewEditorTarget

    init(target: AppModel.SavedViewEditorTarget) {
        self.target = target
        _script = State(initialValue: target.initialScript)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save Collection View")
                        .font(.headline)
                    Text("\(target.location.database).\(target.location.collection)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("For example, Failed invoices", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)

            SyntaxTextEditor(
                text: $script,
                language: .javascript,
                fontSize: 12,
                completions: model.queryEditorCompletions
            )

            Divider()

            HStack {
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save View") {
                    model.saveCollectionView(
                        title: title,
                        script: script,
                        location: target.location
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(12)
        }
        .frame(width: 650, height: 520)
    }
}

struct IndexManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var showingCreateIndex = false
    @State private var indexToDrop: DatabaseIndex?

    let target: AppModel.IndexManagerTarget

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Indexes")
                        .font(.headline)
                    Text("\(target.database).\(target.collection)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    model.loadIndexes(for: target)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingIndexes)

                Button {
                    showingCreateIndex = true
                } label: {
                    Label("Create Index", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.isLoadingIndexes ||
                    model.currentConnection?.isReadOnly == true
                )
            }
            .padding(14)

            Divider()

            if model.isLoadingIndexes && model.indexes.isEmpty {
                ProgressView("Loading indexes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.indexes) {
                    TableColumn("Name") { index in
                        HStack(spacing: 6) {
                            Image(systemName: index.name == "_id_" ? "key.fill" : "square.stack.3d.up")
                                .foregroundStyle(.secondary)
                            Text(index.name)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("Keys") { index in
                        Text(indexKeys(index))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("Options") { index in
                        Text(indexOptions(index))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("") { index in
                        Button {
                            indexToDrop = index
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(
                            index.name == "_id_" ||
                            model.currentConnection?.isReadOnly == true
                        )
                        .help(index.name == "_id_" ? "The _id index cannot be removed" : "Drop index")
                        .accessibilityLabel("Drop \(index.name) index")
                    }
                    .width(34)
                }
            }

            Divider()

            HStack {
                if model.currentConnection?.isReadOnly == true {
                    Label(
                        "Read-only connection — index changes are disabled",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 500)
        .sheet(isPresented: $showingCreateIndex) {
            CreateIndexView(target: target)
                .environmentObject(model)
        }
        .alert(
            "Drop Index?",
            isPresented: Binding(
                get: { indexToDrop != nil },
                set: { if !$0 { indexToDrop = nil } }
            )
        ) {
            Button("Drop Index", role: .destructive) {
                guard let indexToDrop else { return }
                model.dropIndex(indexToDrop, from: target)
                self.indexToDrop = nil
            }
            Button("Cancel", role: .cancel) {
                indexToDrop = nil
            }
        } message: {
            Text(
                "Dropping \(indexToDrop?.name ?? "this index") can affect query "
                    + "performance on \(target.database).\(target.collection)."
            )
        }
    }

    private func indexKeys(_ index: DatabaseIndex) -> String {
        index.keys.map { "\($0.field): \($0.direction)" }.joined(separator: ", ")
    }

    private func indexOptions(_ index: DatabaseIndex) -> String {
        var options: [String] = []
        if index.unique { options.append("Unique") }
        if index.sparse { options.append("Sparse") }
        if let seconds = index.expireAfterSeconds {
            options.append("TTL \(seconds)s")
        }
        return options.isEmpty ? "Standard" : options.joined(separator: " · ")
    }
}

private struct CreateIndexView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var field = ""
    @State private var direction = 1
    @State private var unique = false

    let target: AppModel.IndexManagerTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Index")
                .font(.headline)

            Form {
                TextField("Field", text: $field)
                Picker("Order", selection: $direction) {
                    Text("Ascending").tag(1)
                    Text("Descending").tag(-1)
                }
                Toggle("Unique values", isOn: $unique)
            }

            HStack {
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    model.createIndex(
                        for: target,
                        field: field.trimmingCharacters(in: .whitespacesAndNewlines),
                        direction: direction,
                        unique: unique
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

struct CollectionHistoryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Restorable"
        case restored = "Restored"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var selectedEntryID: CollectionHistoryEntry.ID?
    @State private var searchText = ""
    @State private var filter = Filter.all
    @State private var entryToRestore: CollectionHistoryEntry?
    @State private var showingClearConfirmation = false
    @State private var selectedDocumentIndex = 0

    let target: AppModel.CollectionHistoryTarget

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                historyTable
                    .frame(minWidth: 390, idealWidth: 470)
                detail
                    .frame(minWidth: 360, idealWidth: 470)
            }
            Divider()
            footer
        }
        .frame(width: 980, height: 620)
        .onAppear {
            selectedEntryID = filteredEntries.first?.id
        }
        .onChange(of: model.collectionHistoryEntries) { _ in
            if selectedEntry == nil {
                selectedEntryID = filteredEntries.first?.id
            }
        }
        .onChange(of: selectedEntryID) { _ in
            selectedDocumentIndex = 0
        }
        .alert(
            restoreTitle,
            isPresented: Binding(
                get: { entryToRestore != nil },
                set: { if !$0 { entryToRestore = nil } }
            )
        ) {
            Button(restoreTitle) {
                guard let entryToRestore else { return }
                model.restoreCollectionHistoryEntry(entryToRestore)
                self.entryToRestore = nil
            }
            Button("Cancel", role: .cancel) {
                entryToRestore = nil
            }
        } message: {
            Text(restoreMessage)
        }
        .alert("Empty Collection History?", isPresented: $showingClearConfirmation) {
            Button("Empty History", role: .destructive) {
                model.clearCollectionHistory(for: target)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes every locally stored snapshot for "
                    + "\(target.database).\(target.collection)."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Collection History")
                    .font(.headline)
                Text("\(target.database).\(target.collection)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: 6)
            )

            Picker("History filter", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)

            Button {
                model.loadCollectionHistory(for: target)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingCollectionHistory)
        }
        .padding(14)
    }

    @ViewBuilder
    private var historyTable: some View {
        if model.isLoadingCollectionHistory && model.collectionHistoryEntries.isEmpty {
            ProgressView("Loading collection history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No Collection History")
                    .font(.headline)
                Text(
                    model.collectionHistoryEntries.isEmpty
                        ? "Edits made with Shard’s document tools will appear here."
                        : "No actions match the current filter."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(filteredEntries, selection: $selectedEntryID) {
                TableColumn("Action") { entry in
                    Label(actionTitle(entry.action), systemImage: actionSymbol(entry.action))
                        .foregroundStyle(entry.restoredAt == nil ? .primary : .secondary)
                }
                .width(min: 105, ideal: 125)

                TableColumn("Changed") { entry in
                    Text(
                        entry.occurredAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .foregroundStyle(.secondary)
                }
                .width(min: 135, ideal: 160)

                TableColumn("Docs") { entry in
                    Text(entry.documentCount.formatted())
                        .foregroundStyle(.secondary)
                }
                .width(min: 42, ideal: 48)

                TableColumn("Status") { entry in
                    Text(entry.restoredAt == nil ? "Restorable" : "Restored")
                        .foregroundStyle(entry.restoredAt == nil ? .primary : .secondary)
                }
                .width(min: 80, ideal: 90)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            VStack(spacing: 0) {
                HStack {
                    Label(
                        actionTitle(entry.action),
                        systemImage: actionSymbol(entry.action)
                    )
                    .font(.headline)
                    Spacer()
                    if let restoredAt = entry.restoredAt {
                        Text("Restored \(restoredAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if entry.documentCount > 1 {
                        documentNavigator(entry)
                    }
                }
                .padding(12)

                Divider()

                snapshotPreview(entry)

                Divider()

                HStack {
                    Button("Remove from History", role: .destructive) {
                        model.removeCollectionHistoryEntry(entry)
                    }
                    Spacer()
                    Button(restoreButtonTitle(entry.action)) {
                        entryToRestore = entry
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        entry.restoredAt != nil ||
                        entry.documentCount != 1 ||
                        model.isExecuting ||
                        model.currentConnectionID != target.connectionID ||
                        model.currentConnection?.isReadOnly == true ||
                        Self.documentID(in: entry) == nil
                    )
                    .help(
                        entry.documentCount > 1
                            ? "Grouped restore is unavailable until every document can be safely conflict-checked."
                            : ""
                    )
                }
                .padding(10)
            }
        } else {
            Text("Select an action to preview its document snapshots.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func snapshotPreview(_ entry: CollectionHistoryEntry) -> some View {
        let change = selectedDocumentChange(in: entry)
        switch entry.action {
        case .insert:
            snapshotPane(title: "Inserted document", document: change?.afterDocument)
        case .delete:
            snapshotPane(title: "Deleted document", document: change?.beforeDocument)
        case .update:
            let before = snapshotText(change?.beforeDocument)
            let after = snapshotText(change?.afterDocument)
            let diff = DocumentLineDiff(original: before, edited: after)
            HSplitView {
                snapshotPane(
                    title: "Before",
                    text: before,
                    highlights: diff.originalHighlights
                )
                snapshotPane(
                    title: "After",
                    text: after,
                    highlights: diff.editedHighlights
                )
            }
        }
    }

    private func snapshotPane(
        title: String,
        document: JSONValue?
    ) -> some View {
        snapshotPane(title: title, text: snapshotText(document))
    }

    private func snapshotPane(
        title: String,
        text: String,
        highlights: [SyntaxBackgroundHighlight] = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
            Divider()
            SyntaxTextEditor(
                text: .constant(text),
                language: .mongoShell,
                isEditable: false,
                fontSize: 11,
                backgroundHighlights: highlights
            )
        }
    }

    private var footer: some View {
        HStack {
            Text(
                "\(model.collectionHistoryEntries.count) locally stored actions · "
                    + "\(storedDocumentCount) document snapshots"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Empty History…", role: .destructive) {
                showingClearConfirmation = true
            }
            .disabled(model.collectionHistoryEntries.isEmpty)
            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private var filteredEntries: [CollectionHistoryEntry] {
        model.collectionHistoryEntries.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .active:
                matchesFilter = entry.restoredAt == nil
            case .restored:
                matchesFilter = entry.restoredAt != nil
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return actionTitle(entry.action)
                .localizedCaseInsensitiveContains(searchText)
                || entry.occurredAt.formatted()
                    .localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedEntry: CollectionHistoryEntry? {
        model.collectionHistoryEntries.first { $0.id == selectedEntryID }
    }

    private var storedDocumentCount: Int {
        model.collectionHistoryEntries.reduce(0) { $0 + $1.documentCount }
    }

    private var restoreTitle: String {
        entryToRestore.map { restoreButtonTitle($0.action) } ?? "Restore Document"
    }

    private var restoreMessage: String {
        guard let entryToRestore else { return "" }
        let action: String
        switch entryToRestore.action {
        case .insert:
            action = "remove the document inserted by this action"
        case .update:
            action = "replace the current document with the saved original"
        case .delete:
            action = "reinsert the deleted document"
        }
        return "Shard will \(action). It will stop if the live document changed after this history entry."
    }

    private func actionTitle(_ action: CollectionHistoryEntry.Action) -> String {
        switch action {
        case .insert: return "Inserted"
        case .update: return "Edited"
        case .delete: return "Deleted"
        }
    }

    private func actionSymbol(_ action: CollectionHistoryEntry.Action) -> String {
        switch action {
        case .insert: return "plus.circle"
        case .update: return "pencil.circle"
        case .delete: return "trash.circle"
        }
    }

    private func restoreButtonTitle(
        _ action: CollectionHistoryEntry.Action
    ) -> String {
        action == .insert ? "Undo Insert…" : "Restore Original…"
    }

    private static func documentID(
        in entry: CollectionHistoryEntry
    ) -> JSONValue? {
        guard entry.documentCount == 1 else { return nil }
        let change = entry.documentChanges.first
        let document = change?.afterDocument ?? change?.beforeDocument
        guard case let .object(fields) = document else { return nil }
        return fields["_id"]
    }

    private func selectedDocumentChange(
        in entry: CollectionHistoryEntry
    ) -> CollectionHistoryDocumentChange? {
        let changes = entry.documentChanges
        guard changes.indices.contains(selectedDocumentIndex) else {
            return changes.first
        }
        return changes[selectedDocumentIndex]
    }

    private func snapshotText(_ document: JSONValue?) -> String {
        document.map {
            BSONValue(extendedJSON: $0).shellFormatted
        } ?? "Snapshot unavailable"
    }

    private func documentNavigator(
        _ entry: CollectionHistoryEntry
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedDocumentIndex = max(0, selectedDocumentIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(selectedDocumentIndex == 0)

            Text("Document \(selectedDocumentIndex + 1) of \(entry.documentCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                selectedDocumentIndex = min(
                    entry.documentCount - 1,
                    selectedDocumentIndex + 1
                )
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(selectedDocumentIndex >= entry.documentCount - 1)
        }
    }
}
