import SwiftUI
import AppKit

// MARK: - Layout manager that draws match highlights as rounded rects

/// Background painting happens in the layout manager, so a subclass is the
/// only way to get Regex101-style rounded highlight pills. The text view
/// hands over its match ranges; this class paints each line-fragment slice.
final class MatchHighlightLayoutManager: NSLayoutManager {
    weak var owner: RegexSampleTextView?
    var highlightColor = NSColor.controlAccentColor

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let owner,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil) else { return }
        // AppKit draws on the main thread, but toolchains disagree on how
        // this override inherits the view's isolation (warning on one
        // Xcode, error on another) — claim the main actor explicitly.
        let ranges = MainActor.assumeIsolated { owner.highlightRanges }
        guard !ranges.isEmpty else { return }
        let visibleChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let path = NSBezierPath()

        for range in ranges {
            let inter = NSIntersectionRange(range, visibleChars)
            guard inter.length > 0 else { continue }
            let glyphRange = self.glyphRange(forCharacterRange: inter, actualCharacterRange: nil)
            // Slice per line fragment so multi-line matches get one pill per line.
            enumerateLineFragments(forGlyphRange: glyphRange) { _, _, fragContainer, fragCharRange, _ in
                guard fragContainer === container else { return }
                let lineInter = NSIntersectionRange(fragCharRange, inter)
                guard lineInter.length > 0 else { return }
                let lineGlyphs = self.glyphRange(forCharacterRange: lineInter, actualCharacterRange: nil)
                // Inset two points per side: bounding rects use full mono
                // cell advances, and the inset keeps adjacent pills from
                // merging across unmatched characters between them.
                var rect = self.boundingRect(forGlyphRange: lineGlyphs, in: fragContainer)
                rect.origin.x += origin.x + 2
                rect.origin.y += origin.y
                rect.size.width -= 4
                path.append(NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4))
            }
        }
        guard !path.isEmpty else { return }
        highlightColor.setFill()
        path.fill()
    }
}

// MARK: - The sample editor

final class RegexSampleTextView: NSTextView {
    var onEdit: (() -> Void)?
    var highlightRanges: [NSRange] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { RegexKeyLoop.register(editor: self) }
    }

    // Tab is focus navigation, not input: the sample editor participates in
    // the window's key-view loop like every other surface (a literal tab
    // character is not a useful sample edit).
    override func insertTab(_ sender: Any?) {
        window?.selectKeyView(following: self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectKeyView(preceding: self)
    }

    override func didChangeText() {
        super.didChangeText()
        clearHighlights()
        onEdit?()
    }

    func clearHighlights() {
        guard !highlightRanges.isEmpty else { return }
        highlightRanges = []
        if let layoutManager {
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: (string as NSString).length))
        }
    }

    func applyHighlights(_ ranges: [NSRange]) {
        highlightRanges = ranges
        if let layoutManager {
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: (string as NSString).length))
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - SwiftUI bridge

/// Hosts the sample editor. SwiftUI sizes the scroll view after
/// `makeNSView` returns, and the clip view's autoresizing pass does not
/// grow a freshly created zero-width document view — a zero-width text
/// view wraps every character onto its own line, pushes the caret ~850pt
/// down the document, and paints nothing once the width finally arrives
/// because the stale scroll position never comes back. Keep the document
/// frame and the visible origin pinned on every layout pass instead.
final class SampleEditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let target = max(contentView.bounds.width, 1)
        let minHeight = contentView.bounds.height
        var frame = text.frame
        var changed = false
        if abs(frame.width - target) > 0.5 { frame.size.width = target; changed = true }
        if frame.height < minHeight { frame.size.height = minHeight; changed = true }
        if frame.origin != .zero { frame.origin = .zero; changed = true }
        if changed {
            text.frame = frame
            var bounds = contentView.bounds
            bounds.origin = .zero
            contentView.bounds = bounds
            text.needsDisplay = true
        }
    }
}

struct SampleTextView: NSViewRepresentable {
    @Binding var text: String
    var highlightColor: NSColor
    var highlights: [NSRange]
    var selection: NSRange?
    var onEdit: () -> Void

    typealias NSViewType = NSScrollView

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SampleEditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // Wire the TextKit 1 stack explicitly. A text view built without a
        // container runs TextKit 2, where the `.layoutManager` accessor only
        // hands back a shadow object: `replaceLayoutManager` then silently
        // does nothing and the highlight pills never paint. An explicit
        // storage → layout manager → container chain pins the view to
        // TextKit 1 from birth.
        let storage = NSTextStorage(string: text)
        let layoutManager = MatchHighlightLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 6
        layoutManager.addTextContainer(container)

        let initial = scroll.contentSize
        let view = RegexSampleTextView(
            frame: NSRect(x: 0, y: 0,
                          width: max(initial.width, 1),
                          height: max(initial.height, 1)),
            textContainer: container)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 4, height: 10)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        layoutManager.highlightColor = highlightColor
        layoutManager.owner = view
        view.onEdit = { [weak view] in
            text = view?.string ?? ""
            onEdit()
        }
        context.coordinator.applied = nil

        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? RegexSampleTextView else { return }
        if let layoutManager = view.layoutManager as? MatchHighlightLayoutManager {
            layoutManager.highlightColor = highlightColor
        }
        // Only replace text when it changed outside the view (initial load);
        // otherwise typing would fight the binding.
        if view.string != text {
            view.string = text
        }
        if context.coordinator.applied != highlights {
            view.applyHighlights(highlights)
            context.coordinator.applied = highlights
        }
        if context.coordinator.appliedSelection != selection {
            // Setting a selection on an NSTextView makes it first responder,
            // which would steal keyboard focus away from the match list the
            // user is walking with the arrows. Apply the selection, then
            // restore whatever element held focus.
            let previousResponder = view.window?.firstResponder
            view.setSelectedRange(selection ?? NSRange(location: 0, length: 0))
            // Inspecting a match must surface the span: scroll it into view
            // even when the match list selection changed it from off-screen.
            if let selection {
                view.scrollRangeToVisible(selection)
            }
            if let previousResponder, previousResponder !== view {
                view.window?.makeFirstResponder(previousResponder)
            }
            context.coordinator.appliedSelection = selection
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: [NSRange]?
        var appliedSelection: NSRange?
    }
}
