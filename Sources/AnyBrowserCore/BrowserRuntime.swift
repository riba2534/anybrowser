import AppKit
import Combine
import Darwin
import Foundation

public struct BrowserEngine: Sendable {
    public let version: String
    let executable: URL
    let passkeyBoxDirectory: URL

    public static func bundled(in bundleURL: URL = Bundle.main.bundleURL) throws -> BrowserEngine {
        guard let root = ProcessInspection.canonicalURL(bundleURL, isDirectory: true) else {
            throw BrowserRuntimeError.message("无法定位 AnyBrowser 应用。")
        }
        let engineURL = root.appendingPathComponent("Contents/Frameworks/Chromium.app", isDirectory: true)
        guard ProcessInspection.canonicalURL(engineURL, isDirectory: true)?.path == engineURL.path,
              let bundle = Bundle(url: engineURL),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty, let entry = bundle.executableURL,
              let executable = ProcessInspection.canonicalURL(entry),
              executable.path.hasPrefix(engineURL.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BrowserRuntimeError.message("内置 Chromium 不可用，请重新安装 AnyBrowser。")
        }
        let extensionURL = root.appendingPathComponent("Contents/Resources/Extensions/PasskeyBox", isDirectory: true)
        let manifest = extensionURL.appendingPathComponent("manifest.json")
        guard ProcessInspection.canonicalURL(extensionURL, isDirectory: true)?.path == extensionURL.path,
              ProcessInspection.canonicalURL(manifest)?.path == manifest.path,
              FileManager.default.isReadableFile(atPath: manifest.path) else {
            throw BrowserRuntimeError.message("内置 Passkey Box 不可用，请重新安装 AnyBrowser。")
        }
        // Chromium parses --load-extension as a comma-separated list.
        guard !extensionURL.path.contains(",") else {
            throw BrowserRuntimeError.message("请将 AnyBrowser 移到路径不含逗号的目录。")
        }
        return BrowserEngine(version: version, executable: executable, passkeyBoxDirectory: extensionURL)
    }
}

enum BrowserRuntimeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        }
    }
}

private final class LocalOnlySession: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
public final class BrowserRuntime: ObservableObject {
    @Published public private(set) var states: [UUID: BrowserRunState] = [:]

    struct Receipt: Codable, Equatable {
        let pid: Int32
        let stamp: ProcessStamp
        let port: Int
        let device: Int32
        let inode: UInt64
    }

    let engine: BrowserEngine
    let storage: URL
    let localSession: URLSession
    private var children: [UUID: Process] = [:]

    public init(engine: BrowserEngine, storage: URL) {
        self.engine = engine
        let path = storage.standardizedFileURL
        self.storage = ProcessInspection.canonicalURL(path, isDirectory: true)
            ?? ProcessInspection.canonicalURL(path.deletingLastPathComponent(), isDirectory: true)?
                .appendingPathComponent(path.lastPathComponent, isDirectory: true)
            ?? path
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        localSession = URLSession(configuration: configuration, delegate: LocalOnlySession(), delegateQueue: nil)
    }

    deinit { localSession.invalidateAndCancel() }

