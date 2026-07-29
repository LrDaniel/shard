import AppKit
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

struct DocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var showingDiff = false

    var body: some View {
        VStack(spacing: 0) {
            documentHeader
            Divider()
            documentEditor
            Divider()
            documentFooter
        }
        .frame(width: 760, height: 620)
        .background(Color(nsColor: SyntaxEditorTheme.background))
        .background(
            FindShortcutMonitor(action: model.findInDocumentSheet)
        )
        .background(
            OutsideClickDismissMonitor(action: dismiss.callAsFunction)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            model.inspectorIsEditing ? "Edit document" : "View document"
        )
        .sheet(isPresented: $showingDiff) {
            DocumentDiffView(
                edited: $model.inspectorDraft,
                original: model.inspectedDocument.map {
                    BSONValue(extendedJSON: $0).shellFormatted
                } ?? "{}"
            ) {
                model.saveInspectedDocument()
                showingDiff = false
            }
        }
    }

    private var documentHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.inspectorIsEditing ? "Edit Document" : "View Document")
                    .font(.headline)
                if let document = model.selectedDocument,
                   let collection = document.collectionName {
                    Text("\(document.database).\(collection)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Button {
                model.findInDocumentSheet()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Find in document (⌘F)")
            .accessibilityLabel("Find in document")

            if !model.inspectorIsEditing {
                Button(action: model.beginEditingInspectedDocument) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(model.currentConnection?.isReadOnly == true)
                .help("Edit document")
                .accessibilityLabel("Edit document")
            }
        }
        .padding(12)
    }

    private var documentEditor: some View {
        SyntaxTextEditor(
            text: $model.inspectorDraft,
            language: .mongoShell,
            isEditable: model.inspectorIsEditing,
            fontSize: 13,
            focusRequest: model.inspectorFocusRequest,
            findRequest: model.inspectorFindRequest
        )
    }

    private var documentFooter: some View {
        HStack(spacing: 8) {
            if model.inspectorIsEditing {
                Button("Cancel") {
                    model.cancelEditingInspectedDocument()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Changes…") {
                    showingDiff = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !hasChanges ||
                    model.isExecuting ||
                    model.currentConnection?.isReadOnly == true
                )
            } else {
                Menu("Copy") {
                    Button("Copy MongoDB Document", action: copyDocument)
                    Button("Copy Canonical Extended JSON", action: copyExtendedJSON)
                }
                Spacer()
                Button("Edit", action: model.beginEditingInspectedDocument)
                    .disabled(model.currentConnection?.isReadOnly == true)
                Button("Done", action: dismiss.callAsFunction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private var hasChanges: Bool {
        guard let inspectedDocument = model.inspectedDocument else { return false }
        return model.inspectorDraft
            != BSONValue(extendedJSON: inspectedDocument).shellFormatted
    }

    private func copyDocument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.inspectorDraft, forType: .string)
    }

    private func copyExtendedJSON() {
        guard let document = model.inspectedDocument else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.prettyPrinted, forType: .string)
    }
}

