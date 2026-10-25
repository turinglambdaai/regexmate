import AppKit
import ApplicationServices
import Foundation

// Accessibility-driven UI acceptance for the macOS host. Every interaction
// goes through the Accessibility API (presses, value writes, attribute
// reads) — no synthetic pointer coordinates — so the run exercises the same
// surface an assistive technology uses. The one focus-dependent step (arrow
// keys on the match list) runs only when the app owns the key window, and
// records honestly in the trace when it had to skip.
enum DriverError: Error, CustomStringConvertible {
    case failure(String)
    var description: String { switch self { case .failure(let message): return message } }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func stringAttribute(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

// macOS 26 exposes the application element as its own child — an AX cycle.
// An unguarded walk either recurses until the stack overflows (SIGSEGV mid
// AX call) or, depth-capped alone, re-walks the self-chain exponentially and
// times out. Skip anything already on the walked path; the depth cap stays
// as belt-and-suspenders for malformed trees.
func sameAXElement(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }
func walk(_ element: AXUIElement, depth: Int = 0, ancestors: [AXUIElement] = []) -> [AXUIElement] {
    guard depth < 24 else { return [element] }
    let path = ancestors + [element]
    return [element] + children(element)
        .filter { child in !path.contains { sameAXElement($0, child) } }
        .flatMap { walk($0, depth: depth + 1, ancestors: path) }
}
func waitFor<T>(_ description: String, timeout: TimeInterval = 45, probe: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline { if let value = probe() { return value }; Thread.sleep(forTimeInterval: 0.05) }
    throw DriverError.failure("timed out waiting for \(description)")
}
func findButton(_ root: AXUIElement, names: Set<String>) -> AXUIElement? {
    walk(root).first { element in
        stringAttribute(element, kAXRoleAttribute) == (kAXButtonRole as String) &&
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
                .contains { names.contains(stringAttribute(element, $0)) }
    }
}
func findByIdentifier(_ root: AXUIElement, _ identifier: String) -> AXUIElement? {
    walk(root).first { stringAttribute($0, kAXIdentifierAttribute) == identifier }
}
func enabled(_ element: AXUIElement) -> Bool { attribute(element, kAXEnabledAttribute) as? Bool ?? false }
func findMatchTable(_ root: AXUIElement) -> AXUIElement? {
    walk(root).first {
        stringAttribute($0, kAXRoleAttribute) == "AXTable" &&
            stringAttribute($0, kAXIdentifierAttribute) == "MatchList"
    }
}
func tableRows(_ table: AXUIElement) -> [AXUIElement] {
    (attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []
}
// The structured row name lives on the row's content cell.
func rowName(_ row: AXUIElement) -> String {
    for child in children(row) {
        let description = stringAttribute(child, kAXDescriptionAttribute)
        if !description.isEmpty { return description }
    }
    return stringAttribute(row, kAXDescriptionAttribute)
}
func selectTableRow(_ table: AXUIElement, _ row: AXUIElement, _ what: String) throws {
    guard AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success else {
        throw DriverError.failure("AX selected-rows write failed for \(what)")
    }
}
func contains(_ root: AXUIElement, fragment: String) -> Bool {
    walk(root).contains { element in
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .contains { stringAttribute(element, $0).contains(fragment) }
    }
}
func press(_ element: AXUIElement, _ what: String) throws {
    guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for \(what)")
    }
}
// The sample editor is the only text area; the pattern is a text field.
func findTextArea(_ root: AXUIElement) -> AXUIElement? {
    walk(root).first { stringAttribute($0, kAXRoleAttribute) == (kAXTextAreaRole as String) }
}
func findTextField(_ root: AXUIElement) -> AXUIElement? {
    walk(root).first { stringAttribute($0, kAXRoleAttribute) == (kAXTextFieldRole as String) }
}
func selectedEditorText(_ root: AXUIElement) throws -> String {
    guard let editor = findTextArea(root) else { throw DriverError.failure("sample editor not found") }
    return stringAttribute(editor, kAXSelectedTextAttribute)
}
func setSelectedText(_ element: AXUIElement, _ value: String, _ what: String) throws {
    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
        throw DriverError.failure("AX value write failed for \(what)")
    }
}
func pressMenuItem(_ application: AXUIElement, _ title: String) throws {
    // kAXMenuBarAttribute yields the single menu-bar element; its children
    // are the per-menu items.
    guard let menuBarRef = attribute(application, kAXMenuBarAttribute) else {
        throw DriverError.failure("no menu bar on the app element")
    }
    let menuBar = menuBarRef as! AXUIElement
    guard let matchMenu = children(menuBar).first(where: { stringAttribute($0, kAXTitleAttribute) == "Match" }) else {
        throw DriverError.failure("Match menu not found")
    }
    // Opening the menu populates its Accessibility children.
    try press(matchMenu, "Match menu")
    let deadline = Date().addingTimeInterval(5)
    var item: AXUIElement?
    while Date() < deadline && item == nil {
        let menu = children(matchMenu).first(where: { stringAttribute($0, kAXRoleAttribute) == (kAXMenuRole as String) }) ?? matchMenu
        item = children(menu).first(where: { stringAttribute($0, kAXTitleAttribute) == title })
        if item == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    guard let item else {
        _ = AXUIElementPerformAction(matchMenu, kAXCancelAction as CFString)
        throw DriverError.failure("Match menu item not found: \(title)")
    }
    try press(item, title)
    usleep(200_000)
}

// Menu presses race the system's menu tracking; retry open→press until the
// observable effect lands.
func activateMenuItem(_ application: AXUIElement, _ title: String, timeout: TimeInterval = 5, until probe: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    var pressFailed = false
    while Date() < deadline {
        if probe() { return }
        do {
            try pressMenuItem(application, title)
        } catch {
            pressFailed = true
        }
        let step = Date().addingTimeInterval(2)
        while Date() < step {
            if probe() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    if pressFailed {
        throw DriverError.failure("menu action \(title) could not be pressed")
    }
    throw DriverError.failure("menu action \(title) did not take effect")
}
func pressArrowKey(_ keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
    down.post(tap: .cghidEventTap); usleep(40_000); up.post(tap: .cghidEventTap)
    usleep(250_000)
}
func typeText(_ text: String) {
    for scalar in text.unicodeScalars {
        let units = Array(String(scalar).utf16)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap); usleep(20_000)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.post(tap: .cghidEventTap); usleep(40_000)
    }
}
func frameOf(_ element: AXUIElement) -> CGRect? {
    var pointVal: CFTypeRef?
    var sizeVal: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pointVal) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
          let point = pointVal, let size = sizeVal else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(point as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func clickElementCenter(_ element: AXUIElement, _ what: String) throws {
    guard let rect = frameOf(element) else {
        throw DriverError.failure("no frame for \(what)")
    }
    let point = CGPoint(x: rect.midX, y: rect.midY)
    let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
    move.post(tap: .cghidEventTap); usleep(80_000)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!
    down.post(tap: .cghidEventTap); usleep(60_000); up.post(tap: .cghidEventTap)
    usleep(250_000)
}

func selectAllAndType(_ text: String) {
    // ⌘A, then type the replacement over the selection.
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    down.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap); usleep(30_000); up.post(tap: .cghidEventTap)
    usleep(120_000)
    typeText(text)
    usleep(150_000)
}
func snapshot(_ element: AXUIElement, depth: Int = 0, ancestors: [AXUIElement] = []) -> [String: Any] {
    var result: [String: Any] = ["role": stringAttribute(element, kAXRoleAttribute), "identifier": stringAttribute(element, kAXIdentifierAttribute), "title": stringAttribute(element, kAXTitleAttribute), "label": stringAttribute(element, kAXDescriptionAttribute), "value": stringAttribute(element, kAXValueAttribute)]
    if depth < 8 {
        let path = ancestors + [element]
        result["children"] = children(element)
            .filter { child in !path.contains { sameAXElement($0, child) } }
            .map { snapshot($0, depth: depth + 1, ancestors: path) }
    }
    return result
}
func writeJSON(_ value: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url) }

var diagnosticApplication: AXUIElement?
var diagnosticOutput: URL?
var actions: [String] = []
var assertions: [String] = []
var skipped: [String] = []

func writeTrace() {
    guard let output = diagnosticOutput else { return }
    let trace: [String: Any] = ["platform": "macos", "actions": actions, "assertions": assertions, "skipped": skipped]
    try? writeJSON(trace, to: output.appendingPathComponent("interaction-trace.json"))
}

do {
    let arguments = CommandLine.arguments
    guard let pidIndex = arguments.firstIndex(of: "--pid"), pidIndex + 1 < arguments.count,
          let pid = Int32(arguments[pidIndex + 1]),
          let outputIndex = arguments.firstIndex(of: "--output"), outputIndex + 1 < arguments.count else {
        throw DriverError.failure("usage: macos-ax --pid PID --output DIRECTORY")
    }
    let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
    diagnosticOutput = output
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard AXIsProcessTrusted() else { throw DriverError.failure("accessibility access is unavailable") }
    let application = AXUIElementCreateApplication(pid)
    diagnosticApplication = application
    let window: AXUIElement = try waitFor("RegexMate window") { (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first }
    _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let refresh: AXUIElement = try waitFor("enabled Run regex button") {
        guard let button = findButton(window, names: ["RefreshButton", "Run regex"]), enabled(button) else { return nil }
        return button
    }
    try press(refresh, "Run regex")
    actions.append("press:Run regex")
    _ = try waitFor("match count from embedded backend") { contains(window, fragment: "5 matches") ? true : nil }
    assertions.append("packaged SwiftUI window activated")
    assertions.append("Run regex exposed through Accessibility")
    assertions.append("request crossed RVT1 into the embedded backend")
    assertions.append("native UI reports 5 matches")

    // -- Match rows expose the inspection contract to assistive technology --
    let table: AXUIElement = try waitFor("match table") { findMatchTable(window) }
    let rows: [AXUIElement] = try waitFor("five match rows") {
        let found = tableRows(table)
        return found.count == 5 ? found : nil
    }
    let row2Label = rowName(rows[1])
    guard row2Label.contains("Match 2 of 5"), row2Label.contains("'2026'"), row2Label.contains("characters 23–27") else {
        throw DriverError.failure("match row label incomplete: \(row2Label)")
    }
    assertions.append("match row names index, matched text, span and order to Accessibility")

    // -- Row activation inspects the same span in the editor --
    try selectTableRow(table, rows[1], "match row 2")
    actions.append("select:match row 2")
    _ = try waitFor("editor selection '2026'") { (try? selectedEditorText(window)) == "2026" ? true : nil }
    assertions.append("activating a match row selects the same span in the sample editor")

    // -- ⌘G / ⌘⇧G via the Match menu: keyboard reachability without a pointer --
    try activateMenuItem(application, "Inspect Next Match") { (try? selectedEditorText(window)) == "09" }
    actions.append("menu:Inspect Next Match")
    assertions.append("Match menu next/previous walks matches with the same meaning")
    try activateMenuItem(application, "Inspect Previous Match") { (try? selectedEditorText(window)) == "2026" }
    try activateMenuItem(application, "Inspect Previous Match") { (try? selectedEditorText(window)) == "12345" }
    actions.append("menu:Inspect Previous Match ×2")

    // -- Arrow keys on the focused list (needs the key window; runs only when
    //    the app owns it, e.g. on an unattended runner) --
    _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    usleep(300_000)
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    if frontPid == pid {
        try selectTableRow(table, rows[0], "match row 1")
        _ = AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(300_000)
        pressArrowKey(125)  // down
        _ = try waitFor("editor selection '2026' after Down") { (try? selectedEditorText(window)) == "2026" ? true : nil }
        pressArrowKey(125)
        _ = try waitFor("editor selection '09' after Down") { (try? selectedEditorText(window)) == "09" ? true : nil }
        pressArrowKey(126)  // up
        _ = try waitFor("editor selection '2026' after Up") { (try? selectedEditorText(window)) == "2026" ? true : nil }
        actions.append("keys:Down Down Up on focused match list")
        assertions.append("arrow keys move the inspection along the match list")
    } else {
        actions.append("skip:arrow keys (front window held by pid \(frontPid))")
        skipped.append("arrow-key navigation: the key window was held by another process during this run")
    }

    // -- Sample-driven fixtures: the sample editor is a real AppKit text
    //    view, so AX value writes flow through didChangeText into the model --
    guard let editor = findTextArea(window) else { throw DriverError.failure("sample editor not found") }

    // Unicode mapping: with the default \d+ pattern, the engine reports
    // code-point offsets; the editor must select the same characters when a
    // surrogate pair (astral emoji) sits before the match.
    try setSelectedText(editor, "咖啡42 🌟10115 zip.", "sample editor")
    actions.append("value:sample=unicode")
    _ = try waitFor("unicode fixture rows") { () -> Bool? in
        let found = tableRows(table)
        guard found.count >= 1 else { return nil }
        return rowName(found[0]).contains("'42'") ? true : nil
    }
    try selectTableRow(table, tableRows(table)[0], "BMP match row")
    actions.append("select:BMP match row")
    _ = try waitFor("editor selection '42'") { (try? selectedEditorText(window)) == "42" ? true : nil }
    try selectTableRow(table, tableRows(table)[1], "astral-adjacent match row")
    actions.append("select:astral-adjacent match row")
    _ = try waitFor("editor selection '10115'") { (try? selectedEditorText(window)) == "10115" ? true : nil }
    assertions.append("Unicode (BMP and astral) matches inspect the exact span in the editor")

    // -- Live edits never leave the selection on a removed match --
    try setSelectedText(editor, "Order 99 shipped.", "sample editor")
    actions.append("value:sample=live edit")
    _ = try waitFor("selection cleared after the result list changed") { () -> Bool? in
        guard let count = findByIdentifier(window, "MatchCount").flatMap({ stringAttribute($0, kAXValueAttribute) }), count == "1 match", tableRows(table).count == 1 else { return nil }
        return (try? selectedEditorText(window)) == "" ? true : nil
    }
    assertions.append("a live edit that changes the result list clears the inspection selection")

    // -- Pattern-driven fixtures: the pattern field is a real control, so
    //    Accessibility value writes flow into the model --
    guard let patternField = findTextField(window) else { throw DriverError.failure("pattern field not found") }

    // Zero-width matches are named distinctly and inspect by caret.
    try setSelectedText(patternField, "x*", "pattern field")
    actions.append("value:pattern=x*")
    _ = try waitFor("zero-width match row") { () -> Bool? in
        let found = tableRows(table)
        guard found.count >= 1 else { return nil }
        return rowName(found[0]).contains("zero-width") ? true : nil
    }
    try selectTableRow(table, tableRows(table)[0], "zero-width match row")
    actions.append("select:zero-width match row")
    usleep(300_000)
    let zeroSelection = try selectedEditorText(window)
    guard zeroSelection == "" else { throw DriverError.failure("zero-width inspection did not place the caret: '\(zeroSelection)'") }
    assertions.append("zero-width matches are named distinctly and inspect by caret placement")

    // Invalid patterns are an error state, not a zero-match result.
    try setSelectedText(patternField, "[", "pattern field")
    actions.append("value:pattern=[ (invalid)")
    _ = try waitFor("invalid-pattern error state") { () -> Bool? in
        guard let count = findByIdentifier(window, "MatchCount").flatMap({ stringAttribute($0, kAXValueAttribute) }) else { return nil }
        return (count == "—" && tableRows(table).isEmpty) ? true : nil
    }
    assertions.append("invalid pattern reports the error, not a valid zero-match result")

    try setSelectedText(patternField, "\\d+", "pattern field")
    actions.append("value:pattern=\\d+ (restored)")

    // -- The pattern entry stays reachable at the compact window width --
    var size = CGSize(width: 980, height: 600)
    guard let windowSize = AXValueCreate(.cgSize, &size) else { throw DriverError.failure("AXValueCreate failed") }
    guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, windowSize) == .success else {
        throw DriverError.failure("could not resize the window to the compact width")
    }
    actions.append("size:window=980×600")
    usleep(500_000)
    guard let compactPattern = findByIdentifier(window, "PatternField"), enabled(compactPattern) else {
        throw DriverError.failure("pattern field unavailable at the compact window width")
    }
    assertions.append("pattern entry remains usable at the supported compact width")

    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility.json"))
    let trace: [String: Any] = ["platform": "macos", "actions": actions, "assertions": assertions, "skipped": skipped]
    try writeJSON(trace, to: output.appendingPathComponent("interaction-trace.json"))
    guard let running = NSRunningApplication(processIdentifier: pid), running.terminate() else { throw DriverError.failure("native application rejected termination") }
} catch {
    if let application = diagnosticApplication, let output = diagnosticOutput {
        try? writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-failure.json"))
        let trace: [String: Any] = ["platform": "macos", "actions": actions, "assertions": assertions, "skipped": skipped, "failure": "\(error)"]
        try? writeJSON(trace, to: output.appendingPathComponent("interaction-trace.json"))
    }
    FileHandle.standardError.write(Data("RegexMate macOS acceptance failed: \(error)\n".utf8))
    exit(1)
}
