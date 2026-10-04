import AppKit
import SwiftUI

/// A read-only, selectable, searchable text view for long text.
struct LargeTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Space.page, height: Space.page)
        textView.setAccessibilityLabel("Transcript")
        apply(text, to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.lastText != text {
            apply(text, to: textView)
        }
        context.coordinator.lastText = text
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastText = ""
    }

    private func apply(_ text: String, to textView: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 12

        let attributed = NSAttributedString(
            string: Self.paragraphs(from: text),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToBeginningOfDocument(nil)
    }

    /// A transcript is often one unbroken block. For display only, break it into
    /// paragraphs of a few sentences so a long one can be read. Text that already
    /// has line breaks is left alone, and Copy and the exported files always
    /// use the original.
    static func paragraphs(from text: String, sentencesPerParagraph: Int = 4) -> String {
        guard !text.contains("\n") else { return text }

        var paragraphs: [String] = []
        var current: [String] = []
        (text as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (text as NSString).length),
            options: .bySentences
        ) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty else { return }
            current.append(sentence)
            if current.count >= sentencesPerParagraph {
                paragraphs.append(current.joined(separator: " "))
                current.removeAll()
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }

        return paragraphs.isEmpty ? text : paragraphs.joined(separator: "\n")
    }
}
