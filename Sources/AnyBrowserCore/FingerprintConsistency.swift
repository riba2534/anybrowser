import Foundation

public struct ConsistencyIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

extension BrowserProfile {
    /// Combinations a website could notice: versions ahead of the engine, platform and version
    /// mismatches, or a time zone and language that disagree with the proxy's exit.
    public func consistencyIssues(engineVersion: String?, exit: ProxyExit?) -> [ConsistencyIssue] {
        []
    }
}
