import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// Accessibility-driven UI acceptance for the macOS host. Every interaction
// goes through the Accessibility API (presses, value writes, attribute
// reads) or real CGEvent keyboard input — no synthetic pointer coordinates —
// so the run exercises the same surface an assistive technology or a
// keyboard-only user exercises. Holding the key window is a hard
// precondition asserted up front: the scenario's value is precisely the
// full keyboard path (type → submit → Tab → arrows → ⌘R → error recovery).
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
// The pattern field's AX value write lands in the cell; AXConfirm carries
// it into the model (the field syncs the cell value on confirm).
func confirmPattern(_ field: AXUIElement, _ value: String, _ what: String) throws {
    try setSelectedText(field, value, what)
    guard AXUIElementPerformAction(field, "AXConfirm" as CFString) == .success else {
        throw DriverError.failure("AXConfirm failed for \(what)")
    }
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
    // A value write can fail transiently while the host is mid-refresh.
    for attempt in 0..<4 {
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        if result == .success { return }
        if attempt == 3 {
            throw DriverError.failure("AX value write failed for \(what) (\(result))")
        }
        Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1))
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

// MARK: keyboard-path primitives (shape taken from the rivet reference
// driver: focus asserts kAXFocusedAttribute, keys go through CGEvent)

let kReturnKeyCode: CGKeyCode = 36
let kEscapeKeyCode: CGKeyCode = 53
let kTabKeyCode: CGKeyCode = 48
let kRKeyCode: CGKeyCode = 15
let kDownArrowKeyCode: CGKeyCode = 125
let kUpArrowKeyCode: CGKeyCode = 126

// ANSI keycodes for the characters the keyboard scenarios need (shift flag
// produces the shifted glyph on the ASCII layout selected for typing).
let kAKeyCode: CGKeyCode = 0
let kDKeyCode: CGKeyCode = 2
let kXKeyCode: CGKeyCode = 7
let kMinusKeyCode: CGKeyCode = 27
let kEqualKeyCode: CGKeyCode = 24 // '+' with shift
let kLeftBracketKeyCode: CGKeyCode = 33 // '[' plain, '{' with shift
let kRightBracketKeyCode: CGKeyCode = 30 // ']' plain, '}' with shift
let kBackslashKeyCode: CGKeyCode = 42
let kEightKeyCode: CGKeyCode = 28 // '*' with shift
let kTwoKeyCode: CGKeyCode = 19

// MARK: input source (an active IME consumes synthetic unicode-string key
// events before they reach the app, so real typing must be asserted on a
// plain ASCII layout; the switch uses the same public TIS API a user's
// layout switch uses, and the original source is restored afterwards)

func inputSourceProperty(_ source: TISInputSource, _ key: CFString) -> CFTypeRef? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return unsafeBitCast(raw, to: CFTypeRef.self)
}

func currentInputSource() -> TISInputSource? {
    TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
}

func asciiKeyboardLayout() -> TISInputSource? {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
    // ASCII-capable sources are plain keyboard layouts; IME input modes are
    // never ASCII-capable, so no further kind filtering is needed.
    return list.first { source in
        guard let ascii = inputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable as CFString) as? Bool,
              ascii else { return false }
        return true
    }
}

func switchInputSource(_ source: TISInputSource) -> Bool {
    TISSelectInputSource(source) == noErr
}

func isFocused(_ element: AXUIElement) -> Bool { attribute(element, kAXFocusedAttribute) as? Bool ?? false }

// AX focus with the reference driver's assertion: the write must be visible
// on the next read, otherwise later key events would land somewhere else.
func focus(_ element: AXUIElement, _ what: String) throws {
    guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        throw DriverError.failure("AX focus failed for \(what)")
    }
    guard isFocused(element) else { throw DriverError.failure("\(what) did not take focus") }
}

