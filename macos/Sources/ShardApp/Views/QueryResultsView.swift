import AppKit
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

struct QueryResultsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pageIndex = 0
    @State private var requestedPageIndex: Int?

    let run: QueryRun?
    private let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            if let run {
                resultBar(run)
                Divider()
                BSONOutlineTable(
                    value: visibleResult(run),
                    rootOffset: pageIndex * pageSize
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Run a query to see results")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel("Query results")
        .onChange(of: run?.id) { _ in
            pageIndex = 0
            requestedPageIndex = nil
        }
        .onChange(of: run?.resultCount) { updatedCount in
            guard let requestedPageIndex,
                  let updatedCount,
                  updatedCount > requestedPageIndex * pageSize else {
                return
            }
            pageIndex = requestedPageIndex
            self.requestedPageIndex = nil
        }
    }

    private func resultBar(_ run: QueryRun) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(model.selectedDocument?.collectionName ?? "Results")
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Label(executionTime(run), systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if model.isExecuting, requestedPageIndex != nil {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Loading next page")
            }

            Text(pageRange(run))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(action: showPreviousPage) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(pageIndex == 0 || model.isExecuting)
            .help("Previous page")
            .accessibilityLabel("Previous result page")

            Button {
                showNextPage(run)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!canShowNextPage(run) || model.isExecuting)
            .help("Next page")
            .accessibilityLabel("Next result page")
        }
        .controlSize(.small)
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(ShardTheme.raised)
    }

    private func visibleResult(_ run: QueryRun) -> BSONValue {
        guard case let .array(documents) = run.result else {
            return BSONValue(extendedJSON: run.result)
        }
        let start = min(pageIndex * pageSize, documents.count)
        let end = min(start + pageSize, documents.count)
        return BSONValue(extendedJSON: .array(Array(documents[start..<end])))
    }

    private func loadedDocumentCount(_ run: QueryRun?) -> Int {
        guard let run else { return 0 }
        if case let .array(documents) = run.result {
            return documents.count
        }
        return 1
    }

    private func pageRange(_ run: QueryRun) -> String {
        let count = loadedDocumentCount(run)
        guard count > 0 else { return "0 results" }
        let start = pageIndex * pageSize + 1
        let end = min(start + pageSize - 1, count)
        return run.hasMore ? "\(start)–\(end) loaded" : "\(start)–\(end) of \(count)"
    }

    private func executionTime(_ run: QueryRun) -> String {
        String(format: "%.3f sec", Double(run.elapsedMilliseconds) / 1_000)
    }

    private func canShowNextPage(_ run: QueryRun) -> Bool {
        let nextPageStart = (pageIndex + 1) * pageSize
        return nextPageStart < loadedDocumentCount(run) || run.hasMore
    }

    private func showPreviousPage() {
        pageIndex = max(0, pageIndex - 1)
    }

    private func showNextPage(_ run: QueryRun) {
        let nextPage = pageIndex + 1
        if nextPage * pageSize < loadedDocumentCount(run) {
            pageIndex = nextPage
            return
        }
        guard run.hasMore else { return }
        requestedPageIndex = nextPage
        model.loadMoreResults()
    }
}

private struct BSONOutlineTable: View {
    @State private var expandedNodeIDs: Set<String> = []

    let value: BSONValue
    let rootOffset: Int

    var body: some View {
        GeometryReader { geometry in
            let tableWidth = geometry.size.width
            let keyColumnWidth = tableWidth / 3
            let valueColumnWidth = tableWidth / 3
            let typeColumnWidth = tableWidth - keyColumnWidth - valueColumnWidth

            VStack(alignment: .leading, spacing: 0) {
                header(
                    keyColumnWidth: keyColumnWidth,
                    valueColumnWidth: valueColumnWidth,
                    typeColumnWidth: typeColumnWidth
                )
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(BSONNode.makeRoot(value, startingAt: rootOffset)) { node in
                            BSONOutlineRow(
                                expandedNodeIDs: $expandedNodeIDs,
                                node: node,
                                depth: 0,
                                keyColumnWidth: keyColumnWidth,
                                valueColumnWidth: valueColumnWidth,
                                typeColumnWidth: typeColumnWidth
                            )
                        }
                    }
                    .frame(width: tableWidth, alignment: .topLeading)
                    .frame(
                        minHeight: max(0, geometry.size.height - 25),
                        alignment: .topLeading
                    )
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .background(ShardTheme.canvas)
        }
    }

