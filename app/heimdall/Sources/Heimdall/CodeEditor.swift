import AppKit
import SwiftUI

/// Plain-text code editor: monospaced, no line wrapping, line numbers in a gutter, undo, no smart quotes.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        // No wrapping: the text container is as wide as it needs to be and the view scrolls sideways.
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        tv.string = text
        tv.delegate = context.coordinator
        scroll.verticalRulerView = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        scroll.verticalRulerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// Line numbers next to an NSTextView. Counts real lines (newlines), not wrapped fragments.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    /// Number of the line that starts at or contains utf16 offset `upTo` (1-based).
    static func lineNumber(_ s: NSString, upTo: Int) -> Int {
        var n = 1
        let limit = min(upTo, s.length)
        var buf = [unichar](repeating: 0, count: 4096)
        var i = 0
        while i < limit {
            let len = min(4096, limit - i)
            s.getCharacters(&buf, range: NSRange(location: i, length: len))
            for k in 0..<len where buf[k] == 10 { n += 1 }
            i += len
        }
        return n
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let s = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]
        let inset = tv.textContainerInset.height
        func draw(_ n: Int, atY y: CGFloat, height: CGFloat) {
            let label = "\(n)" as NSString
            let size = label.size(withAttributes: attrs)
            let p = convert(NSPoint(x: 0, y: y + inset), from: tv)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: p.y + (height - size.height) / 2), withAttributes: attrs)
        }
        if s.length == 0 { draw(1, atY: lm.extraLineFragmentRect.minY, height: lm.extraLineFragmentRect.height); return }
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        var idx = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
        idx = s.lineRange(for: NSRange(location: min(idx, s.length - 1), length: 0)).location
        var line = Self.lineNumber(s, upTo: idx)
        let bottom = tv.visibleRect.maxY
        while idx < s.length {
            let r = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: idx), effectiveRange: nil)
            if r.minY > bottom { return }
            draw(line, atY: r.minY, height: r.height)
            let lr = s.lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(lr); line += 1
            if lr.length == 0 { break }
        }
        if idx >= s.length, s.character(at: s.length - 1) == 10 {
            let r = lm.extraLineFragmentRect
            draw(line, atY: r.minY, height: r.height)
        }
    }
}
