import SwiftUI
import AppKit
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 360)
                .task { model.start() }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting embedded Racket CS…"
    @Published var ready = false
    @Published var busy = false

    @Published var pattern = "\\d+"
    @Published var sample = "Order 12345 shipped on 2026-09-28 to zip 10115."
    @Published var matches = "(no matches)"
    @Published var explanation = ""
    @Published var lint = "(no findings)"
    @Published var diagram: NSImage?

    private var backend: EmbeddedRacketBackend?

    func start() {
        guard backend == nil else { return }

        do {
            let config = try Self.runtimeConfiguration()
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend] in
                do {
                    try backend.start()
                    let api = RivetAPI(client: backend.client)
                    _ = try await api.status(pattern: "\\d+")
                    await MainActor.run {
                        self.ready = true
                        self.status = "Embedded Racket CS is ready"
                    }
                } catch {
                    await MainActor.run {
                        self.ready = false
                        self.status = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    func refresh() {
        guard let backend, ready, !busy else { return }
        busy = true

        let pattern = pattern
        let sample = sample

        Task {
            do {
                let api = RivetAPI(client: backend.client)
                let rows = try await api.matchRows(pattern: pattern, text: sample)
                let explanation = try await api.explainText(pattern: pattern)
                let lint = try await api.lintRows(pattern: pattern)
                let png = try await api.diagramPng(pattern: pattern)

                var table = "(no matches)"
                if !rows.isEmpty {
                    var lines: [String] = []
                    for (index, row) in rows.enumerated() where row.count >= 4 {
                        lines.append("\(index + 1). \(row[0])  [\(row[1])-\(row[2])]  \(row[3]) group(s)")
                    }
                    table = lines.joined(separator: "\n")
                }

                var lintText = "(no findings)"
                if !lint.isEmpty {
                    var lines: [String] = []
                    for row in lint where row.count >= 4 {
                        lines.append("[\(row[0])] \(row[1]) @\(row[2]): \(row[3])")
                    }
                    lintText = lines.joined(separator: "\n")
                }

                var image: NSImage?
                if !png.isEmpty {
                    image = NSImage(data: png)
                }

                matches = table
                self.explanation = explanation
                self.lint = lintText
                self.diagram = image
                self.status = "Found \(rows.count) match(es)"
                self.busy = false
            } catch {
                status = "Error: \(error)"
                busy = false
            }
        }
    }

    private static func runtimeConfiguration() throws -> EmbeddedRacketConfiguration {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        // Packaged apps keep Racket data in Contents/Resources. `raco rivet
        // dev` runs the staged executable directly, where runtime/res live next
        // to the executable. Pick the first complete layout so both paths use
        // exactly the same host binary.
        let roots = [
            Bundle.main.resourceURL,
            executable.deletingLastPathComponent()
        ].compactMap { $0 }

        for root in roots {
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let core = root.appendingPathComponent("res/core.zo")
            let required = [
                runtime.appendingPathComponent("petite.boot"),
                runtime.appendingPathComponent("scheme.boot"),
                runtime.appendingPathComponent("racket.boot"),
                core
            ]
            if required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return EmbeddedRacketConfiguration(
                    executable: executable,
                    petiteBoot: required[0],
                    schemeBoot: required[1],
                    racketBoot: required[2],
                    core: core,
                    moduleName: RivetGeneratedConfig.moduleName,
                    entryName: RivetGeneratedConfig.entryName
                )
            }
        }

        throw HostError.missingRuntimeLayout(
            roots.map(\.path).joined(separator: ", ")
        )
    }
}

enum HostError: Error, CustomStringConvertible {
    case missingRuntimeLayout(String)

    var description: String {
        switch self {
        case .missingRuntimeLayout(let roots):
            return "missing Rivet runtime/res layout under: \(roots)"
        }
    }
}