    private func header(
        keyColumnWidth: CGFloat,
        valueColumnWidth: CGFloat,
        typeColumnWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            columnHeader("Key", width: keyColumnWidth)
            Divider()
            columnHeader("Value", width: valueColumnWidth)
            Divider()
            columnHeader("Type", width: typeColumnWidth)
        }
        .frame(
            width: keyColumnWidth + valueColumnWidth + typeColumnWidth,
            height: 24,
            alignment: .leading
        )
        .background(ShardTheme.raised)
    }

    private func columnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(width: width, alignment: .leading)
    }
}

private struct BSONOutlineRow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var expandedNodeIDs: Set<String>
    @State private var showingInsertDocument = false
    @State private var showingDeleteConfirmation = false

    let node: BSONNode
    let depth: Int
    let keyColumnWidth: CGFloat
    let valueColumnWidth: CGFloat
    let typeColumnWidth: CGFloat

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if node.hasChildren {
                    Button(action: activateRow) {
                        rowContent
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isExpanded ? "Collapse \(node.key)" : "Expand \(node.key)"
                    )
                } else {
                    rowContent
                }
            }
            .frame(height: 23)
            .contentShape(Rectangle())
            .background(isHovered ? Color.accentColor.opacity(0.08) : .clear)
            .onHover { isHovered = $0 }
            .contextMenu {
                resultContextMenu
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard node.isRootDocument else { return }
                    model.inspectDocument(node.source.extendedJSON)
                }
            )

            Divider()

            if isExpanded {
                ForEach(node.children ?? []) { child in
                    BSONOutlineRow(
                        expandedNodeIDs: $expandedNodeIDs,
                        node: child,
                        depth: depth + 1,
                        keyColumnWidth: keyColumnWidth,
                        valueColumnWidth: valueColumnWidth,
                        typeColumnWidth: typeColumnWidth
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.key), \(node.value), \(node.type)")
        .sheet(isPresented: $showingInsertDocument) {
            InsertDocumentSheet { value in
                model.insertDocument(value)
            }
        }
        .alert("Delete Document?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.deleteDocument(node.source.extendedJSON)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(node.key) from the current collection.")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            keyCell
            Divider()
            valueCell
            Divider()
            typeCell
        }
    }

    private var keyCell: some View {
        HStack(spacing: 4) {
            Color.clear
                .frame(width: CGFloat(depth) * 14)

            if node.hasChildren {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }

            Image(systemName: node.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(node.iconColor)
                .frame(width: 13)

            Text(node.key)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 5)
        .frame(width: keyColumnWidth, alignment: .leading)
    }

    private var valueCell: some View {
        Text(node.value)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .padding(.horizontal, 7)
            .frame(width: valueColumnWidth, alignment: .leading)
    }

    private var typeCell: some View {
        Text(node.type)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(width: typeColumnWidth, alignment: .leading)
    }

    private var isExpanded: Bool {
        expandedNodeIDs.contains(node.id)
    }

    private func toggleExpansion() {
        if isExpanded {
            expandedNodeIDs.remove(node.id)
        } else {
            expandedNodeIDs.insert(node.id)
        }
    }

    @ViewBuilder
    private var resultContextMenu: some View {
        if node.hasChildren {
            Button("Expand Recursively", action: expandRecursively)
            Button("Collapse Recursively", action: collapseRecursively)
            Divider()
        }

        if node.isRootDocument {
            Button("Edit Document…") {
                model.inspectDocument(node.source.extendedJSON, editing: true)
            }
            .disabled(model.currentConnection?.isReadOnly == true)
            Button("View Document…") {
                model.inspectDocument(node.source.extendedJSON)
            }
            Button("Insert Document…") {
                showingInsertDocument = true
            }
            .disabled(model.currentConnection?.isReadOnly == true)
            Divider()
            Button("Copy MongoDB Document", action: copyDocument)
            Button("Copy Canonical Extended JSON", action: copyExtendedJSON)
            Divider()
            Button("Delete Document…", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(model.currentConnection?.isReadOnly == true)
        } else {
            Button("Copy Value", action: copyValue)
            Button("Copy Key", action: copyKey)
            if let fieldPath = node.fieldPath {
                Button("Copy Field Path", action: copyFieldPath)
                Divider()
                Button("Find Where \(fieldPath) Equals This") {
                    model.openFieldQuery(
                        path: fieldPath,
                        value: node.source,
                        action: .equals
                    )
                }
                Button("Find Where \(fieldPath) Does Not Equal This") {
                    model.openFieldQuery(
                        path: fieldPath,
                        value: node.source,
                        action: .notEquals
                    )
                }
                Menu("Field Presence") {
                    Button("Field Exists") {
                        model.openFieldQuery(
                            path: fieldPath,
                            value: node.source,
                            action: .exists
                        )
                    }
                    Button("Field Is Missing") {
                        model.openFieldQuery(
                            path: fieldPath,
                            value: node.source,
                            action: .missing
                        )
                    }
                }
                Menu("Sort by \(fieldPath)") {
                    Button("Ascending") {
                        model.openFieldQuery(
                            path: fieldPath,
                            value: node.source,
                            action: .sortAscending
                        )
                    }
                    Button("Descending") {
                        model.openFieldQuery(
                            path: fieldPath,
                            value: node.source,
                            action: .sortDescending
                        )
                    }
                }
                Divider()
            }
            Button("Copy MongoDB Value", action: copyDocument)
            Button("Copy Canonical Extended JSON", action: copyExtendedJSON)
        }
    }

    private func expandRecursively() {
        expandedNodeIDs.formUnion(node.expandableNodeIDs)
    }

    private func activateRow() {
        toggleExpansion()
    }

    private func collapseRecursively() {
        expandedNodeIDs.subtract(node.expandableNodeIDs)
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.value, forType: .string)
    }

    private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.key, forType: .string)
    }

    private func copyFieldPath() {
        guard let fieldPath = node.fieldPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fieldPath, forType: .string)
    }

    private func copyDocument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.source.shellFormatted, forType: .string)
    }

    private func copyExtendedJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            node.source.extendedJSON.prettyPrinted,
            forType: .string
        )
    }
}

