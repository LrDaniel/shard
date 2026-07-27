import AppKit
import SwiftUI

enum SyntaxLanguage {
    case javascript
    case json
    case mongoShell
}

enum SyntaxEditorTheme {
    static let background = NSColor(
        calibratedRed: 0.090,
        green: 0.094,
        blue: 0.098,
        alpha: 1
    )
    static let foreground = NSColor(
        calibratedRed: 0.84,
        green: 0.86,
        blue: 0.89,
        alpha: 1
    )
    static let number = NSColor(
        calibratedRed: 0.95,
        green: 0.61,
        blue: 0.31,
        alpha: 1
    )
    static let keyword = NSColor(
        calibratedRed: 0.78,
        green: 0.47,
        blue: 0.86,
        alpha: 1
    )
    static let string = NSColor(
        calibratedRed: 0.56,
        green: 0.76,
        blue: 0.47,
        alpha: 1
    )
    static let key = NSColor(
        calibratedRed: 0.38,
        green: 0.66,
        blue: 0.94,
        alpha: 1
    )
    static let constructor = NSColor(
        calibratedRed: 0.34,
        green: 0.71,
        blue: 0.75,
        alpha: 1
    )
    static let comment = NSColor(
        calibratedRed: 0.48,
        green: 0.51,
        blue: 0.56,
        alpha: 1
    )
}

struct SyntaxBackgroundHighlight {
    let range: NSRange
    let color: NSColor
}

struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String

    let language: SyntaxLanguage
    var isEditable = true
    var fontSize: CGFloat = 13
    var backgroundHighlights: [SyntaxBackgroundHighlight] = []
    var focusRequest = 0
    var cursorLocation: Int?
    var findRequest = 0
    var completions: [String] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.backgroundColor = SyntaxEditorTheme.background

        let textView = SyntaxCompletionTextView()
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = SyntaxEditorTheme.background
        textView.insertionPointColor = SyntaxEditorTheme.foreground
        textView.string = text
        scrollView.documentView = textView

        context.coordinator.configure(textView)
        context.coordinator.focus(
            textView,
            ifRequestedBy: focusRequest,
            cursorLocation: cursorLocation
        )
        context.coordinator.showFindBar(textView, ifRequestedBy: findRequest)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.backgroundColor = SyntaxEditorTheme.background
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = SyntaxEditorTheme.background
        textView.insertionPointColor = SyntaxEditorTheme.foreground

        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalUpdate = true
            textView.string = text
            context.coordinator.isApplyingExternalUpdate = false
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, textView.string.utf16.count),
                    length: 0
                )
            )
        }
        context.coordinator.configure(textView)
        context.coordinator.focus(
            textView,
            ifRequestedBy: focusRequest,
            cursorLocation: cursorLocation
        )
        context.coordinator.showFindBar(textView, ifRequestedBy: findRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxTextEditor
        var isApplyingExternalUpdate = false
        private var handledFocusRequest = 0
        private var handledFindRequest = 0
        private var completionWorkItem: DispatchWorkItem?

        init(parent: SyntaxTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            configure(textView)
            scheduleCompletions(for: textView)
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let source = textView.string as NSString
            guard NSMaxRange(charRange) <= source.length else { return [] }
            let prefix = source.substring(with: charRange)
            index?.pointee = 0
            return parent.completions.filter {
                $0.caseInsensitiveCompare(prefix) != .orderedSame
                    && $0.range(
                        of: prefix,
                        options: [.anchored, .caseInsensitive]
                    ) != nil
            }
            .prefix(50)
            .map { $0 }
        }

        func configure(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let visibleOrigin = textView.enclosingScrollView?
                .contentView.bounds.origin
            let fullRange = NSRange(location: 0, length: storage.length)
            let selection = textView.selectedRange()
            let font = NSFont.monospacedSystemFont(
                ofSize: parent.fontSize,
                weight: .regular
            )
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: SyntaxEditorTheme.foreground
            ]

            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: fullRange)
            for highlight in parent.backgroundHighlights {
                let range = NSIntersectionRange(highlight.range, fullRange)
                if range.length > 0 {
                    storage.addAttribute(
                        .backgroundColor,
                        value: highlight.color,
                        range: range
                    )
                }
            }
            apply(
                pattern: #"\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
                color: SyntaxEditorTheme.number,
                to: storage
            )
            apply(
                pattern: #"\b(?:true|false|null|undefined)\b"#,
                color: SyntaxEditorTheme.keyword,
                to: storage
            )
            apply(
                pattern: #""(?:\\.|[^"\\])*""#,
                color: SyntaxEditorTheme.string,
                to: storage
            )

            if parent.language == .json || parent.language == .mongoShell {
                apply(
                    pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#,
                    color: SyntaxEditorTheme.key,
                    to: storage
                )
            }
            if parent.language != .json {
                apply(
                    pattern: #"\b(?:async|await|break|case|catch|const|continue|default|delete|do|else|for|function|if|in|let|new|return|switch|throw|try|typeof|var|while)\b"#,
                    color: SyntaxEditorTheme.keyword,
                    to: storage
                )
                apply(
                    pattern: #"\b(?:db|EJSON|ISODate|ObjectId|NumberInt|NumberLong|NumberDecimal|Timestamp|BinData|RegExp|MinKey|MaxKey|show|use)\b"#,
                    color: SyntaxEditorTheme.constructor,
                    to: storage
                )
                apply(
                    pattern: #"(?s)/\*.*?\*/|//[^\n]*"#,
                    color: SyntaxEditorTheme.comment,
                    to: storage
                )
            }

            storage.endEditing()
            textView.typingAttributes = baseAttributes
            textView.setSelectedRange(selection)
            stabilizeDocumentLayout(
                textView,
                preserving: visibleOrigin
            )
        }

        func focus(
            _ textView: NSTextView,
            ifRequestedBy request: Int,
            cursorLocation: Int?
        ) {
            guard request > handledFocusRequest else { return }
            handledFocusRequest = request
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                if let cursorLocation {
                    let location = min(
                        max(0, cursorLocation),
                        textView.string.utf16.count
                    )
                    let range = NSRange(location: location, length: 0)
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                }
            }
        }

        func showFindBar(_ textView: NSTextView, ifRequestedBy request: Int) {
            guard request > handledFindRequest else { return }
            handledFindRequest = request
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                let findBarWasVisible =
                    textView.enclosingScrollView?.isFindBarVisible == true
                if !findBarWasVisible {
                    let findPasteboard = NSPasteboard(name: .find)
                    findPasteboard.clearContents()
                    findPasteboard.setString("", forType: .string)
                }
                window.makeFirstResponder(textView)
                let sender = NSMenuItem()
                sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.performFindPanelAction(sender)
            }
        }

        private func scheduleCompletions(for textView: NSTextView) {
            completionWorkItem?.cancel()
            guard parent.isEditable,
                  parent.language == .javascript,
                  !parent.completions.isEmpty,
                  let completionTextView = textView as? SyntaxCompletionTextView,
                  completionTextView.completionPrefix.count >= 2,
                  parent.completions.contains(where: {
                      $0.range(
                          of: completionTextView.completionPrefix,
                          options: [.anchored, .caseInsensitive]
                      ) != nil
                  }) else {
                return
            }

            let workItem = DispatchWorkItem { [weak textView] in
                textView?.complete(nil)
            }
            completionWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.18,
                execute: workItem
            )
        }

        private func apply(
            pattern: String,
            color: NSColor,
            to storage: NSTextStorage
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return
            }
            let range = NSRange(location: 0, length: storage.length)
            for match in expression.matches(in: storage.string, range: range) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        private func stabilizeDocumentLayout(
            _ textView: NSTextView,
            preserving visibleOrigin: NSPoint?
        ) {
            guard let scrollView = textView.enclosingScrollView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else {
                return
            }

            let viewportSize = scrollView.contentSize
            let documentWidth = max(1, viewportSize.width)
            if abs(textView.frame.width - documentWidth) > 0.5 {
                textView.setFrameSize(
                    NSSize(width: documentWidth, height: textView.frame.height)
                )
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
                + (textView.textContainerInset.height * 2)
            let documentHeight = max(viewportSize.height, ceil(usedHeight))
            if abs(textView.frame.height - documentHeight) > 0.5 {
                textView.setFrameSize(
                    NSSize(width: documentWidth, height: documentHeight)
                )
            }

            guard let visibleOrigin else { return }
            let maximumY = max(
                0,
                documentHeight - scrollView.contentView.bounds.height
            )
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: 0,
                    y: min(max(0, visibleOrigin.y), maximumY)
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

private final class SyntaxCompletionTextView: NSTextView {
    private static let completionCharacters = CharacterSet
        .alphanumerics
        .union(CharacterSet(charactersIn: "_.$"))

    override var rangeForUserCompletion: NSRange {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else {
            return NSRange(location: selection.location, length: 0)
        }

        let source = string as NSString
        var location = selection.location
        while location > 0 {
            let scalar = UnicodeScalar(source.character(at: location - 1))
            guard let scalar,
                  Self.completionCharacters.contains(scalar) else {
                break
            }
            location -= 1
        }
        return NSRange(
            location: location,
            length: selection.location - location
        )
    }

    var completionPrefix: String {
        let range = rangeForUserCompletion
        guard range.length > 0 else { return "" }
        return (string as NSString).substring(with: range)
    }
}

struct FindShortcutMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
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
                guard modifiers == .command, event.keyCode == 3 else {
                    return event
                }
                action()
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