private struct DocumentDiffView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var edited: String

    let original: String
    let save: () -> Void

    var body: some View {
        let diff = DocumentLineDiff(original: original, edited: edited)

        VStack(spacing: 0) {
            HStack {
                Text("Review Document Changes")
                    .font(.headline)
                Spacer()
                Text(diff.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HSplitView {
                diffPane(
                    title: "Original",
                    text: .constant(original),
                    editable: false,
                    highlights: diff.originalHighlights
                )
                diffPane(
                    title: "Edited",
                    text: $edited,
                    editable: true,
                    highlights: diff.editedHighlights
                )
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Changes", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 900, height: 620)
        .background(
            OutsideClickDismissMonitor(action: dismiss.callAsFunction)
        )
    }

    private func diffPane(
        title: String,
        text: Binding<String>,
        editable: Bool,
        highlights: [SyntaxBackgroundHighlight]
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            Divider()
            SyntaxTextEditor(
                text: text,
                language: .mongoShell,
                isEditable: editable,
                fontSize: 12,
                backgroundHighlights: highlights
            )
        }
        .frame(minWidth: 320)
    }
}

struct DocumentLineDiff {
    let originalHighlights: [SyntaxBackgroundHighlight]
    let editedHighlights: [SyntaxBackgroundHighlight]
    let changeCount: Int

    init(original: String, edited: String) {
        let originalLines = original.components(separatedBy: "\n")
        let editedLines = edited.components(separatedBy: "\n")
        let changedLines = Self.changedLineIndexes(
            original: originalLines,
            edited: editedLines
        )
        originalHighlights = Self.highlights(
            in: original,
            lineIndexes: changedLines.original,
            color: NSColor.systemRed.withAlphaComponent(0.18)
        )
        editedHighlights = Self.highlights(
            in: edited,
            lineIndexes: changedLines.edited,
            color: NSColor.systemGreen.withAlphaComponent(0.18)
        )
        changeCount = max(changedLines.original.count, changedLines.edited.count)
    }

    var summary: String {
        switch changeCount {
        case 0:
            return "No changes"
        case 1:
            return "1 changed line"
        default:
            return "\(changeCount) changed lines"
        }
    }

    private static func changedLineIndexes(
        original: [String],
        edited: [String]
    ) -> (original: Set<Int>, edited: Set<Int>) {
        var matches = Array(
            repeating: Array(repeating: 0, count: edited.count + 1),
            count: original.count + 1
        )
        if !original.isEmpty, !edited.isEmpty {
            for originalIndex in stride(from: original.count - 1, through: 0, by: -1) {
                for editedIndex in stride(from: edited.count - 1, through: 0, by: -1) {
                    if original[originalIndex] == edited[editedIndex] {
                        matches[originalIndex][editedIndex] =
                            matches[originalIndex + 1][editedIndex + 1] + 1
                    } else {
                        matches[originalIndex][editedIndex] = max(
                            matches[originalIndex + 1][editedIndex],
                            matches[originalIndex][editedIndex + 1]
                        )
                    }
                }
            }
        }

        var originalChanges = Set<Int>()
        var editedChanges = Set<Int>()
        var originalIndex = 0
        var editedIndex = 0
        while originalIndex < original.count, editedIndex < edited.count {
            if original[originalIndex] == edited[editedIndex] {
                originalIndex += 1
                editedIndex += 1
            } else if matches[originalIndex + 1][editedIndex]
                        >= matches[originalIndex][editedIndex + 1] {
                originalChanges.insert(originalIndex)
                originalIndex += 1
            } else {
                editedChanges.insert(editedIndex)
                editedIndex += 1
            }
        }
        while originalIndex < original.count {
            originalChanges.insert(originalIndex)
            originalIndex += 1
        }
        while editedIndex < edited.count {
            editedChanges.insert(editedIndex)
            editedIndex += 1
        }
        return (originalChanges, editedChanges)
    }

    private static func highlights(
        in text: String,
        lineIndexes: Set<Int>,
        color: NSColor
    ) -> [SyntaxBackgroundHighlight] {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        var highlights: [SyntaxBackgroundHighlight] = []
        for (index, line) in lines.enumerated() {
            let lineLength = line.utf16.count
            let includesNewline = index < lines.count - 1
            let rangeLength = lineLength + (includesNewline ? 1 : 0)
            if lineIndexes.contains(index), rangeLength > 0 {
                highlights.append(
                    SyntaxBackgroundHighlight(
                        range: NSRange(location: offset, length: rangeLength),
                        color: color
                    )
                )
            }
            offset += rangeLength
        }
        return highlights
    }
}

struct OutsideClickDismissMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView()
        view.onWindowChange = context.coordinator.attach
        return view
    }

    func updateNSView(_ nsView: MonitoringView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(
        _ nsView: MonitoringView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var action: () -> Void

        private weak var modalWindow: NSWindow?
        private var localMonitor: Any?
        private var isDismissing = false

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attach(to window: NSWindow?) {
            guard modalWindow !== window else { return }
            detach()
            modalWindow = window
            guard window != nil else { return }

            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func detach() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            localMonitor = nil
            modalWindow = nil
            isDismissing = false
        }

        private func handle(_ event: NSEvent) {
            guard !isDismissing,
                  let modalWindow,
                  event.window !== modalWindow else {
                return
            }

            isDismissing = true
            action()
        }
    }

    final class MonitoringView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