private struct BSONNode: Identifiable {
    let id: String
    let key: String
    let value: String
    let type: String
    let systemImage: String
    let iconColor: Color
    let source: BSONValue
    let isRootDocument: Bool
    let fieldPath: String?
    let children: [BSONNode]?

    var hasChildren: Bool {
        children?.isEmpty == false
    }

    var expandableNodeIDs: Set<String> {
        var result = hasChildren ? Set([id]) : []
        for child in children ?? [] {
            result.formUnion(child.expandableNodeIDs)
        }
        return result
    }

    var documentID: JSONValue? {
        guard case let .document(fields) = source else { return nil }
        return fields.first(where: { $0.0 == "_id" })?.1.extendedJSON
    }

    static func makeRoot(_ value: BSONValue, startingAt offset: Int = 0) -> [BSONNode] {
        switch value {
        case let .array(values):
            return values.enumerated().map { index, child in
                makeNode(
                    key: rootKey(for: child, number: offset + index + 1),
                    value: child,
                    path: "$[\(offset + index)]",
                    fieldPath: nil,
                    isRootDocument: true
                )
            }
        default:
            return [
                makeNode(
                    key: rootKey(for: value, number: 1),
                    value: value,
                    path: "$",
                    fieldPath: nil,
                    isRootDocument: true
                )
            ]
        }
    }

    private static func makeNode(
        key: String,
        value: BSONValue,
        path: String,
        fieldPath: String?,
        isRootDocument: Bool = false
    ) -> BSONNode {
        BSONNode(
            id: path,
            key: key,
            value: summary(value),
            type: typeName(value),
            systemImage: systemImage(value),
            iconColor: iconColor(value),
            source: value,
            isRootDocument: isRootDocument,
            fieldPath: fieldPath,
            children: children(
                for: value,
                path: path,
                fieldPath: fieldPath
            )
        )
    }

