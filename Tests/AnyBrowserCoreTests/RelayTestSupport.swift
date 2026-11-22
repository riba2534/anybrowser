@testable import AnyBrowserCore
import Darwin
import Foundation
import Network
import Security
import Testing

// Upstream proxies and origins for the relay suites. They use blocking sockets on their own threads,
// independent of the relay's Network.framework code, so a relay bug cannot hide behind a stub sharing it.

/// The AnyBrowserRelay executable, built next to the test bundle.
let relayHelperPath = builtProduct(RelayHelper.executableName)

/// Runs blocking work (sockets, child processes) on a thread of its own instead of the cooperative pool.
/// Blocked there, a few waits take every thread of a small machine (the hosted runner has three),
/// and the async work they wait for, such as a test server answering, can no longer run.
func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: body()) }
    }
}

enum Sockets {
    /// A TCP connection to 127.0.0.1:`port`, or -1.
    static func connect(to port: Int, timeout: TimeInterval = 10) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        configure(fd, timeout: timeout)
        var address = loopback(port)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        // A peer that went away must not raise SIGPIPE in the test process.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    static func loopback(_ port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    @discardableResult
    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }

    @discardableResult
    static func write(_ fd: Int32, _ text: String) -> Bool { write(fd, Data(text.utf8)) }

    /// Up to `count` bytes; empty at the end of the stream or on an error.
    static func read(_ fd: Int32, upTo count: Int = 65536) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(fd, &buffer, count)
        return received > 0 ? Data(buffer[0..<received]) : Data()
    }

    /// Exactly `count` bytes, or nil when the stream ends first.
    static func read(_ fd: Int32, exactly count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = read(fd, upTo: count - data.count)
            guard !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    /// Everything until the peer closes its side.
    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        while true {
            let chunk = read(fd)
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }

    /// A request or response head and the bytes that arrived after it.
    static func readHead(_ fd: Int32) -> (head: String, rest: Data)? {
        var data = Data()
        let end = Data("\r\n\r\n".utf8)
        while data.range(of: end) == nil {
            let chunk = read(fd, upTo: 4096)
            guard !chunk.isEmpty, data.count < 65536 else { return nil }
            data.append(chunk)
        }
        let range = data.range(of: end)!
        return (String(decoding: data[..<range.lowerBound], as: UTF8.self), Data(data[range.upperBound...]))
    }

    /// Copies both ways until both sides have ended, passing each end on as a half-close.
    static func splice(_ first: Int32, _ second: Int32) {
        let remaining = Counter(2)
        for (from, to) in [(first, second), (second, first)] {
            Thread.detachNewThread {
                while true {
                    let chunk = read(from)
                    if chunk.isEmpty || !write(to, chunk) { break }
                }
                shutdown(to, SHUT_WR)
                if remaining.decrement() == 0 {
                    close(first)
                    close(second)
                }
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int

        init(_ value: Int) { self.value = value }

        func decrement() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value -= 1
            return value
        }
    }
}

/// A listening socket on 127.0.0.1 that hands each connection to `handle` on a thread of its own.
/// Stopping only ends the listening; open connections end with their peers.
class SocketServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = Sockets.loopback(0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 64) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            throw VerificationFailure.message("The test server could not listen")
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Called on a new thread for every connection, which it closes.
    func handle(_ fd: Int32) {}

    func hangUp(_ fd: Int32) {
        close(fd)
    }

    func stop() {
        locked { stopped = true }
    }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func acceptLoop() {
        defer { close(listener) }
        while !locked({ stopped }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            Sockets.configure(fd, timeout: 30)
            Thread.detachNewThread { [self] in handle(fd) }
        }
    }
}

/// Answers every request with a small page naming the host and path, then closes.
final class OriginStub: SocketServer, @unchecked Sendable {
    private var heads: [String] = []

    var requests: [String] { locked { heads } }

