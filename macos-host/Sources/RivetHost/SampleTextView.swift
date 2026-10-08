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
        guard let owner, !owner.highlightRanges.isEmpty,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil) else { return }
        let visibleChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let path = NSBezierPath()

        for range in owner.highlightRanges {
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

struct SampleTextView: NSViewRepresentable {
    @Binding var text: String
    var highlightColor: NSColor
    var highlights: [NSRange]
    var selection: NSRange?
    var onEdit: () -> Void

    typealias NSViewType = NSScrollView

    func makeNSView(context: Context) -> NSScrollView {
        let view = RegexSampleTextView()
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 4, height: 10)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainer?.lineFragmentPadding = 6
        // Force the default layout manager to exist, then swap in the one
        // that paints highlights as rounded pills.
        _ = view.layoutManager
        let rounded = MatchHighlightLayoutManager()
        rounded.highlightColor = highlightColor
        rounded.owner = view
        view.textContainer?.replaceLayoutManager(rounded)
        view.string = text
        view.onEdit = { [weak view] in
            text = view?.string ?? ""
            onEdit()
        }
        context.coordinator.applied = nil

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
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
            view.setSelectedRange(selection ?? NSRange(location: 0, length: 0))
            context.coordinator.appliedSelection = selection
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: [NSRange]?
        var appliedSelection: NSRange?
    }
}
