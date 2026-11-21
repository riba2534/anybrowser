import Darwin
import Foundation

/// The Passkey Box server account every Profile's built-in extension signs in with.
public struct PasskeyBoxAccount: Codable, Equatable, Sendable {
    public static let defaultServerURL = "https://password.riba2534.cn"

    public var serverURL: String
    public var username: String
    public var password: String

    public init(serverURL: String = PasskeyBoxAccount.defaultServerURL, username: String = "", password: String = "") {
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }

    /// Normalizes the server address the way the extension does: trims it, adds https:// when no
    /// scheme is given and drops trailing slashes.
    public func validated() throws -> PasskeyBoxAccount {
        var address = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil {
            address = "https://" + address
        }
        while address.hasSuffix("/") { address.removeLast() }
        guard address.utf8.count <= 2048, let parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw ProfileError.invalid("Passkey Box 服务器地址须为 http:// 或 https:// 网址。")
        }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // HTTP Basic authentication ends the user name at the first colon.
        guard !name.isEmpty, name.count <= 128, !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ProfileError.invalid("请填写 Passkey Box 用户名，用户名不能包含冒号。")
        }
        guard !password.isEmpty, password.utf8.count <= 1024 else {
            throw ProfileError.invalid("请填写 Passkey Box 密码。")
        }
        return PasskeyBoxAccount(serverURL: address, username: name, password: password)
    }

    /// Signs in with GET /api/v1/me, as the extension's login form does.
    public func verify(configuration: URLSessionConfiguration = .ephemeral) async throws {
        let account = try validated()
        guard let url = URL(string: account.serverURL + "/api/v1/me") else {
            throw ProfileError.invalid("Passkey Box 服务器地址须为 http:// 或 https:// 网址。")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let token = Data("\(account.username):\(account.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProfileError.invalid("无法连接 Passkey Box 服务器：\(error.localizedDescription)")
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (body?["user"] as? [String: Any])?["username"] is String else {
                throw ProfileError.invalid("服务器返回的数据不正确，请检查 Passkey Box 服务器地址。")
            }
        case 401:
            throw ProfileError.invalid("Passkey Box 用户名或密码错误。")
        case let status:
            throw ProfileError.invalid("Passkey Box 服务器返回 \(status.map(String.init) ?? "未知") 状态。")
        }
    }

    /// The managed-config.json the extension reads at startup (see the Passkey Box README).
    func managedConfiguration() throws -> Data {
        let account = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(["serverUrl": account.serverURL, "username": account.username, "password": account.password])
    }
}

/// Never forward the Authorization header to another location.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The unpacked Passkey Box that Profiles load: a copy of the bundled extension in the AnyBrowser
/// data directory, plus managed-config.json when an account is set. The app bundle stays untouched.
enum PasskeyBoxInstall {
    static let managedConfigFile = "managed-config.json"

    static func directory(in storage: URL) -> URL {
        storage.appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent("PasskeyBox", isDirectory: true)
    }

    static func prepare(bundled source: URL, in storage: URL, account: PasskeyBoxAccount?) throws {
        let target = directory(in: storage)
        let parent = target.deletingLastPathComponent()
        // Chromium parses --load-extension as a comma-separated list.
        guard !target.path.contains(",") else {
            throw ProfileError.invalid("AnyBrowser 资料目录的路径不能包含逗号。")
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var details = stat()
        guard lstat(parent.path, &details) == 0, details.st_uid == getuid(), details.st_mode & S_IFMT == S_IFDIR else {
            throw ProfileError.invalid("Passkey Box 扩展目录不可用，请检查本机目录权限。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        guard let bundled = files(in: source) else {
            throw ProfileError.invalid("内置 Passkey Box 不可用，请重新安装 AnyBrowser。")
        }
        // Only a real directory counts as installed; a link to elsewhere is replaced.
        var installed = lstat(target.path, &details) == 0 && details.st_mode & S_IFMT == S_IFDIR ? files(in: target) : nil
        installed?[managedConfigFile] = nil
        if installed != bundled {
            let staging = parent.appendingPathComponent(".PasskeyBox-\(UUID().uuidString)", isDirectory: true)
            let retired = parent.appendingPathComponent(".PasskeyBox-old-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: staging)
            if lstat(target.path, &details) == 0 {
                try FileManager.default.moveItem(at: target, to: retired)
            }
            do {
                try FileManager.default.moveItem(at: staging, to: target)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            try? FileManager.default.removeItem(at: retired)
        }

        let config = target.appendingPathComponent(managedConfigFile)
        guard let account else {
            if lstat(config.path, &details) == 0 { try FileManager.default.removeItem(at: config) }
            return
        }
        let data = try account.managedConfiguration()
        if lstat(config.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_mode & 0o077 == 0,
           (try? Data(contentsOf: config)) == data {
            return
        }
        let temporary = parent.appendingPathComponent(".managed-config-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ProfileError.invalid("无法写入 Passkey Box 账号配置。")
        }
        guard rename(temporary.path, config.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ProfileError.invalid("无法写入 Passkey Box 账号配置。")
        }
    }

    /// Relative path → contents of every regular file, or nil when the tree is missing or holds links.
    private static func files(in root: URL) -> [String: Data]? {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else { return nil }
        var result: [String: Data] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            var details = stat()
            guard lstat(url.path, &details) == 0 else { return nil }
            switch details.st_mode & S_IFMT {
            case S_IFDIR: continue
            case S_IFREG: result[path] = try? Data(contentsOf: url)
            default: return nil
            }
            if result[path] == nil { return nil }
        }
        return result
    }
}
