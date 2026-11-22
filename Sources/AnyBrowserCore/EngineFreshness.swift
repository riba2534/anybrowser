import Foundation

/// How many major versions the bundled engine is behind Chrome stable for Mac, from Google's
/// VersionHistory API, as `scripts/check-updates.sh` reads it. The lookup goes straight to Google,
/// never through a Profile's proxy, and its answer is kept for a day; a failed lookup tells
/// nothing and is tried again an hour later at the earliest.
@MainActor
public final class EngineFreshness: ObservableObject {
    public nonisolated static let stableVersions = URL(string: "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions")!

    /// The major version of the newest Chrome stable for Mac, when a lookup found it.
    @Published public private(set) var stableMajor: Int?
    public var cacheLifetime: TimeInterval = 24 * 60 * 60
    public var retryDelay: TimeInterval = 60 * 60
    private let configuration: URLSessionConfiguration
    private var answeredAt: Date?
    private var failedAt: Date?
    private var lookup: Task<Int?, Never>?
    /// How many requests went out, for tests.
    private(set) var requests = 0

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    /// How far `engine` is behind stable; nil until a lookup succeeded.
    public func majorsBehind(engine: Int = BundledVersions.engineMajor) -> Int? {
        stableMajor.map { max(0, $0 - engine) }
    }

    /// Looks the stable version up, unless an answer younger than `cacheLifetime` or a failure
    /// younger than `retryDelay` is known, or a lookup is already running.
    public func refresh(now: Date = Date()) async {
        if let answeredAt, now.timeIntervalSince(answeredAt) < cacheLifetime { return }
        if let failedAt, now.timeIntervalSince(failedAt) < retryDelay { return }
        if let lookup {
            _ = await lookup.value
            return
        }
        requests += 1
        let task = Task { [configuration] in await Self.fetchStableMajor(configuration: configuration) }
        lookup = task
        let major = await task.value
        lookup = nil
        if let major {
            stableMajor = major
            answeredAt = now
            failedAt = nil
        } else {
            failedAt = now
        }
    }

    nonisolated static func fetchStableMajor(configuration: URLSessionConfiguration) async -> Int? {
        var request = URLRequest(url: stableVersions, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // Straight to Google: the system proxy settings apply, a Profile's proxy does not.
        let session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return stableMajor(in: data)
    }

    /// The highest major version among the response's `versions[].version`.
    nonisolated static func stableMajor(in data: Data) -> Int? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = body["versions"] as? [[String: Any]] else { return nil }
        return versions.compactMap { ($0["version"] as? String)?.split(separator: ".").first.flatMap { Int($0) } }.max()
    }
}