    override func handle(_ fd: Int32) {
        guard let (head, _) = Sockets.readHead(fd) else { return hangUp(fd) }
        locked { heads.append(head) }
        let lines = head.components(separatedBy: "\r\n")
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let host = lines.first { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? ""
        let body = "<!doctype html><meta charset=utf-8><title>origin \(host)</title><p id=path>\(path)</p>"
        Sockets.write(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        shutdown(fd, SHUT_WR)
        _ = Sockets.readAll(fd)
        close(fd)
    }
}

/// Reads until the client half-closes, then answers `echo:` and everything it read, and closes.
/// It only answers when the end of the request reaches it, so it also checks half-closes.
final class EchoStub: SocketServer, @unchecked Sendable {
    override func handle(_ fd: Int32) {
        let received = Sockets.readAll(fd)
        Sockets.write(fd, Data("echo:".utf8) + received)
        close(fd)
    }
}

/// Accepts connections and never answers.
final class SilentStub: SocketServer, @unchecked Sendable {
    override func handle(_ fd: Int32) {
        _ = Sockets.readAll(fd)
        close(fd)
    }
}

/// An HTTP proxy that asks for Basic sign-in and forwards to the port `route` gives for a host,
/// both through CONNECT and for absolute-form requests.
final class UpstreamHTTPStub: SocketServer, @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        var authorization: String?
        var head: String
    }

    private let credentials: String?
    private let route: @Sendable (String) -> Int?
    private var log: [Request] = []

    init(credentials: String?, route: @escaping @Sendable (String) -> Int?) throws {
        self.credentials = credentials
        self.route = route
        try super.init()
    }

    var requests: [Request] { locked { log } }

    var signIn: String? { credentials.map { "Basic " + Data($0.utf8).base64EncodedString() } }

    override func handle(_ fd: Int32) {
        guard let (head, rest) = Sockets.readHead(fd) else { return hangUp(fd) }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ").map(String.init)
        // Other programs on this Mac probe local ports with plain requests; only proxy requests count.
        guard start.count == 3, start[0] == "CONNECT" || start[1].hasPrefix("http://") else { return hangUp(fd) }
        let authorization = lines.first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { $0.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) }
        locked { log.append(Request(method: start[0], target: start[1], authorization: authorization, head: head)) }
        guard signIn == nil || authorization == signIn else {
            Sockets.write(fd, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"stub\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return hangUp(fd)
        }
        let host: String
        var request: Data
        if start[0] == "CONNECT" {
            host = start[1]
            request = rest
        } else {
            let remainder = start[1].dropFirst("http://".count)
            let split = remainder.firstIndex(of: "/") ?? remainder.endIndex
            host = String(remainder[..<split])
            let kept = lines.dropFirst().filter { !$0.lowercased().hasPrefix("proxy-") }
            let path = remainder[split...].isEmpty ? "/" : String(remainder[split...])
            request = Data((["\(start[0]) \(path) \(start[2])"] + kept).joined(separator: "\r\n").utf8) + Data("\r\n\r\n".utf8) + rest
        }
        guard let port = route(host) else {
            Sockets.write(fd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return hangUp(fd)
        }
        let origin = Sockets.connect(to: port)
        guard origin >= 0 else { return hangUp(fd) }
        if start[0] == "CONNECT" { Sockets.write(fd, "HTTP/1.1 200 Connection established\r\n\r\n") }
        if !request.isEmpty { Sockets.write(origin, request) }
        Sockets.splice(fd, origin)
    }
}

/// A SOCKS5 proxy that requires `username` and `password` (RFC 1929) when given, and connects to the
/// port `route` gives for the requested host.
final class UpstreamSOCKSStub: SocketServer, @unchecked Sendable {
    struct Request: Sendable {
        var methods: [UInt8]
        var username: String?
        var password: String?
        var addressType: UInt8
        var host: String
        var port: Int
    }

    private let credentials: (username: String, password: String)?
    private let route: @Sendable (String) -> Int?
    private var log: [Request] = []

    init(username: String?, password: String?, route: @escaping @Sendable (String) -> Int?) throws {
        credentials = username.map { ($0, password ?? "") }
        self.route = route
        try super.init()
    }

    var requests: [Request] { locked { log } }

