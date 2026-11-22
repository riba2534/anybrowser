@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// Shared by the automation API and anybrowserctl suites: a backend whose Profiles and proxies live
// in a real store while its browsers are pretend, and a client that controls every byte it sends.

let automationTestToken = String(repeating: "5a", count: 32)

/// Runs `body` with an API server for `backend` on a free port.
@MainActor
func serveAutomation(_ backend: AutomationBackend, _ body: (Int) async throws -> Void) async throws {
    let server = AutomationServer(port: 0, token: automationTestToken, backend: backend)
    let port = try await server.start()
    do {
        try await body(port)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func automationHeaders(_ port: Int) -> [String] {
    ["Host: 127.0.0.1:\(port)", "Authorization: Bearer \(automationTestToken)"]
}

/// One request with the token unless `headers` replaces them; `body` gets its Content-Length.
func automationRequest(_ port: Int, _ method: String, _ path: String, headers: [String]? = nil,
                       body: String = "") async -> RawClient.Reply {
    var head = "\(method) \(path) HTTP/1.1\r\n" + (headers ?? automationHeaders(port)).map { $0 + "\r\n" }.joined()
    if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
    return await automationSend(port, [Data((head + "\r\n" + body).utf8)])
}

/// `body` encoded as JSON.
func automationRequest(_ port: Int, _ method: String, _ path: String, json body: Any) async -> RawClient.Reply {
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return await automationRequest(port, method, path, body: String(decoding: data, as: UTF8.self))
}

func automationSend(_ port: Int, _ chunks: [Data]) async -> RawClient.Reply {
    await onThread { RawClient.exchange(port: port, chunks: chunks) }
}

/// An automation backend for the HTTP layer: Profiles, the recycle bin and the proxy library are
/// a real store in a scratch directory; launches only change `states` and record what was asked.
@MainActor
final class FakeBackend: AutomationBackend {
    let directory: URL
    let store: ProfileStore
    let proxyLibrary: ProxyLibrary
    var profiles: [BrowserProfile] { store.profiles }

    var states: [UUID: BrowserRunState] = [:]
    var busy: Set<UUID> = []
    /// A batch action is in progress, which blocks removals as the coordinator's does.
    var batchRunning = false
    var startError: Error?
    var stopError: Error?
    var startWarnings: [String] = []
    var startedFresh = true
    var endpointAvailable = true
    /// DevTools endpoints of running Profiles, such as a `FakeDevTools`; others get a made-up one.
    var endpoints: [UUID: URL] = [:]
    /// What a refresh finds on the system, when it differs from `states`.
    var refreshedStates: [UUID: BrowserRunState] = [:]
    var pendingRestarts: Set<UUID> = []
    var logs: [UUID: String] = [:]
    var exits: [UUID: ProxyExit] = [:]
    /// Exits by proxy address for new Profiles; a missing one is a failed lookup.
    var lookups: [String: ProxyExit] = [:]
    /// Exits by library URL for proxy checks; a missing one fails.
    var proxyChecks: [String: ProxyExit] = [:]
    var arrangeError: Error?
    /// What `remove` reports about a directory it could not delete.
    var removeProblem: String?
    /// Runs inside every start, before the browser counts as running.
    var duringStart: (UUID) async -> Void = { _ in }
    /// Runs inside every exit lookup for a new Profile, before it answers.
    var duringLookup: (String) async -> Void = { _ in }

    private(set) var started: [UUID] = []
    private(set) var restarted: [UUID] = []
    private(set) var overrides: [LaunchOverrides] = []
    private(set) var stopped: [UUID] = []
    private(set) var forced: [Bool] = []
    private(set) var removed: [(id: UUID, browserData: Bool)] = []
    private(set) var lookedUp: [String] = []
    private(set) var checked: [UUID] = []
    private(set) var arranged: [(ids: [UUID], columns: Int?)] = []

    /// With `directory`, the store already there, such as one a test made read-only.
    init(directory: URL? = nil) throws {
        self.directory = try directory ?? scratchDirectory("automation-backend")
        store = try ProfileStore(directory: self.directory)
        proxyLibrary = ProxyLibrary(store: store)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func add(_ name: String, port: Int, group: String = "", _ change: (inout BrowserProfile) -> Void = { _ in }) throws -> BrowserProfile {
        var profile = BrowserProfile(name: name, port: port, fingerprint: FingerprintSettings(seed: port), group: group)
        change(&profile)
        try store.save(profile)
        return try #require(store.profiles.first { $0.id == profile.id })
    }

    func state(for id: UUID) -> BrowserRunState { states[id] ?? .stopped }

    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    func hasPendingRestart(_ id: UUID) -> Bool { pendingRestarts.contains(id) }

    func devToolsEndpoint(for id: UUID) async -> URL? {
        guard endpointAvailable, case let .running(_, port, true) = state(for: id) else { return nil }
        return endpoints[id] ?? URL(string: "ws://127.0.0.1:\(port)/devtools/browser/\(id.uuidString.lowercased())")
    }

    func refresh(_ id: UUID) async {
        if let state = refreshedStates[id] { states[id] = state }
    }

    func start(_ id: UUID, overrides: LaunchOverrides, fingerprintChange: FingerprintChangeHandling) async throws -> LaunchOutcome {
        started.append(id)
        return try await launch(id, overrides)
    }

    func restart(_ id: UUID, overrides: LaunchOverrides, fingerprintChange: FingerprintChangeHandling) async throws -> LaunchOutcome {
        restarted.append(id)
        return try await launch(id, overrides)
    }

    private func launch(_ id: UUID, _ overrides: LaunchOverrides) async throws -> LaunchOutcome {
        self.overrides.append(overrides)
        if let startError { throw startError }
        await duringStart(id)
        let port = store.profiles.first { $0.id == id }?.port ?? 0
        states[id] = .running(pid: 42, port: port, debugReady: true)
        return LaunchOutcome(startedFresh: startedFresh, warnings: startWarnings)
    }

    func stop(_ id: UUID, force: Bool) async throws {
        stopped.append(id)
        forced.append(force)
        if let stopError { throw stopError }
        states[id] = .stopped
    }

    func launchLog(for id: UUID) -> String? { logs[id] }

    func lastExit(for id: UUID) -> (exit: ProxyExit, checkedAt: Date)? { exits[id].map { ($0, Date()) } }

    func removalBlocker(_ id: UUID) -> String? {
        ProfileLibrary.removalBlocker(state: state(for: id), busy: isBusy(id), batchRunning: batchRunning)
    }

    func trash(_ id: UUID) throws {
        if let blocker = removalBlocker(id) { throw ProfileError.invalid(blocker) }
        try store.trash(id)
    }

    func restore(_ id: UUID) throws {
        try store.restore(id)
    }

    func remove(_ id: UUID, deletingBrowserData: Bool, recordRemoved: () -> Void) async throws -> String? {
        if let blocker = removalBlocker(id) { throw ProfileError.invalid(blocker) }
        try store.remove(id)
        removed.append((id, deletingBrowserData))
        recordRemoved()
        return removeProblem
    }

    func lookUpExit(through proxy: String) async -> ProxyExit? {
        lookedUp.append(proxy)
        await duringLookup(proxy)
        return lookups[proxy]
    }

    func checkProxy(_ entry: ProxyEntry) async throws -> ProxyExit {
        checked.append(entry.id)
        guard let exit = proxyChecks[entry.url] else { throw ProfileError.invalid("无法查询出口 IP：代理拒绝了连接。") }
        return exit
    }

    func arrangeWindows(_ ids: [UUID], columns: Int?) async throws -> [WindowArrangement.Outcome] {
        arranged.append((ids, columns))
        if let arrangeError { throw arrangeError }
        return ids.enumerated().map { index, id in
            if case .running = state(for: id) {
                return WindowArrangement.Outcome(id: id, frame: .init(left: index * 100, top: 25, width: 100, height: 200))
            }
            return WindowArrangement.Outcome(id: id, frame: nil, failure: "浏览器没有运行，或调试端口尚未就绪。")
        }
    }
}

/// A blocking HTTP client over BSD sockets, so tests control every byte of the request.
enum RawClient {
    struct Reply {
        var status = 0
        var headers: [String: String] = [:]
        var body = Data()

        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
        var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }
        var errorMessage: String? { (json?["error"] as? [String: Any])?["message"] as? String }
    }

    static func exchange(port: Int, chunks: [Data]) -> Reply {
        let fd = Sockets.connect(to: port, timeout: 30)
        guard fd >= 0 else { return Reply() }
        defer { close(fd) }
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { usleep(100_000) }
            Sockets.write(fd, chunk)
        }
        let received = Sockets.readAll(fd)
        guard let split = received.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: received[..<split.lowerBound], encoding: .utf8) else { return Reply() }
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ")
        var reply = Reply(status: status.count > 1 ? Int(status[1]) ?? 0 : 0, body: received[split.upperBound...])
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            reply.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return reply
    }

    static func connects(to host: String, port: Int) async -> Bool {
        await onThread {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return false }
            defer { freeaddrinfo(result) }
            let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
        }
    }

    /// IPv4 addresses of this Mac other than loopback; the API must not answer on any of them.
    /// Point-to-point tunnels are left out because VPN and proxy apps accept any connection there.
    static func externalIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        var cursor = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("127.") { addresses.append(text) }
        }
        return addresses
    }
}
