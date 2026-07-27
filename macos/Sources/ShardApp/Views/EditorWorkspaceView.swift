#if canImport(ShardCore)
import ShardCore
#endif
import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            QueryTabStrip()
            Divider()
            if let document = model.selectedDocumentBinding {
                VSplitView {
                    QueryEditorView(document: document)
                        .frame(
                            minHeight: editorHeight(for: document.wrappedValue),
                            idealHeight: editorHeight(for: document.wrappedValue)
                        )
                    QueryResultsView(run: model.activeRun)
                        .frame(minHeight: 160)
                        .layoutPriority(1)
                }
            } else {
                EmptyWorkspaceView()
            }
        }
        .background(ShardTheme.canvas)
    }

    private func editorHeight(for document: QueryDocument) -> CGFloat {
        let lineCount = max(1, document.script.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count)
        let textHeight = min(190, 18 * CGFloat(lineCount) + 16)
        return 24 + textHeight + 12
    }
}

private struct QueryTabStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.workspace.documents) { document in
                    QueryTab(
                        document: document,
                        selected: document.id == model.workspace.selectedDocumentID,
                        select: { model.selectQuery(document.id) },
                        close: { model.closeQuery(document.id) }
                    )
                }
                Button(action: model.addQuery) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New query")
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 32)
        .background(ShardTheme.raised)
    }
}

private struct QueryTab: View {
    let document: QueryDocument
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                    Text(document.title)
                    if document.isDirty {
                        Circle()
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close \(document.title)")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(selected ? ShardTheme.selection : .clear)
        .clipShape(.rect(cornerRadius: 5))
        .background(MiddleClickMonitor(action: close))
        .contextMenu {
            Button("Close", action: close)
        }
    }
}

private struct MiddleClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var action: () -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) {
                [weak self] event in
                guard
                    let self,
                    event.buttonNumber == 2,
                    let view = self.view,
                    event.window === view.window
                else {
                    return event
                }

                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                self.action()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private struct QueryEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var document: QueryDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.database)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let connection = model.currentConnection {
                    if connection.effectiveEnvironment == .production {
                        Text("PRODUCTION")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red)
                            .clipShape(.rect(cornerRadius: 3))
                    }
                    if connection.isReadOnly {
                        Label("READ-ONLY", systemImage: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isSamplingSchema {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Sampling collection fields")
                } else if !model.sampledDatabaseFields.isEmpty {
                    let indexedCount = model.sampledDatabaseFields.filter(\.isIndexed).count
                    Button(action: model.refreshSelectedQuerySchema) {
                        Label(
                            "\(model.sampledDatabaseFields.count) fields"
                                + (indexedCount > 0 ? " · \(indexedCount) indexed" : ""),
                            systemImage: "text.magnifyingglass"
                        )
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh schema-aware autocomplete")
                    .accessibilityLabel(
                        "\(model.sampledDatabaseFields.count) sampled fields, "
                            + "\(indexedCount) indexed"
                    )
                }
                Button(action: model.toggleSelectedQueryFavorite) {
                    Image(
                        systemName: model.isFavorite(
                            script: document.script,
                            database: document.database
                        ) ? "star.fill" : "star"
                    )
                    .foregroundStyle(
                        model.isFavorite(
                            script: document.script,
                            database: document.database
                        ) ? ShardTheme.favorite : Color.gray
                    )
                }
                .buttonStyle(.borderless)
                .help("Add or remove this query from favorites")
                .accessibilityLabel("Toggle favorite query")
                Text(document.isDirty ? "Edited" : "Saved")
                    .font(.caption)
                    .foregroundStyle(ShardTheme.subtleText)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(ShardTheme.raised)

            SyntaxTextEditor(
                text: $document.script,
                language: .javascript,
                fontSize: 13,
                focusRequest: model.queryEditorFocusDocumentID == document.id
                    ? model.queryEditorFocusRequest
                    : 0,
                cursorLocation: model.queryEditorFocusDocumentID == document.id
                    ? model.queryEditorCursorLocation
                    : nil,
                completions: model.queryEditorCompletions
            )
            .clipShape(.rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .accessibilityLabel("MongoDB query editor")
        }
        .background(ShardTheme.canvas)
    }
}

private struct EmptyWorkspaceView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Query Open")
                .font(.headline)
            Text("Create a query with ⌘T.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
