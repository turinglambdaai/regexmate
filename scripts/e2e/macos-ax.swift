import AppKit
import ApplicationServices
import Foundation

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
func enabled(_ element: AXUIElement) -> Bool { attribute(element, kAXEnabledAttribute) as? Bool ?? false }
func contains(_ root: AXUIElement, fragment: String) -> Bool {
    walk(root).contains { element in
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .contains { stringAttribute(element, $0).contains(fragment) }
    }
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
    guard AXUIElementPerformAction(refresh, kAXPressAction as CFString) == .success else { throw DriverError.failure("AXPress failed for Run regex") }
    _ = try waitFor("match count from embedded backend") { contains(window, fragment: "5 matches") ? true : nil }
    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility.json"))
    try writeJSON(["platform": "macos", "actions": ["press:Run regex"], "assertions": ["packaged SwiftUI window activated", "Run regex exposed through Accessibility", "request crossed RVT1 into the embedded backend", "native UI reports 5 matches"]], to: output.appendingPathComponent("interaction-trace.json"))
    guard let running = NSRunningApplication(processIdentifier: pid), running.terminate() else { throw DriverError.failure("native application rejected termination") }
} catch {
    if let application = diagnosticApplication, let output = diagnosticOutput { try? writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-failure.json")) }
    FileHandle.standardError.write(Data("RegexMate macOS acceptance failed: \(error)\n".utf8))
    exit(1)
}
