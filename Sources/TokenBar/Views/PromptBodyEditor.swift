import AppKit
import SwiftUI
import TokenBarCore

/// Syntax-highlighted, lint-aware editor for prompt-template bodies.
///
/// Wraps NSTextView so we can paint per-token foreground colors and squiggle
/// underlines for diagnostics. The plain text stays the source of truth via
/// `@Binding<String>`; attributes are re-applied on every change.
struct PromptBodyEditor: NSViewRepresentable {
    @Binding var text: String
    let lintResult: PromptLintResult
    /// Bottom-of-editor ghost text shown when `text` is empty.
    let ghostText: String
    /// Notifies the parent that the user typed a `⌘.` shortcut to open picker.
    var onPickerShortcut: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.string = text
        context.coordinator.applyAttributes(to: textView, lintResult: lintResult)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Only mutate the storage from the outside if the binding diverged
        // from what the user has typed (avoids fighting the user's caret).
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selection)
        }
        context.coordinator.applyAttributes(to: textView, lintResult: lintResult)
        context.coordinator.ghostText = ghostText
        context.coordinator.refreshGhost(in: nsView, textView: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPickerShortcut: onPickerShortcut, ghostText: ghostText)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let textBinding: Binding<String>
        let onPickerShortcut: () -> Void
        var ghostText: String
        private var ghostLabel: NSTextField?

        init(text: Binding<String>, onPickerShortcut: @escaping () -> Void, ghostText: String) {
            self.textBinding = text
            self.onPickerShortcut = onPickerShortcut
            self.ghostText = ghostText
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            DispatchQueue.main.async {
                self.textBinding.wrappedValue = textView.string
            }
        }

        // Catch ⌘. — open picker without inserting a period.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true,
               NSApp.currentEvent?.charactersIgnoringModifiers == "."
            {
                onPickerShortcut()
                return true
            }
            return false
        }

        // MARK: - Attribute application

        func applyAttributes(to textView: NSTextView, lintResult: PromptLintResult) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let baseColor = NSColor.labelColor

            storage.beginEditing()
            storage.setAttributes(
                [.font: baseFont, .foregroundColor: baseColor],
                range: full
            )

            for token in lintResult.tokens {
                guard NSMaxRange(token.range) <= storage.length else { continue }
                let color: NSColor
                switch token.kind {
                case .argumentsToken, .indexedToken:
                    color = TokenBarStyle.PromptTokenColor.arguments
                case .positionalToken:
                    color = TokenBarStyle.PromptTokenColor.positional
                case .envToken:
                    color = TokenBarStyle.PromptTokenColor.env
                case .shellInlineToken, .shellBlockToken:
                    color = TokenBarStyle.PromptTokenColor.shell
                case .frontmatter:
                    color = TokenBarStyle.PromptTokenColor.frontmatter
                }
                storage.addAttribute(.foregroundColor, value: color, range: token.range)
            }

            // Apply diagnostic underlines on top of token colors.
            for diag in lintResult.diagnostics {
                guard NSMaxRange(diag.range) <= storage.length else { continue }
                let underlineColor: NSColor
                let foreground: NSColor
                switch diag.severity {
                case .error:
                    underlineColor = TokenBarStyle.PromptTokenColor.error
                    foreground = TokenBarStyle.PromptTokenColor.error
                case .warning:
                    underlineColor = TokenBarStyle.PromptTokenColor.warning
                    foreground = TokenBarStyle.PromptTokenColor.warning
                }
                storage.addAttributes(
                    [
                        .foregroundColor: foreground,
                        .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                        .underlineColor: underlineColor,
                        .toolTip: diag.message,
                    ],
                    range: diag.range
                )
            }
            storage.endEditing()
        }

        // MARK: - Ghost text overlay

        func refreshGhost(in scroll: NSScrollView, textView: NSTextView) {
            if textView.string.isEmpty {
                if ghostLabel == nil {
                    let label = NSTextField(labelWithString: ghostText)
                    label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    label.textColor = .secondaryLabelColor.withAlphaComponent(0.55)
                    label.isEditable = false
                    label.isSelectable = false
                    label.drawsBackground = false
                    label.translatesAutoresizingMaskIntoConstraints = false
                    scroll.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 12),
                        label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 10),
                    ])
                    ghostLabel = label
                }
                ghostLabel?.stringValue = ghostText
                ghostLabel?.isHidden = false
            } else {
                ghostLabel?.isHidden = true
            }
        }
    }
}
