import SwiftUI
import AppKit

// MARK: - The native result list
//
// An NSTableView, deliberately not a SwiftUI list: selecting a row is
// inspecting the match, and the table is a real first responder. Tab reaches
// it, the arrow keys walk it, and assistive technology both selects its rows
// and presses them — on every machine, with or without full keyboard access.

// One row: exposes the inspection action to assistive technology (AXPress)
// and carries the structured row name.
final class MatchTableRowView: NSTableRowView {
    var onPress: (() -> Void)?
    private var rowLabel = ""
    private var rowIdentifier = ""

    // Keep the selected-row tint at its normal strength even when the table
    // is not the key view (the editor is often first responder instead).
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    func setRowAccessibility(label: String, identifier: String) {
        rowLabel = label
        rowIdentifier = identifier
    }

    // NSTableRowView owns its attribute routing, so the structured name and
    // the inspection action are surfaced at the attribute/action layer.
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute.rawValue {
        case NSAccessibility.Attribute.description.rawValue where !rowLabel.isEmpty:
            return rowLabel
        case NSAccessibility.Attribute.identifier.rawValue where !rowIdentifier.isEmpty:
            return rowIdentifier
        default:
            return super.accessibilityAttributeValue(attribute)
        }
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        super.accessibilityActionNames() + [.press]
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        if action == .press {
            onPress?()
            return
        }
        super.accessibilityPerformAction(action)
    }
}

// One row's content: ordinal, matched text (∅ for zero-width), span, and
// the capture-group badge.
final class MatchCellView: NSTableCellView {
    private let ordinal = NSTextField(labelWithString: "")
    private var cellLabel = ""
    private let value = NSTextField(labelWithString: "")
    private let span = NSTextField(labelWithString: "")
    private let zeroWidth = NSTextField(labelWithString: "zero-width")
    private let groups = NSTextField(labelWithString: "")

    // The row view carries the accessible identity; the cell is pure content.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityLabel() -> String { cellLabel }

    init() {
        super.init(frame: .zero)
        ordinal.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        ordinal.textColor = .tertiaryLabelColor
        ordinal.alignment = .right
        ordinal.setContentHuggingPriority(.required, for: .horizontal)
        value.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .labelColor
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        span.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        span.textColor = .tertiaryLabelColor
        span.setContentHuggingPriority(.required, for: .horizontal)
        zeroWidth.font = NSFont.systemFont(ofSize: 10)
        zeroWidth.textColor = .tertiaryLabelColor
        zeroWidth.setContentHuggingPriority(.required, for: .horizontal)
        groups.font = NSFont.systemFont(ofSize: 10)
        groups.textColor = .controlAccentColor
        groups.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [ordinal, value, zeroWidth, span, groups])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        zeroWidth.isHidden = true
        groups.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(index: Int, match: MatchSpan) {
        cellLabel = MatchTableController.accessibilityLabel(index: index, match: match, total: total)
        ordinal.stringValue = "\(index + 1)"
        value.stringValue = match.text.isEmpty ? "∅" : match.text
        span.stringValue = "[\(match.start), \(match.end))"
        zeroWidth.isHidden = !match.text.isEmpty
        let groupCount = match.groups
        groups.isHidden = groupCount == 0
        groups.stringValue = groupCount == 1 ? "1 group" : "\(groupCount) groups"
    }

    var total = 1
}

final class MatchTableController: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    var matches: [MatchSpan] = []
    var synchronizing = false
    var onSelect: ((Int?) -> Void)?
    weak var tableView: NSTableView?

    func numberOfRows(in _: NSTableView) -> Int { matches.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let cell = MatchCellView()
        cell.total = matches.count
        cell.configure(index: row, match: matches[row])
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MatchTableRowView()
        rowView.setRowAccessibility(
            label: Self.accessibilityLabel(index: row, match: matches[row], total: matches.count),
            identifier: "MatchRow-\(row + 1)")
        rowView.onPress = { [weak self] in
            guard let self, matches.indices.contains(row) else { return }
            // One meaning: activating a row inspects the match. Selecting it
            // also focuses the table, so the arrows keep walking the list.
            tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView?.scrollRowToVisible(row)
        }
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizing else { return }
        let row = (notification.object as? NSTableView)?.selectedRow ?? -1
        onSelect?(row >= 0 ? row : nil)
    }

    // One assistive name per row spelling out the inspection contract: which
    // match of how many, the matched text or zero-width position, the span,
    // and the capture-group count.
    static func accessibilityLabel(index: Int, match: MatchSpan, total: Int) -> String {
        let ordinal = "Match \(index + 1) of \(total)"
        let spanDescription: String
        if match.text.isEmpty {
            spanDescription = "zero-width match at character \(match.start)"
        } else {
            spanDescription = "'\(match.text)', characters \(match.start)–\(match.end)"
        }
        let groupDescription: String
        switch match.groups {
        case 0: groupDescription = ""
        case 1: groupDescription = ", 1 capture group"
        default: groupDescription = ", \(match.groups) capture groups"
        }
        return "\(ordinal): \(spanDescription)\(groupDescription)"
    }
}

struct MatchTableView: NSViewRepresentable {
    let matches: [MatchSpan]
    @Binding var selectedMatch: Int?

    func makeCoordinator() -> MatchTableController {
        let controller = MatchTableController()
        controller.onSelect = { row in
            selectedMatch = row
        }
        return controller
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match")))
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowHeight = 27
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.setAccessibilityIdentifier("MatchList")
        context.coordinator.tableView = table
        context.coordinator.matches = matches
        table.reloadData()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        if coordinator.matches != matches {
            coordinator.matches = matches
            coordinator.synchronizing = true
            table.reloadData()
            coordinator.synchronizing = false
        }
        // Reflect externally-driven inspection changes (⌘G / ⌘⇧G, result
        // invalidation) in the table without re-entering the handler.
        let wanted = selectedMatch ?? -1
        if table.selectedRow != wanted {
            coordinator.synchronizing = true
            if matches.indices.contains(wanted) {
                table.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
                table.scrollRowToVisible(wanted)
            } else {
                table.deselectAll(nil)
            }
            coordinator.synchronizing = false
        }
    }
}
