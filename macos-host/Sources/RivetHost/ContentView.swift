import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var patternFocused: Bool
    @State private var selectedMatch: Int?

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
            .frame(width: 620)
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.matches.enumerated()), id: \.offset) { index, match in
                        matchRow(index: index, match: match)
                        Divider().overlay(RM.Color_.hairline.opacity(0.6))
                    }
                }
            }
        }
    }

    private func matchRow(index: Int, match: MatchSpan) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(RM.Color_.ink3)
                .frame(width: 18, alignment: .trailing)
            Text(match.text.isEmpty ? "∅" : match.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RM.Color_.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("[\(match.start), \(match.end))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(RM.Color_.ink3)
            if match.groups > 0 {
                Text(match.groups == 1 ? "1 group" : "\(match.groups) groups")
                    .font(.system(size: 10))
                    .foregroundStyle(RM.Color_.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(RM.Color_.accentTint))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selectedMatch == index ? RM.Color_.accentTint.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedMatch = (selectedMatch == index) ? nil : index }
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
            Text("\(model.matches.count) match\(model.matches.count == 1 ? "" : "es")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RM.Color_.ink2)
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

    private var spanRanges: [SpanRange] {
        let ns = model.sample as NSString
        let limit = ns.length
        return model.matches.enumerated().compactMap { index, match in
            let start = min(match.start, limit)
            let end = min(match.end, limit)
            guard end > start else { return nil }
            return SpanRange(matchIndex: index, range: NSRange(location: start, length: end - start))
        }
    }

    private var sampleRanges: [NSRange] { spanRanges.map(\.range) }

    private var selectedRange: NSRange? {
        guard let selectedMatch else { return nil }
        return spanRanges.first(where: { $0.matchIndex == selectedMatch })?.range
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Pattern field (toolbar command surface)

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
            TextField("/\\d+/", text: $pattern)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(RM.Color_.ink)
                .focused(focused)
                .onSubmit(onSubmit)
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
