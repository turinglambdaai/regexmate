// Generated from the default Rivet scaffold backend.
// raco rivet build replaces this file from the application's actual schema.
import Foundation
import RivetRuntime

public enum RivetGeneratedError: Error {
    case typeMismatch(String)
}

public enum RivetGeneratedConfig {
    public static let moduleName = "backend"
    public static let entryName = "start"
}

public struct RivetAPI: Sendable {
    public let client: RivetClient

    public init(client: RivetClient) {
        self.client = client
    }

    public func greet(name: String) async throws -> String {
        let value = try await client.call("greet", arguments: [.string(name)])
        guard case .string(let result) = value else {
            throw RivetGeneratedError.typeMismatch("String")
        }
        return result
    }

    public func increment(value: Int64) async throws -> Int64 {
        let result = try await client.call("increment", arguments: [.int64(value)])
        guard case .int64(let next) = result else {
            throw RivetGeneratedError.typeMismatch("Int64")
        }
        return next
    }
}