    private static func children(
        for value: BSONValue,
        path: String,
        fieldPath: String?
    ) -> [BSONNode]? {
        switch value {
        case let .document(fields):
            return fields.map { key, child in
                makeNode(
                    key: key,
                    value: child,
                    path: "\(path).\(key)",
                    fieldPath: fieldPath.map { "\($0).\(key)" } ?? key
                )
            }
        case let .array(values):
            return values.enumerated().map { index, child in
                makeNode(
                    key: "[\(index)]",
                    value: child,
                    path: "\(path)[\(index)]",
                    fieldPath: fieldPath
                )
            }
        default:
            return nil
        }
    }

    private static func rootKey(for value: BSONValue, number: Int) -> String {
        guard case let .document(fields) = value,
              let identifier = fields.first(where: { $0.0 == "_id" })?.1 else {
            return "(\(number))"
        }
        return "(\(number)) \(summary(identifier))"
    }

    private static func summary(_ value: BSONValue) -> String {
        switch value {
        case let .document(fields): return "{ \(fields.count) fields }"
        case let .array(values): return "[ \(values.count) values ]"
        case let .objectId(value): return "ObjectId(\"\(value)\")"
        case let .string(value): return value
        default: return value.displayString
        }
    }

    private static func typeName(_ value: BSONValue) -> String {
        switch value {
        case .null: return "Null"
        case .bool: return "Boolean"
        case .int32: return "Int32"
        case .int64: return "Int64"
        case .double: return "Double"
        case .decimal128: return "Decimal128"
        case .string: return "String"
        case .objectId: return "ObjectId"
        case .date: return "Date"
        case .timestamp: return "Timestamp"
        case .binary: return "Binary"
        case .regex: return "Regex"
        case .minKey: return "MinKey"
        case .maxKey: return "MaxKey"
        case .array: return "Array"
        case .document: return "Object"
        }
    }

    private static func systemImage(_ value: BSONValue) -> String {
        switch value {
        case .document, .array: return "curlybraces"
        case .string: return "textformat"
        case .int32, .int64, .double, .decimal128: return "number"
        case .date, .timestamp: return "calendar.badge.clock"
        case .bool: return "switch.2"
        case .objectId: return "rectangle"
        case .null: return "minus"
        default: return "doc.plaintext"
        }
    }

    private static func iconColor(_ value: BSONValue) -> Color {
        switch value {
        case .document, .array: return .yellow
        case .date, .timestamp: return .red
        case .string: return .secondary
        case .int32, .int64, .double, .decimal128: return .secondary
        default: return .secondary
        }
    }
}

private struct InsertDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var text = JSONValue.object([:]).prettyPrinted
    @State private var validationError: String?
    @State private var focusRequest = 0
    @State private var findRequest = 0

    let insert: (JSONValue) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insert Document")
                        .font(.headline)
                    if let document = model.selectedDocument,
                       let collection = document.collectionName {
                        Text("\(document.database).\(collection)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                Button(action: showFind) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Find in document (⌘F)")
                .accessibilityLabel("Find in document")
            }
            .padding(12)

            Divider()

            SyntaxTextEditor(
                text: $text,
                language: .json,
                fontSize: 13,
                focusRequest: focusRequest,
                findRequest: findRequest
            )

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(insertButtonTitle, action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 620)
        .background(FindShortcutMonitor(action: showFind))
        .onAppear {
            focusRequest += 1
        }
    }

    private func commit() {
        do {
            let value = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(text.utf8)
            )
            switch value {
            case .object:
                break
            case let .array(documents):
                guard !documents.isEmpty else {
                    validationError = "Insert Many requires at least one document."
                    return
                }
                guard documents.allSatisfy({
                    if case .object = $0 { return true }
                    return false
                }) else {
                    validationError = "Every item in the array must be a JSON object."
                    return
                }
            default:
                validationError = "Enter one JSON object or an array of JSON objects."
                return
            }
            insert(value)
            dismiss()
        } catch {
            validationError = "Invalid Extended JSON: \(error.localizedDescription)"
        }
    }

    private var insertButtonTitle: String {
        guard let value = try? JSONDecoder().decode(
            JSONValue.self,
            from: Data(text.utf8)
        ), case .array = value else {
            return "Insert"
        }
        return "Insert Many"
    }

    private func showFind() {
        focusRequest += 1
        findRequest += 1
    }
}