    override func handle(_ fd: Int32) {
        guard let greeting = Sockets.read(fd, exactly: 2), greeting[0] == 5,
              let methods = Sockets.read(fd, exactly: Int(greeting[1])) else { return hangUp(fd) }
        var request = Request(methods: Array(methods), addressType: 0, host: "", port: 0)
        if let credentials {
            guard methods.contains(2) else {
                Sockets.write(fd, Data([5, 0xff]))
                locked { log.append(request) }
                return hangUp(fd)
            }
            Sockets.write(fd, Data([5, 2]))
            guard let version = Sockets.read(fd, exactly: 2), version[0] == 1,
                  let username = Sockets.read(fd, exactly: Int(version[1])),
                  let length = Sockets.read(fd, exactly: 1),
                  let password = Sockets.read(fd, exactly: Int(length[0])) else { return hangUp(fd) }
            request.username = String(decoding: username, as: UTF8.self)
            request.password = String(decoding: password, as: UTF8.self)
            guard request.username == credentials.username, request.password == credentials.password else {
                Sockets.write(fd, Data([1, 1]))
                locked { log.append(request) }
                return hangUp(fd)
            }
            Sockets.write(fd, Data([1, 0]))
        } else {
            Sockets.write(fd, Data([5, 0]))
        }
        guard let head = Sockets.read(fd, exactly: 4), head[0] == 5, head[1] == 1 else { return hangUp(fd) }
        request.addressType = head[3]
        switch head[3] {
        case 1:
            guard let bytes = Sockets.read(fd, exactly: 4) else { return hangUp(fd) }
            request.host = bytes.map(String.init).joined(separator: ".")
        case 3:
            guard let length = Sockets.read(fd, exactly: 1), let name = Sockets.read(fd, exactly: Int(length[0])) else {
                return hangUp(fd)
            }
            request.host = String(decoding: name, as: UTF8.self)
        case 4:
            guard let bytes = Sockets.read(fd, exactly: 16) else { return hangUp(fd) }
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
            request.host = String(cString: text)
        default:
            return hangUp(fd)
        }
        guard let port = Sockets.read(fd, exactly: 2) else { return hangUp(fd) }
        request.port = Int(port[0]) << 8 | Int(port[1])
        locked { log.append(request) }
        guard let target = route(request.host) else {
            // Connection refused.
            Sockets.write(fd, Data([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]))
            return hangUp(fd)
        }
        let origin = Sockets.connect(to: target)
        guard origin >= 0 else { return hangUp(fd) }
        Sockets.write(fd, Data([5, 0, 0, 1, 127, 0, 0, 1, UInt8(target >> 8), UInt8(target & 0xff)]))
        Sockets.splice(fd, origin)
    }
}

/// A browser-side client speaking to the relay.
enum RelayClient {
    struct Reply: Sendable {
        var head: String
        var body: Data

        var status: Int { Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0 }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// Sends `request` as it is, half-closes, and reads the whole reply.
    static func exchange(_ port: Int, _ request: String) async -> Reply? {
        await onThread {
            let fd = Sockets.connect(to: port)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard Sockets.write(fd, request), let (head, rest) = Sockets.readHead(fd) else { return nil }
            return Reply(head: head, body: rest + Sockets.readAll(fd))
        }
    }

    /// Opens a CONNECT tunnel to `target`, sends `payload` through it, half-closes unless told not to,
    /// and reads to the end.
    static func tunnel(_ port: Int, to target: String, payload: Data, halfClose: Bool = true) async -> Reply? {
        await onThread {
            let fd = Sockets.connect(to: port)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard Sockets.write(fd, "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nUser-Agent: relay-test\r\n\r\n"),
                  let (head, rest) = Sockets.readHead(fd) else { return nil }
            guard head.hasPrefix("HTTP/1.1 200") else { return Reply(head: head, body: rest + Sockets.readAll(fd)) }
            guard Sockets.write(fd, payload) else { return nil }
            if halfClose { shutdown(fd, SHUT_WR) }
            return Reply(head: head, body: rest + Sockets.readAll(fd))
        }
    }
}

/// Terminates TLS on 127.0.0.1 and passes the plain bytes on to `port`, like an HTTPS proxy in front
/// of the HTTP stub. The certificate is self-signed for 127.0.0.1.
final class TLSFront: @unchecked Sendable {
    let port: Int
    let certificate: SecCertificate
    private let listener: NWListener

    private init(port: Int, certificate: SecCertificate, listener: NWListener) {
        self.port = port
        self.certificate = certificate
        self.listener = listener
    }

