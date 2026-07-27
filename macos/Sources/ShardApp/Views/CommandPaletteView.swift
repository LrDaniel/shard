import Foundation
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)

            Divider()

            List(filteredCommands) { command in
                Button {
                    command.action()
                    dismiss()
                } label: {
                    HStack {
                        Label(command.title, systemImage: command.systemImage)
                        Spacer()
                        Text(command.shortcut)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 360)
    }

    private var filteredCommands: [PaletteCommand] {
        commands.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var commands: [PaletteCommand] {
        [
            PaletteCommand(
                title: "New Query",
                systemImage: "terminal",
                shortcut: "⌘T",
                action: model.addQuery
            ),
            PaletteCommand(
                title: "Run Query",
                systemImage: "play.fill",
                shortcut: "⌘R",
                action: model.executeSelectedQuery
            ),
            PaletteCommand(
                title: "Quick Open Collection",
                systemImage: "magnifyingglass",
                shortcut: "⇧⌘O",
                action: model.showCollectionQuickOpen
            ),
            PaletteCommand(
                title: "Query History & Favorites",
                systemImage: "clock.arrow.circlepath",
                shortcut: "⇧⌘H",
                action: model.showQueryHistory
            ),
            PaletteCommand(
                title: "Toggle Database Sidebar",
                systemImage: "sidebar.left",
                shortcut: "⌃⌘S",
                action: model.toggleSidebar
            )
        ]
    }
}

struct QueryHistoryView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case favorites = "Favorites"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var selectedSection = Section.history
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search scripts, databases, and collections", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                Picker("Query library", selection: $selectedSection) {
                    ForEach(Section.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            .padding(12)

            Divider()

            if selectedSection == .history {
                historyList
            } else {
                favoritesList
            }

            Divider()

            HStack {
                Text(selectedSection == .history
                    ? "\(filteredHistory.count) recent queries"
                    : "\(filteredFavorites.count) saved queries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 760, height: 500)
        .onAppear {
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if filteredHistory.isEmpty {
            emptyState(
                title: "No Query History",
                detail: "Queries you run successfully appear here."
            )
        } else {
            List(filteredHistory) { run in
                queryRow(
                    title: collectionName(in: run.script) ?? "Query",
                    script: run.script,
                    database: run.database,
                    detail: "\(run.elapsedMilliseconds) ms · \(run.resultCount ?? 0) results",
                    isFavorite: model.isFavorite(
                        script: run.script,
                        database: run.database
                    ),
                    open: { model.openHistoryRun(run) },
                    toggleFavorite: { model.toggleFavorite(run: run) }
                )
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var favoritesList: some View {
        if filteredFavorites.isEmpty {
            emptyState(
                title: "No Favorite Queries",
                detail: "Use the star beside a history item to save it."
            )
        } else {
            List(filteredFavorites) { favorite in
                queryRow(
                    title: favorite.title,
                    script: favorite.script,
                    database: favorite.database,
                    detail: favorite.createdAt.formatted(date: .abbreviated, time: .shortened),
                    isFavorite: true,
                    open: { model.openFavoriteQuery(favorite) },
                    toggleFavorite: { model.toggleFavorite(favorite) }
                )
            }
            .listStyle(.inset)
        }
    }

    private func queryRow(
        title: String,
        script: String,
        database: String,
        detail: String,
        isFavorite: Bool,
        open: @escaping () -> Void,
        toggleFavorite: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title)
                            .font(.body.weight(.medium))
                        Text(database)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(script)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(
                        isFavorite ? ShardTheme.favorite : ShardTheme.mutedText
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Remove favorite" : "Add favorite")
        }
        .padding(.vertical, 3)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: selectedSection == .history ? "clock" : "star")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredHistory: [QueryRun] {
        guard !searchText.isEmpty else { return model.queryHistory }
        return model.queryHistory.filter {
            $0.script.localizedCaseInsensitiveContains(searchText)
                || $0.database.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredFavorites: [FavoriteQuery] {
        guard !searchText.isEmpty else { return model.favoriteQueries }
        return model.favoriteQueries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.script.localizedCaseInsensitiveContains(searchText)
                || $0.database.localizedCaseInsensitiveContains(searchText)
        }
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
}

private struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void
}