// The app element's focused-UI attribute is the canonical read of where
// keyboard input would land.
func focusedUIElement(_ application: AXUIElement) -> AXUIElement? {
    guard let value = attribute(application, kAXFocusedUIElementAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func describeFocused(_ application: AXUIElement) -> String {
    guard let element = focusedUIElement(application) else { return "none" }
    let role = stringAttribute(element, kAXRoleAttribute)
    let identifier = stringAttribute(element, kAXIdentifierAttribute)
    let value = stringAttribute(element, kAXValueAttribute)
    let suffix = value.isEmpty ? "" : " value='\(value)'"
    return identifier.isEmpty ? "\(role)\(suffix)" : "\(role)#\(identifier)\(suffix)"
}

func matchCount(_ window: AXUIElement) -> String? {
    findByIdentifier(window, "MatchCount").flatMap { stringAttribute($0, kAXValueAttribute) }
}
func waitForMatchCount(_ window: AXUIElement, _ expected: String, _ what: String) throws {
    _ = try waitFor("MatchCount '\(expected)' after \(what)") { matchCount(window) == expected ? true : nil }
}

// The AX element of the match table can go stale across result refreshes
// (SwiftUI may rebuild the representable's NSView); probe the live tree and
// re-acquire when the instance changed.
func reacquireTable(_ table: AXUIElement, _ window: AXUIElement, observations: [String]) -> (AXUIElement, [String]) {
    guard let live = findMatchTable(window), !sameAXElement(live, table) else { return (table, observations) }
    return (live, observations + ["match table NSView instance changed; driver re-acquired it"])
}

// Bounded no-change probe: the predicate must hold for the whole horizon or
// the run fails. This is how a negative contract ("typing alone must not run
// the engine") is asserted without pretending a sleep is a check.
func assertStable(_ what: String, horizon: TimeInterval = 0.8, probe: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(horizon)
    while Date() < deadline {
        guard probe() else { throw DriverError.failure("\(what) changed unexpectedly") }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// The real-keyboard path needs this application to hold the key window or
// the CGEvents land in whatever app the user is in; retry the activation
// inside the bounded probe instead of assuming it.
func waitFrontmost(_ application: AXUIElement, pid: pid_t, timeout: TimeInterval = 10) throws {
    _ = try waitFor("RegexMate to hold the key window", timeout: timeout) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? true : nil
    }
}

func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    down.flags = flags
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
    up.flags = flags
    down.post(tap: .cghidEventTap); usleep(40_000); up.post(tap: .cghidEventTap)
    usleep(200_000)
}

// Walk keyboard focus with real Tab presses until one of the targets holds
// it. Every visited element is logged so the trace records the actual focus
// order instead of assuming it.
func tabWalk(_ application: AXUIElement, targets: [AXUIElement], maxTabs: Int = 6, _ what: String) throws -> [String] {
    var log: [String] = []
    func onTarget() -> Bool {
        guard let current = focusedUIElement(application) else { return false }
        return targets.contains { sameAXElement($0, current) }
    }
    if onTarget() { return log }
    for _ in 0..<maxTabs {
        pressKey(kTabKeyCode)
        log.append(describeFocused(application))
        if onTarget() { return log }
    }
    throw DriverError.failure("Tab walk never reached \(what): \(log)")
}

// Capture one window by id, never the whole screen: the runner may be a
// developer machine with unrelated windows on it, and evidence must not
// include them.
func captureWindow(_ pid: pid_t, to output: URL, name: String) throws {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        throw DriverError.failure("CGWindowListCopyWindowInfo failed")
    }
    let id = list.first { info in
        (info[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
            (info[kCGWindowLayer as String] as? Int) == 0
    }.flatMap { $0[kCGWindowNumber as String] as? UInt32 }
    guard let id else { throw DriverError.failure("no on-screen window owned by pid \(pid)") }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", "\(id)", output.appendingPathComponent(name).path]
    try shot.run()
    shot.waitUntilExit()
    guard shot.terminationStatus == 0 else {
        throw DriverError.failure("screencapture \(name) exited with status \(shot.terminationStatus)")
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

func selectAll() {
    // ⌘A: keycode 0 ('a') with the command flag; modifier payloads ride on
    // keycode events and are not affected by input methods.
    pressKey(kAKeyCode, flags: .maskCommand)
    usleep(120_000)
}

// Type a pattern as real keycodes — the same shape a hardware keyboard
// produces (keycode + shift flag), with no synthetic unicode payload for an
// input method or text system to drop.
func typePattern(_ pattern: String) throws {
    selectAll()
    for ch in pattern {
        switch ch {
        case "\\": pressKey(kBackslashKeyCode)
        case "d": pressKey(kDKeyCode)
        case "{": pressKey(kLeftBracketKeyCode, flags: .maskShift)
        case "}": pressKey(kRightBracketKeyCode, flags: .maskShift)
        case "2": pressKey(kTwoKeyCode)
        case "x": pressKey(kXKeyCode)
        case "*": pressKey(kEightKeyCode, flags: .maskShift)
        case "[": pressKey(kLeftBracketKeyCode)
        case "a": pressKey(kAKeyCode)
        case "-": pressKey(kMinusKeyCode)
        case "+": pressKey(kEqualKeyCode, flags: .maskShift)
        default:
            throw DriverError.failure("no keycode mapping for '\(ch)' in the typing scenario")
        }
    }
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
var observations: [String] = []
var skipped: [String] = []

func writeTrace() {
    guard let output = diagnosticOutput else { return }
    let trace: [String: Any] = ["platform": "macos", "actions": actions, "assertions": assertions, "observations": observations, "skipped": skipped]
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
    // Hard precondition for every later keystroke: this scenario's value is
    // the real keyboard path, so the run fails honestly when the key window
    // is held elsewhere instead of silently skipping it.
    try waitFrontmost(application, pid: pid)
    assertions.append("application holds the key window for the real keyboard path")
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
    // The editor must be laid out wide enough to paint. A zero-width
    // document view paints nothing while its AX tree stays correct — the
    // blank-editor regression shipped green because only AX values were
    // asserted; the frame is the pixel-level guard.
    let editorFrame: CGRect = try waitFor("laid-out sample editor frame") {
        guard let editor = findTextArea(window), let frame = frameOf(editor), frame.width > 200 else { return nil }
        return frame
    }
    assertions.append("sample editor laid out \(Int(editorFrame.width))pt wide, not a zero-width document view")

    // -- Initial state: sample loaded, default pattern, nothing inspected --
    observations.append("initial keyboard focus: \(describeFocused(application))")
    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-before.json"))
    try captureWindow(pid, to: output, name: "screen-before.png")
    actions.append("snapshot:initial state")

    // -- Match rows expose the inspection contract to assistive technology --
    var table: AXUIElement = try waitFor("match table") { findMatchTable(window) }
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
    let selectedRows = attribute(table, kAXSelectedRowsAttribute) as? [AXUIElement] ?? []
    guard selectedRows.count == 1, sameAXElement(selectedRows[0], rows[1]) else {
        throw DriverError.failure("selected row is not carried on the table: \(selectedRows.count) rows")
    }
    assertions.append("activating a match row selects the same span in the sample editor")
    assertions.append("the inspected row carries the table selection (AXSelectedRows)")
    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-during.json"))
    try captureWindow(pid, to: output, name: "screen-during.png")
    actions.append("snapshot:row inspection")

    // -- ⌘G / ⌘⇧G via the Match menu: keyboard reachability without a pointer --
    try activateMenuItem(application, "Inspect Next Match") { (try? selectedEditorText(window)) == "09" }
    actions.append("menu:Inspect Next Match")
    assertions.append("Match menu next/previous walks matches with the same meaning")
    try activateMenuItem(application, "Inspect Previous Match") { (try? selectedEditorText(window)) == "2026" }
    try activateMenuItem(application, "Inspect Previous Match") { (try? selectedEditorText(window)) == "12345" }
    actions.append("menu:Inspect Previous Match ×2")

    // -- Arrow keys on the focused list: the key window is this app by the
    //    asserted precondition, so the keyboard walk runs unconditionally --
    try selectTableRow(table, rows[0], "match row 1")
    try focus(table, "match table")
    pressArrowKey(125)  // down
    _ = try waitFor("editor selection '2026' after Down") { (try? selectedEditorText(window)) == "2026" ? true : nil }
    pressArrowKey(125)
    _ = try waitFor("editor selection '09' after Down") { (try? selectedEditorText(window)) == "09" ? true : nil }
    pressArrowKey(126)  // up
    _ = try waitFor("editor selection '2026' after Up") { (try? selectedEditorText(window)) == "2026" ? true : nil }
    actions.append("keys:Down Down Up on focused match list")
    assertions.append("arrow keys move the inspection along the match list")

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
    try confirmPattern(patternField, "x*", "pattern field")
    actions.append("value+confirm:pattern=x*")
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
    try confirmPattern(patternField, "[", "pattern field (invalid)")
    actions.append("value+confirm:pattern=[")
    _ = try waitFor("invalid-pattern error state") { () -> Bool? in
        guard let count = findByIdentifier(window, "MatchCount").flatMap({ stringAttribute($0, kAXValueAttribute) }) else { return nil }
        return (count == "—" && tableRows(table).isEmpty) ? true : nil
    }
    assertions.append("invalid pattern reports the error, not a valid zero-match result")

    try confirmPattern(patternField, "\\d+", "pattern field (restored)")
    actions.append("value+confirm:pattern=\\d+")

    // -- Full keyboard path with real CGEvent keys only: Tab to the field →
    //    type → submit → Tab to the list → walk it → ⌘R → invalid-pattern
    //    recovery. This is the exact sequence a keyboard-only user performs;
    //    AX value writes and AXConfirm above are the assistive counterpart. --
    // Restore the canonical sample first (the earlier fixtures changed it;
    // a sample edit auto-runs), so the keyboard path starts from the
    // documented default state: default sample + \d+ → 5 matches.
    guard let keyboardEditor = findTextArea(window) else { throw DriverError.failure("sample editor not found") }
    try setSelectedText(keyboardEditor, "Order 12345 shipped on 2026-09-28 to zip 10115.", "sample editor (keyboard fixture)")
    actions.append("value:sample=default fixture")
    try waitForMatchCount(window, "5 matches", "the restored default sample and pattern")

    // An active IME consumes synthetic unicode-string key events before they
    // reach the app, so the typing assertions run on a plain ASCII layout —
    // the same public input-source API a user's layout switch uses. The
    // original source is restored when the scenario exits, success or not.
    let originalInputSource = currentInputSource()
    let typingLayout = asciiKeyboardLayout()
    var inputSourceSwitched = false
    defer {
        if inputSourceSwitched, let originalInputSource {
            _ = switchInputSource(originalInputSource)
        }
    }
    if let typingLayout, switchInputSource(typingLayout) {
        inputSourceSwitched = true
        actions.append("input:switch to ASCII layout for real typing")
        Thread.sleep(forTimeInterval: 0.3)
    } else {
        observations.append("no ASCII-capable keyboard layout available; the active input method may swallow typed keys")
    }

    // Walk keyboard focus to the pattern field with real Tab presses. An AX
    // focus write on the toolbar field reports focused but does not start
    // the field editor — real Tab navigation does, which is also the path a
    // keyboard-only user takes.
    var toField: [String] = []
    for _ in 0..<6 {
        pressKey(kTabKeyCode)
        toField.append(describeFocused(application))
        if let element = focusedUIElement(application), sameAXElement(element, patternField) { break }
    }
    actions.append("keys:Tab walk to pattern field → \(toField.joined(separator: " → "))")
    guard let focused = focusedUIElement(application), sameAXElement(focused, patternField) else {
        throw DriverError.failure("Tab walk never reached the pattern field: \(toField)")
    }

    // Typing alone must not run the engine: submission is the field action
    // (Return) or ⌘R, so the count holds while the draft accumulates. The
    // draft assertion below also proves real keystrokes reach the field.
    try typePattern("\\d{2}")
    actions.append("keys:⌘A + type \\d{2} via keycodes (no submit)")
    do {
        _ = try waitFor("pattern field to carry the typed draft", timeout: 8) { () -> Bool? in
            stringAttribute(patternField, kAXValueAttribute) == "\\d{2}" ? true : nil
        }
    } catch {
        throw DriverError.failure("typed draft never reached the pattern field (value '\(stringAttribute(patternField, kAXValueAttribute))', focus \(describeFocused(application)))")
    }
    try assertStable("match count while typing without submitting", horizon: 0.8) {
        matchCount(window) == "5 matches"
    }
    assertions.append("real typing lands in the pattern field and does not run the engine until submitted")

    pressKey(kReturnKeyCode)
    actions.append("keys:Return submits the pattern")
    try waitForMatchCount(window, "8 matches", "Return with \\d{2}")
    do {
        _ = try waitFor("the first \\d{2} row", timeout: 15) { () -> [AXUIElement]? in
            guard let live = findMatchTable(window) else { return nil }
            let found = tableRows(live)
            guard let first = found.first, rowName(first).contains("'12'") else { return nil }
            return found
        }
    } catch {
        let live = findMatchTable(window)
        let labels = live.map { tableRows($0).map { rowName($0) } } ?? []
        throw DriverError.failure("after Return with \\d{2}: MatchCount '\(matchCount(window) ?? "?")', captured-table rows \(tableRows(table).map { rowName($0) }), live-table rows \(labels)")
    }
    (table, observations) = reacquireTable(table, window, observations: observations)
    assertions.append("Return submits the pattern and the result list updates (5 → 8 matches)")

    // Walk focus with real Tab presses from the pattern field to the match
    // list; every step is recorded, landing on the list is asserted.
    let tableElements = walk(table)
    let listWalk = try tabWalk(application, targets: tableElements, "the match list")
    actions.append("keys:Tab walk field → list → \(listWalk.joined(separator: " → "))")
    assertions.append("Tab walks keyboard focus from the pattern field to the match list")
    try focus(table, "match table (after Tab walk)") // normalize to the table itself for the arrow walk

    // Arrow keys on the keyboard-reached list: the walked row is selected,
    // and the editor inspects the same span at every step.
    pressKey(kDownArrowKeyCode)
    _ = try waitFor("editor selection '12' after keyboard Down") { (try? selectedEditorText(window)) == "12" ? true : nil }
    pressKey(kDownArrowKeyCode)
    _ = try waitFor("editor selection '34' after keyboard Down") { (try? selectedEditorText(window)) == "34" ? true : nil }
    pressKey(kUpArrowKeyCode)
    _ = try waitFor("editor selection '12' after keyboard Up") { (try? selectedEditorText(window)) == "12" ? true : nil }
    let walkedSelection = attribute(table, kAXSelectedRowsAttribute) as? [AXUIElement] ?? []
    guard walkedSelection.count == 1, rowName(walkedSelection[0]).contains("Match 1 of 8") else {
        throw DriverError.failure("the arrow-key walk did not leave row 1 selected")
    }
    actions.append("keys:Down Down Up on the Tab-focused match list")
    assertions.append("arrow keys on the keyboard-reached list select the walked row and inspect it in the editor")

    // Walk back to the field with real Tabs; ⌘R then runs the typed pattern
    // without ever pressing Return.
    _ = try tabWalk(application, targets: [patternField], "the pattern field (⌘R path)")
    try typePattern("x*")
    actions.append("keys:⌘A + type x* via keycodes (no submit)")
    _ = try waitFor("pattern field to carry the typed draft x*") { () -> Bool? in
        stringAttribute(patternField, kAXValueAttribute) == "x*" ? true : nil
    }
    try assertStable("match count while typing x* without submitting", horizon: 0.8) {
        matchCount(window) == "8 matches"
    }
    pressKey(kRKeyCode, flags: .maskCommand)
    actions.append("keys:⌘R")
    _ = try waitFor("zero-width rows after ⌘R") { () -> Bool? in
        guard let live = findMatchTable(window), let first = tableRows(live).first else { return nil }
        return rowName(first).contains("zero-width") ? true : nil
    }
    (table, observations) = reacquireTable(table, window, observations: observations)
    assertions.append("⌘R runs the typed pattern without leaving the field")

    // Invalid pattern typed for real: an inline error state, not a
    // zero-match result, with the draft preserved for editing.
    try typePattern("[a-")
    actions.append("keys:⌘A + type [a- via keycodes")
    _ = try waitFor("pattern field to carry the typed draft [a-") { () -> Bool? in
        stringAttribute(patternField, kAXValueAttribute) == "[a-" ? true : nil
    }
    pressKey(kReturnKeyCode)
    actions.append("keys:Return submits the invalid draft")
    _ = try waitFor("invalid-pattern error state") { () -> Bool? in
        guard matchCount(window) == "—" else { return nil }
        let rows = findMatchTable(window).map { tableRows($0) } ?? []
        return rows.isEmpty && contains(window, fragment: "Fix the pattern to match") ? true : nil
    }
    guard contains(window, fragment: "missing closing square bracket in pattern") else {
        throw DriverError.failure("engine error message is not presented inline")
    }
    guard stringAttribute(patternField, kAXValueAttribute) == "[a-" else {
        throw DriverError.failure("invalid draft was not preserved in the pattern field")
    }
    observations.append("error state keeps the result list empty and the count as '—'; the previous explanation panel content remains until the pattern is fixed")
    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-error.json"))
    try captureWindow(pid, to: output, name: "screen-error.png")
    actions.append("snapshot:error state")
    assertions.append("typed invalid pattern ([a-) shows the engine error inline, keeps the count as '—', empties the list and preserves the draft")

    // Recovery over the same path: fixing the pattern restores the results.
    try focus(patternField, "pattern field (recovery)")
    try typePattern("\\d+")
    actions.append("keys:⌘A + type \\d+")
    pressKey(kReturnKeyCode)
    actions.append("keys:Return submits the fixed pattern")
    try waitForMatchCount(window, "5 matches", "recovery")
    _ = try waitFor("restored result rows") { () -> Bool? in
        guard let live = findMatchTable(window) else { return nil }
        let found = tableRows(live)
        guard found.count == 5 else { return nil }
        return rowName(found[1]).contains("'2026'") ? true : nil
    }
    (table, observations) = reacquireTable(table, window, observations: observations)
    assertions.append("fixing the pattern restores the result list over the same keyboard path")

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
    try captureWindow(pid, to: output, name: "screen-final.png")
    actions.append("snapshot:final state")
    let trace: [String: Any] = ["platform": "macos", "actions": actions, "assertions": assertions, "observations": observations, "skipped": skipped]
    try writeJSON(trace, to: output.appendingPathComponent("interaction-trace.json"))
    guard let running = NSRunningApplication(processIdentifier: pid), running.terminate() else { throw DriverError.failure("native application rejected termination") }
} catch {
    if let application = diagnosticApplication, let output = diagnosticOutput {
        try? writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-failure.json"))
        let trace: [String: Any] = ["platform": "macos", "actions": actions, "assertions": assertions, "observations": observations, "skipped": skipped, "failure": "\(error)"]
        try? writeJSON(trace, to: output.appendingPathComponent("interaction-trace.json"))
    }
    FileHandle.standardError.write(Data("RegexMate macOS acceptance failed: \(error)\n".utf8))
    exit(1)
}