    public func dataDirectory(for id: UUID) -> URL {
        storage.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func status(for id: UUID) -> BrowserRunState { states[id] ?? .stopped }

    public func matchesRunningConfiguration(_ profile: BrowserProfile) -> Bool? {
        guard case let .running(pid, _, _) = status(for: profile.id) else { return nil }
        let directory = dataDirectory(for: profile.id)
        guard let receipt = readReceipt(directory), receipt.pid == pid, owns(receipt, directory: directory),
              let arguments = ProcessInspection.arguments(pid), ProcessStamp.read(pid) == receipt.stamp else { return nil }
        return arguments.dropFirst().elementsEqual(launchArguments(profile, directory: directory))
    }

    /// Starts the Profile's browser. Passkey Box signs in with `passkeyBox` when it is set.
    public func start(_ profile: BrowserProfile, passkeyBox: PasskeyBoxAccount? = nil) async throws {
        let profile = try profile.validated()
        let id = profile.id
        guard status(for: id) != .starting && status(for: id) != .stopping else { return }
        let directory = dataDirectory(for: id)
        states[id] = .starting
        do {
            try ensureDirectory(storage)
            try ensureDirectory(directory.deletingLastPathComponent())
            try ensureDirectory(directory)
            let lock = try lockDirectory(directory)
            defer { close(lock) }
            if let receipt = readReceipt(directory) {
                switch await runningState(receipt, directory: directory) {
                case let .running(pid, port, ready):
                    states[id] = .running(pid: pid, port: port, debugReady: ready)
                    if !ready {
                        throw BrowserRuntimeError.message("浏览器正在运行，但本机调试端口 \(port) 尚未就绪。")
                    }
                    return
                default:
                    break
                }
            }
            guard !profileInUse(directory) else {
                throw BrowserRuntimeError.message("此 Profile 的资料目录正在使用，请先在浏览器中退出。")
            }
            guard ProcessInspection.portAvailable(profile.port) else {
                throw BrowserRuntimeError.message("调试端口 \(profile.port) 已占用，请修改此 Profile 的端口。")
            }
            try profile.launch.checkExtensionDirectories()
            try PasskeyBoxInstall.prepare(bundled: engine.passkeyBoxDirectory, in: storage, for: id, account: passkeyBox)
            try ProxyAuthExtension.prepare(for: profile, in: storage)
            let child = Process()
            child.executableURL = engine.executable
            child.arguments = launchArguments(profile, directory: directory)
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] process in
                let pid = process.processIdentifier
                Task { @MainActor [weak self] in self?.childExited(id: id, pid: pid) }
            }
            try child.run()
            children[id] = child
            var launchReceipt: Receipt?
            do {
                let details = try directoryDetails(directory)
                guard let stamp = ProcessStamp.read(child.processIdentifier) else {
                    throw BrowserRuntimeError.message("Chromium 在调试端口就绪前退出。")
                }
                let receipt = Receipt(pid: child.processIdentifier, stamp: stamp, port: profile.port,
                                      device: details.st_dev, inode: details.st_ino)
                try JSONEncoder().encode(receipt).write(to: receiptURL(directory), options: .atomic)
                launchReceipt = receipt
                let deadline = ProcessInfo.processInfo.systemUptime + 20
                while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    if await verifyEndpoint(receipt, directory: directory) {
                        states[id] = .running(pid: receipt.pid, port: receipt.port, debugReady: true)
                        return
                    }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                throw BrowserRuntimeError.message(child.isRunning
                    ? "Chromium 未能在本机端口 \(profile.port) 启用调试。"
                    : "Chromium 在调试端口就绪前退出。")
            } catch {
                // Process tracks the specific child we created, including before writing its receipt.
                if child.isRunning { child.terminate() }
                if let receipt = launchReceipt {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while owns(receipt, directory: directory), ProcessInfo.processInfo.systemUptime < deadline {
                        do {
                            try await Task.sleep(nanoseconds: 100_000_000)
                        } catch {
                            break
                        }
                    }
                    if owns(receipt, directory: directory) {
                        states[id] = .running(pid: receipt.pid, port: receipt.port, debugReady: false)
                    }
                }
                throw error
            }
        } catch {
            if status(for: id) == .starting {
                states[id] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    public func stop(_ id: UUID) async throws {
        let oldState = status(for: id)
        guard oldState != .starting && oldState != .stopping else { return }
        let directory = dataDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            states[id] = .stopped
            return
        }
        let lock = try lockDirectory(directory)
        defer { close(lock) }
        guard let receipt = readReceipt(directory), owns(receipt, directory: directory) else {
            if profileInUse(directory) {
                throw BrowserRuntimeError.message("无法确认该浏览器进程的归属，请从浏览器窗口退出。")
            }
            states[id] = .stopped
            return
        }
        states[id] = .stopping
        do {
            // Revalidate just before requesting termination. Never signal by name or port.
            guard owns(receipt, directory: directory) else {
                throw BrowserRuntimeError.message("浏览器进程已变化，请刷新状态。")
            }
            if NSRunningApplication(processIdentifier: receipt.pid)?.terminate() != true {
                guard owns(receipt, directory: directory), kill(receipt.pid, SIGTERM) == 0 else {
                    throw BrowserRuntimeError.message("无法关闭此 Profile 的浏览器进程。")
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while ProcessStamp.read(receipt.pid) == receipt.stamp {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw BrowserRuntimeError.message("浏览器尚未退出，请在窗口中处理确认提示。")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try? FileManager.default.removeItem(at: receiptURL(directory))
            states[id] = .stopped
        } catch {
            states[id] = await runningState(receipt, directory: directory)
            throw error
        }
    }

    public func refresh(_ profiles: [BrowserProfile]) async {
        for profile in profiles {
            let id = profile.id
            let previous = status(for: id)
            guard previous != .starting && previous != .stopping else { continue }
            let directory = dataDirectory(for: id)
            guard let receipt = readReceipt(directory) else {
                if case .running = previous { states[id] = .stopped }
                continue
            }
            let result = await runningState(receipt, directory: directory)
            guard status(for: id) == previous, readReceipt(directory) == receipt else { continue }
            if result == .stopped, case .failed = previous { continue }
            if result != previous { states[id] = result }
        }
    }

    private func childExited(id: UUID, pid: Int32) {
        guard children[id]?.processIdentifier == pid else { return }
        children[id] = nil
        if case .running(let runningPID, _, _) = status(for: id), runningPID == pid {
            states[id] = .stopped
        }
    }

    private func launchArguments(_ profile: BrowserProfile, directory: URL) -> [String] {
        profile.launchArguments(userDataDirectory: directory,
                                extensions: ProfileExtensions.paths(for: profile, in: storage))
    }

    /// The browser-level DevTools WebSocket of a running Profile, verified to belong to it.
    public func devToolsEndpoint(for id: UUID) async -> URL? {
        guard case let .running(pid, port, _) = status(for: id) else { return nil }
        let directory = dataDirectory(for: id)
        guard let receipt = readReceipt(directory), receipt.pid == pid, receipt.port == port else { return nil }
        return await verifiedEndpoint(receipt, directory: directory)
    }

    private func runningState(_ receipt: Receipt, directory: URL) async -> BrowserRunState {
        guard owns(receipt, directory: directory) else { return .stopped }
        let ready = await verifyEndpoint(receipt, directory: directory)
        guard owns(receipt, directory: directory) else { return .stopped }
        return .running(pid: receipt.pid, port: receipt.port, debugReady: ready)
    }

    private func verifyEndpoint(_ receipt: Receipt, directory: URL) async -> Bool {
        await verifiedEndpoint(receipt, directory: directory) != nil
    }

    private func verifiedEndpoint(_ receipt: Receipt, directory: URL) async -> URL? {
        guard owns(receipt, directory: directory),
              ProcessInspection.hasLoopbackDebugListener(pid: receipt.pid, port: receipt.port),
              let url = URL(string: "http://127.0.0.1:\(receipt.port)/json/version"),
              let (data, response) = try? await localSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let address = info["webSocketDebuggerUrl"],
              let endpoint = URLComponents(string: address), endpoint.scheme == "ws",
              endpoint.host == "127.0.0.1", endpoint.port == receipt.port,
              endpoint.path.hasPrefix("/devtools/browser/"), let url = endpoint.url else { return nil }
        guard owns(receipt, directory: directory),
              ProcessInspection.hasLoopbackDebugListener(pid: receipt.pid, port: receipt.port) else { return nil }
        return url
    }

    func owns(_ receipt: Receipt, directory: URL) -> Bool {
        guard ProcessStamp.read(receipt.pid) == receipt.stamp,
              let details = try? directoryDetails(directory),
              details.st_dev == receipt.device, details.st_ino == receipt.inode,
              let image = ProcessInspection.image(receipt.pid),
              ProcessInspection.hasFlag("--user-data-dir", value: directory.path, arguments: image.arguments),
              ProcessInspection.hasFlag("--remote-debugging-port", value: String(receipt.port), arguments: image.arguments)
        else { return false }

        let child = UUID(uuidString: directory.lastPathComponent).flatMap { children[$0] }
        let trackedChild = child?.processIdentifier == receipt.pid && child?.isRunning == true
        // macOS can report a code-signing clone through proc_pidpath. The initial
        // executable path in the process argument area still identifies the bundle we launched.
        let executableConfirmed = trackedChild || image.executablePath == engine.executable.path
            || ProcessInspection.executable(receipt.pid) == engine.executable
        return executableConfirmed && ProcessStamp.read(receipt.pid) == receipt.stamp
    }

    func profileInUse(_ directory: URL) -> Bool {
        let lock = directory.appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let suffix = target.split(separator: "-").last, let pid = Int32(suffix), pid > 1,
              ProcessStamp.read(pid) != nil else { return false }
        guard let arguments = ProcessInspection.arguments(pid) else { return true }
        return ProcessInspection.hasFlag("--user-data-dir", value: directory.path, arguments: arguments)
    }

    func receiptURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(".anybrowser-runtime.json")
    }

    func readReceipt(_ directory: URL) -> Receipt? {
        guard (try? directoryDetails(directory)) != nil else { return nil }
        let fd = open(receiptURL(directory).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, (1...4096).contains(metadata.st_size),
              let data = try? file.read(upToCount: 4096) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = try directoryDetails(url)
    }

    func directoryDetails(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o022 == 0,
              ProcessInspection.canonicalURL(url, isDirectory: true)?.path == url.path else {
            throw BrowserRuntimeError.message("资料目录不可用，请检查本机目录权限。")
        }
        return metadata
    }

    func lockDirectory(_ directory: URL) throws -> Int32 {
        _ = try directoryDetails(directory)
        let url = directory.appendingPathComponent(".anybrowser-runtime.lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BrowserRuntimeError.message("无法锁定此 Profile 的资料目录。") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw BrowserRuntimeError.message("此 Profile 正在执行另一个操作，请稍后重试。")
        }
        return fd
    }
}