    @available(macOS 15, *)
    static func start(forwardingTo backend: Int) async throws -> TLSFront {
        let identity = try testIdentity()
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, try #require(sec_identity_create(identity)))
        let parameters = NWParameters(tls: options)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.tests.tls-front")
        listener.newConnectionHandler = { connection in
            let plain = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(backend))!, using: .tcp)
            connection.start(queue: queue)
            plain.start(queue: queue)
            relay(connection, plain)
            // When the backend is done, the front closes the TLS connection as a whole, as proxies do.
            relay(plain, connection, closing: true)
        }
        let port = try await listener.startAndWait(on: queue)
        return TLSFront(port: Int(port), certificate: try #require(certificate), listener: listener)
    }

    func stop() { listener.cancel() }

    private static func relay(_ from: NWConnection, _ to: NWConnection, closing: Bool = false) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty { to.send(content: data, completion: .idempotent) }
            if complete || error != nil {
                to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    if closing {
                        to.cancel()
                        from.cancel()
                    }
                })
                return
            }
            relay(from, to, closing: closing)
        }
    }

    @available(macOS 15, *)
    private static func testIdentity() throws -> SecIdentity {
        let data = try #require(Data(base64Encoded: pkcs12, options: .ignoreUnknownCharacters))
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "anybrowser", kSecImportToMemoryOnly as String: true] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw VerificationFailure.message("The test identity could not be imported (\(status))")
        }
        return identity as! SecIdentity
    }

    // openssl ecparam -name prime256v1 -genkey; a self-signed certificate for IP 127.0.0.1 valid until
    // 2126; PKCS#12 with 3DES and the passphrase "anybrowser".
    private static let pkcs12 = """
        MIIDggIBAzCCA0gGCSqGSIb3DQEHAaCCAzkEggM1MIIDMTCCAicGCSqGSIb3DQEHBqCCAhgwggIUAgEAMIICDQYJKoZIhvcNAQcB
        MBwGCiqGSIb3DQEMAQMwDgQISEE6y+LeH7cCAggAgIIB4ORL6blJciveSw+Wx0GOrc4gFJhr+lKSzolkBX4rfK257NHmYWyc08zu
        HNg8lK7AUy8UMf40QRO/JbPG6ZEXUoUcyDUy4LBge4FBfMfTvPiLqZp034CAsktJ4MNrSWs6lfwreEIg0cNNtP8DyqEX/dnFxkHT
        WmrRK1GymlfjMQpivMV+c6pyelfcwA7qJ6hZIxCH+RS1LVsbCULI0oUUnDpKjB/X3qZbb1WouPxfpTbH0X1YFT4ZljhWsm7LeBXe
        MEfLlV4+oujOfIfeok1BpNi4IgHVOSng4zN6zpAR8kRNT+Mbzx8aGMEDl0SFsrt18Q7xYEqaHt4E1Mh+IDB92YSncGWsUP0yJ4qk
        ioGah68+kKpEoKxKR4PlmXgM69dRl5WYHUjHT3x8WDP5hBPBZwTqBwuATrt/SyPaLwaoWbiu2Gi3hnW3agJ584V9MRohXk8x5EOA
        uv98/qvyD8HJIADTI2rkHxBZdKhDIRH5QHTv0VtrASvRI3fpWC4vPR8ItjxJUbJBzfMWUjQGz8hBxUUat4GuACaY0aaXop4aIqxw
        iPcPBJhWsowbzQx6ZT8qIuSgq7sfWrKNgXr9/hziwOuRGOClBJzotdATCiiy8M2VLJuD4r4Azc0BBVkNl8FWBTCCAQIGCSqGSIb3
        DQEHAaCB9ASB8TCB7jCB6wYLKoZIhvcNAQwKAQKggbQwgbEwHAYKKoZIhvcNAQwBAzAOBAgwRgdlUFqTWAICCAAEgZCMgyO0KcUG
        4laMkwOB4xX8K3LVNaJghh/tycCWypPx0rAvivnvGDI/E9hIbDLWMKmFFOxtfvHjZRy1VPRYidwyBB0wX3PNpxO/q9xm31f8+J5L
        92D8oTcA37lS/Bi5cKNGxtDogc9TlHxZtlA/Xd1QYQqRbrfMph8QjRe0PYjIY+rG+sJRgKoLJI6QXbWoYOAxJTAjBgkqhkiG9w0B
        CRUxFgQUTcH1pHfiv3i5ZX5rrwFG4ftS4WowMTAhMAkGBSsOAwIaBQAEFNk8j2UEABKxSYKwsWl+PUYgimNgBAiIX0z2rkdCogIC
        CAA=
        """
}
