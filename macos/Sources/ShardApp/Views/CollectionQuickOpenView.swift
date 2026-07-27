import AppKit
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

struct CollectionQuickOpenView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var selectedID: ExplorerNode.ID?
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            collectionList
            Divider()
            keyboardFooter
        }
        .frame(width: 580, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            CollectionQuickOpenKeyboardMonitor(
                moveUp: { moveSelection(.up) },
                moveDown: { moveSelection(.down) },
                open: openSelectedCollection,
                close: dismiss.callAsFunction
            )
        )
        .onAppear {
            selectFirstResult()
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
        .onChange(of: searchText) { _ in
            selectFirstResult()
        }
        .onExitCommand(perform: dismiss.callAsFunction)
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Search collections and databases…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchIsFocused)
                .onSubmit(openSelectedCollection)

            Text("⇧⌘O")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
    }

    @ViewBuilder
    private var collectionList: some View {
        if allCollections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No collections available")
                    .font(.headline)
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if filteredCollections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No matching collections")
                    .font(.headline)
                Text("Try searching by collection or database name.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredCollections, selection: $selectedID) { item in
                CollectionQuickOpenRow(
                    item: item,
                    isSelected: selectedID == item.id
                )
                .tag(item.id)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        open(item)
                    }
                )
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 44)
            .accessibilityLabel("Collections")
        }
    }

    private var keyboardFooter: some View {
        HStack {
            Label("Navigate", systemImage: "arrow.up.arrow.down")
            Spacer()
            Label("Open", systemImage: "return")
            Spacer()
            Text("esc  Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var allCollections: [CollectionQuickOpenItem] {
        collectionItems(in: model.explorerNodes)
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.database.localizedCaseInsensitiveCompare($1.database) == .orderedAscending
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func collectionItems(
        in nodes: [ExplorerNode],
        database: String? = nil
    ) -> [CollectionQuickOpenItem] {
        nodes.flatMap { node -> [CollectionQuickOpenItem] in
            switch node.kind {
            case .database:
                return collectionItems(in: node.children ?? [], database: node.name)
            case .collection:
                guard let database else { return [] }
                return [CollectionQuickOpenItem(node: node, database: database)]
            case .connection, .category:
                return collectionItems(in: node.children ?? [], database: database)
            }
        }
    }

    private var filteredCollections: [CollectionQuickOpenItem] {
        guard !searchText.isEmpty else { return allCollections }
        return allCollections.compactMap { item -> (
            item: CollectionQuickOpenItem,
            score: Int
        )? in
            let collectionScore = FuzzyMatcher.score(
                query: searchText,
                candidate: item.name
            )
            let databaseScore = FuzzyMatcher.score(
                query: searchText,
                candidate: item.database
            ).map { $0 - 1_000 }
            guard let score = [collectionScore, databaseScore]
                .compactMap({ $0 })
                .max() else {
                return nil
            }
            return (item, score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.item.name.localizedCaseInsensitiveCompare(
                    $1.item.name
                ) == .orderedAscending
            }
            return $0.score > $1.score
        }
        .map(\.item)
    }

    private var emptyMessage: String {
        model.connectionState.isConnected
            ? "Refresh the database sidebar to load collections."
            : "Connect to a MongoDB server to search its collections."
    }

    private func selectFirstResult() {
        selectedID = filteredCollections.first?.id
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredCollections.isEmpty else { return }
        let currentIndex = selectedID.flatMap { selectedID in
            filteredCollections.firstIndex { $0.id == selectedID }
        } ?? 0

        switch direction {
        case .up:
            selectedID = filteredCollections[max(0, currentIndex - 1)].id
        case .down:
            selectedID = filteredCollections[
                min(filteredCollections.count - 1, currentIndex + 1)
            ].id
        default:
            break
        }
    }

    private func openSelectedCollection() {
        guard let selectedID,
              let item = filteredCollections.first(where: { $0.id == selectedID })
        else { return }
        open(item)
    }

    private func open(_ item: CollectionQuickOpenItem) {
        model.openCollection(item.node)
        dismiss()
    }
}

private struct CollectionQuickOpenKeyboardMonitor: NSViewRepresentable {
    let moveUp: () -> Void
    let moveDown: () -> Void
    let open: () -> Void
    let close: () -> Void

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
        var parent: CollectionQuickOpenKeyboardMonitor
        private var monitor: Any?

        init(parent: CollectionQuickOpenKeyboardMonitor) {
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
                let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
                guard event.modifierFlags.intersection(blockedModifiers).isEmpty else {
                    return event
                }

                switch event.keyCode {
                case 126:
                    parent.moveUp()
                case 125:
                    parent.moveDown()
                case 36, 76:
                    parent.open()
                case 53:
                    parent.close()
                default:
                    return event
                }
                return nil
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

private struct CollectionQuickOpenItem: Identifiable {
    let node: ExplorerNode
    let database: String

    var id: ExplorerNode.ID { node.id }
    var name: String { node.name }
}

private struct CollectionQuickOpenRow: View {
    let item: CollectionQuickOpenItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tablecells")
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.database)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Image(systemName: "return")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.database) database")
        .accessibilityHint("Press Return to open and run the collection query")
    }
}
