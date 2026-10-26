import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var patternFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            columns
                .padding(16)

            Divider().overlay(RM.Color_.hairline)
            statusBar
        }
        .background(RM.Color_.bg)
        .toolbar { toolbarContent }
    }

    // MARK: - Toolbar: the pattern bar (the app's one command surface)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            PatternField(
                pattern: $model.pattern,
                focused: $patternFocused,
                error: model.patternError
            ) {
                model.refreshNow()
            }
            // Flex below the ideal width so the pattern stays editable at
            // the window's compact width and under enlarged system text;
            // the principal toolbar item must compress, not clip.
            .frame(minWidth: 280, idealWidth: 620, maxWidth: 620)
            .accessibilityIdentifier("PatternField")
        }
        ToolbarItem {
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.isReady || model.busy)
            .help("Run (⌘R)")
            .accessibilityIdentifier("RefreshButton")
            .accessibilityLabel("Run regex")
        }
        ToolbarItem {
            Button {
                model.exportReport()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(!model.isReady)
            .help("Export HTML report")
        }
    }

    // MARK: - Two draggable columns

    private var columns: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            rightColumn
                .frame(minWidth: 340, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "text.alignleft", title: "TEST TEXT")
                Card(padding: 0) {
                    SampleTextView(
                        text: $model.sample,
                        highlightColor: NSColor(name: nil) { appearance in
                            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                            return dark
                                ? NSColor(srgbRed: 0.24, green: 0.81, blue: 0.56, alpha: 0.26)
                                : NSColor(srgbRed: 0.01, green: 0.48, blue: 0.33, alpha: 0.18)
                        },
                        highlights: sampleRanges,
                        selection: selectedRange,
                        onEdit: { model.scheduleRefresh() }
                    )
                    .frame(height: 168)
                }
                .clipShape(RoundedRectangle(cornerRadius: RM.radiusS))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "text.magnifyingglass", title: "MATCHES",
                              trailing: model.matches.isEmpty ? nil : "\(model.matches.count)")
                Card(padding: 0) {
                    matchList
                }
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: RM.radiusS))
            }
        }
    }

    @ViewBuilder
    private var matchList: some View {
        if model.matches.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(RM.Color_.ink3)
                Text(model.patternError == nil ? "No matches" : "Fix the pattern to match")
                    .font(.system(size: 12))
                    .foregroundStyle(RM.Color_.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The host's result-selection model: one selection means
            // "inspect this match" — the sample editor selects the same span.
            // The native table gives the interaction to the keyboard (the
            // list is a first responder: Tab reaches it, arrows walk it) and
            // to assistive activation, not just the pointer.
            MatchTableView(matches: model.matches, selectedMatch: $model.selectedMatch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "text.book.closed", title: "EXPLANATION")
                    Card {
                        Text(model.explanation.isEmpty ? "—" : model.explanation)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(RM.Color_.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "flag.2.crossed", title: "LINT FINDINGS",
                                  trailing: model.findings.isEmpty ? nil : "\(model.findings.count)")
                    Card {
                        lintList
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "flowchart", title: "RAILROAD DIAGRAM")
                    Card(padding: 0) {
                        ZStack {
                            Rectangle().fill(RM.Color_.canvas)
                            if let image = model.diagram {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .padding(10)
                            } else {
                                Text("No diagram")
                                    .font(.system(size: 12))
                                    .foregroundStyle(RM.Color_.ink3)
                            }
                        }
                        .frame(height: 210)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: RM.radiusS))
                }
            }
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private var lintList: some View {
        if model.findings.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 12))
                    .foregroundStyle(RM.Color_.ok)
                Text("No lint findings")
                    .font(.system(size: 12))
                    .foregroundStyle(RM.Color_.ink2)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.findings.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 {
                        Divider().overlay(RM.Color_.hairline.opacity(0.6))
                    }
                    HStack(alignment: .top, spacing: 9) {
                        SeverityChip(severity: finding.severity)
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(finding.rule)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RM.Color_.ink)
                                Text("@\(finding.position)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RM.Color_.ink3)
                            }
                            Text(finding.message)
                                .font(.system(size: 12))
                                .foregroundStyle(RM.Color_.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    // MARK: - Bottom status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Starting embedded Racket CS…")
            case .failed(let message):
                statusDot(RM.Color_.danger)
                Text("Backend: \(message)").lineLimit(1)
            case .ready:
                if model.busy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running…")
                } else {
                    statusDot(model.patternError == nil ? RM.Color_.ok : RM.Color_.danger)
                    Text(model.patternError ?? "Embedded Racket CS is ready")
                        .lineLimit(1)
                }
            }
            Spacer()
            // An invalid pattern is an error state, not a zero-match result:
            // the count yields to the error message on the left.
            Text(model.patternError == nil
                  ? "\(model.matches.count) match\(model.matches.count == 1 ? "" : "es")"
                  : "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RM.Color_.ink2)
                .accessibilityIdentifier("MatchCount")
            Text("·").foregroundStyle(RM.Color_.ink3)
            Text("\(model.findings.count) finding\(model.findings.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RM.Color_.ink2)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(RM.Color_.ink2)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    // MARK: - Highlight ranges and row->editor selection

    private struct SpanRange {
        let matchIndex: Int
        let range: NSRange
    }

    // The engine reports code-point offsets; NSTextView ranges are UTF-16
    // units. Convert each boundary so highlights and selection land on the
    // same characters (astral-plane scalars occupy two UTF-16 units). An
    // offset past the end clamps to the text length.
    private func utf16Location(ofCodePointOffset offset: Int, in text: String) -> Int {
        var location = 0
        var remaining = offset
        for scalar in text.unicodeScalars {
            if remaining <= 0 { break }
            remaining -= 1
            location += scalar.value >= 0x10000 ? 2 : 1
        }
        return location
    }

    private var spanRanges: [SpanRange] {
        let ns = model.sample as NSString
        let limit = ns.length
        return model.matches.enumerated().compactMap { index, match in
            let start = min(utf16Location(ofCodePointOffset: match.start, in: model.sample), limit)
            let end = min(utf16Location(ofCodePointOffset: match.end, in: model.sample), limit)
            guard end >= start else { return nil }
            return SpanRange(matchIndex: index, range: NSRange(location: start, length: end - start))
        }
    }

    private var sampleRanges: [NSRange] { spanRanges.map(\.range) }

    private var selectedRange: NSRange? {
        guard let selectedMatch = model.selectedMatch else { return nil }
        return spanRanges.first(where: { $0.matchIndex == selectedMatch })?.range
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Pattern field (toolbar command surface)
//
// A real NSTextField, not a SwiftUI TextField: the embedded-runtime hosts and
// the acceptance driver change the pattern through Accessibility value writes,
// which update a control value directly but bypass a SwiftUI binding. KVO on
// the control value and the editor delegate both funnel into the model, so
// programmatic writes, typing and ⌘R all observe the same pattern.

// The field and its coordinator funnel every write path into the model.
// Typing goes through the editor delegate. Accessibility value writes land
// in the cell and never reach the control, so the submit paths (the field's
// action and the delegate's end-editing) sync the cell value into the
// binding before treating the write as a submit.
final class PatternTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { RegexKeyLoop.register(field: self) }
    }
}

final class PatternFieldCoordinator: NSObject, NSTextFieldDelegate {
    var onUpdate: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    weak var field: NSTextField?

    func controlTextDidChange(_: Notification) { onUpdate?() }
    func controlTextDidBeginEditing(_: Notification) { onFocus?(true) }
    func controlTextDidEndEditing(_: Notification) {
        onUpdate?()
        onFocus?(false)
    }

    @objc func submitted() {
        onUpdate?()
        onSubmit?()
    }
}

private struct PatternTextFieldView: NSViewRepresentable {
    @Binding var pattern: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    func makeCoordinator() -> PatternFieldCoordinator { PatternFieldCoordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = PatternTextField()
        field.stringValue = pattern
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        field.textColor = NSColor.textColor
        field.placeholderString = "/\\d+/"
        field.lineBreakMode = .byTruncatingTail
        context.coordinator.onUpdate = { [weak field] in
            pattern = field?.stringValue ?? ""
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocus = { focused.wrappedValue = $0 }
        context.coordinator.field = field
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(PatternFieldCoordinator.submitted)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != pattern {
            field.stringValue = pattern
        }
    }
}

struct PatternField: View {
    @Binding var pattern: String
    var focused: FocusState<Bool>.Binding
    var error: String?
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(error == nil ? RM.Color_.accent : RM.Color_.danger)
            PatternTextFieldView(pattern: $pattern, focused: focused, onSubmit: onSubmit)
            if error != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(RM.Color_.danger)
                    .help(error ?? "")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(RM.Color_.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    focused.wrappedValue
                        ? RM.Color_.accent.opacity(0.75)
                        : RM.Color_.hairline,
                    lineWidth: focused.wrappedValue ? 1.5 : 1
                )
        )
    }
}
