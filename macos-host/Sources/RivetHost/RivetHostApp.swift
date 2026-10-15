import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup("RegexMate") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
                .task { model.start() }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1160, height: 690)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check for Updates…") {
                    model.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }
}

// One match: the matched text plus its [start, end) span and group count.
struct MatchSpan: Equatable {
    let text: String
    let start: Int
    let end: Int
    let groups: Int
}

// One lint row: severity, rule id, pattern position, human message.
struct LintFinding: Equatable, Identifiable {
    let severity: String
    let rule: String
    let position: Int
    let message: String
    var id: String { "\(rule)-\(position)-\(message)" }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    @Published var phase = Phase.starting
    @Published var busy = false

    @Published var pattern = "\\d+"
    @Published var sample = "Order 12345 shipped on 2026-09-28 to zip 10115."
    @Published var matches: [MatchSpan] = []
    @Published var explanation = ""
    @Published var findings: [LintFinding] = []
    @Published var diagram: NSImage?
    @Published var patternError: String?

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private var backend: EmbeddedRacketBackend?
    // Discards results of superseded refreshes (live typing enqueues many).
    private var generation = 0
    private var debounce: Task<Void, Never>?

    func start() {
        guard backend == nil else { return }

        do {
            // Rivet's canonical factory picks the packaged (or dev-staged)
            // runtime layout and pins the working directory so the CS
            // runtime resolves its staged foreign libraries (libpng et al).
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend, weak self] in
                do {
                    try backend.start()
                    let api = RivetAPI(client: backend.client)
                    _ = try await api.status(pattern: "\\d+")
                    await MainActor.run {
                        self?.phase = .ready
                        self?.refreshNow()
                    }
                } catch {
                    await MainActor.run {
                        self?.phase = .failed("\(error)")
                    }
                }
            }
        } catch {
            phase = .failed("\(error)")
        }
    }

    // Live refresh: re-run after 300 ms of typing silence (matches the
    // Windows host's debounce).
    func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    // Read-only check against the same Ed25519-signed manifest the CLI
    // self-update uses. Applying stays the CLI's job — the GUI never
    // mutates its own bundle; the dialog points at Releases instead.
    func checkForUpdates() {
        guard let backend, isReady else { return }
        Task { [weak self] in
            guard let self else { return }
            let api = RivetAPI(client: backend.client)
            do {
                let report = try await api.update_check()
                await MainActor.run { self.presentUpdateReport(report) }
            } catch {
                await MainActor.run {
                    self.updateAlert(title: "Check failed",
                                     message: "\(error)")
                }
            }
        }
    }

    @MainActor
    private func presentUpdateReport(_ report: [String]) {
        switch report.first {
        case "up-to-date":
            updateAlert(title: "You're up to date",
                        message: "RegexMate \(RivetGeneratedConfig.version) is the latest stable build.")
        case "available":
            let version = report.count > 1 ? report[1] : "(unknown)"
            let alert = NSAlert()
            alert.messageText = "RegexMate \(version) is available"
            alert.informativeText = "Download the latest installer, or run `regexmate update` for a portable install — then restart the app."
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "https://github.com/turinglambdaai/regexmate/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        case "offline":
            updateAlert(title: "Check failed",
                        message: report.count > 1 ? report[1] : "The update manifest could not be fetched.")
        default:
            updateAlert(title: "Check failed",
                        message: "Unexpected update-check report.")
        }
    }

    @MainActor
    private func updateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func refreshNow() {
        guard let backend, isReady else { return }
        generation += 1
        let gen = generation
        let pattern = pattern
        let sample = sample
        busy = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let api = RivetAPI(client: backend.client)
                let validity = try await api.status(pattern: pattern)
                guard gen == self.generation else { return }
                if validity != "ok" {
                    self.patternError = validity
                    self.matches = []
                    self.findings = []
                    self.diagram = nil
                    self.busy = false
                    return
                }
                self.patternError = nil

                async let rows = api.match_rows(pattern: pattern, text: sample)
                async let explanation = api.explain_text(pattern: pattern)
                async let lint = api.lint_rows(pattern: pattern)
                async let png = api.diagram_png(pattern: pattern)
                let (r, e, l, g) = try await (rows, explanation, lint, png)
                guard gen == self.generation else { return }

                self.matches = r.compactMap(Self.matchSpan(from:))
                self.explanation = e
                self.findings = l.compactMap(Self.finding(from:))
                self.diagram = g.isEmpty ? nil : NSImage(data: g)
                self.busy = false
            } catch {
                guard gen == self.generation else { return }
                self.phase = .failed("\(error)")
                self.busy = false
            }
        }
    }

    // Write the self-contained HTML evidence report (v0.3.0 CLI feature) and
    // reveal it in Finder.
    func exportReport() {
        guard let backend, isReady else { return }
        let pattern = pattern
        let sample = sample

        Task { [weak self] in
            do {
                let html = try await RivetAPI(client: backend.client)
                    .report_html(pattern: pattern, text: sample)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.html]
                panel.nameFieldStringValue = "regexmate-report.html"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try html.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self?.phase = .failed("\(error)")
            }
        }
    }

    private static func matchSpan(from row: [String]) -> MatchSpan? {
        guard row.count >= 4,
              let start = Int(row[1]),
              let end = Int(row[2]),
              let groups = Int(row[3]) else { return nil }
        return MatchSpan(text: row[0], start: start, end: end, groups: groups)
    }

    private static func finding(from row: [String]) -> LintFinding? {
        guard row.count >= 4, let position = Int(row[2]) else { return nil }
        return LintFinding(severity: row[0], rule: row[1], position: position, message: row[3])
    }
}
