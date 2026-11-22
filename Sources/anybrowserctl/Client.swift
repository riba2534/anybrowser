import AnyBrowserCore
import Foundation
import SQLite3

/// Why the command stopped; each kind has its own exit status.
enum Failure: Error {
    /// The command line is wrong (exit 2).
    case usage(String)
    /// The API answered with an error (exit 1).
    case api(status: Int, code: String, message: String)
    /// No Profile, or more than one, has the name given (exit 1, as for an id the API does not know).
    case name(String)
    /// No token, no connection, or a local file problem (exit 3).
    case local(String)

    var status: Int32 {
        switch self {
        case .usage: return 2
        case .api, .name: return 1
        case .local: return 3
        }
    }

    var message: String {
        switch self {
        case .usage(let text): return "\(text)\n运行 anybrowserctl help 查看用法。"
        case let .api(status, code, message): return "\(message)（HTTP \(status)，\(code)）"
        case .name(let text), .local(let text): return text
        }
    }
}

/// Where the API listens and its token: `--port`/`--token`, then `ANYBROWSER_PORT`/`ANYBROWSER_TOKEN`,
/// then the settings AnyBrowser saved. The database is opened read-only and never through
/// `ProfileStore`, which would migrate it, back it up and change its permissions.
struct Connection {
    var port: Int
    var token: String

    static func resolve(port: String?, token: String?, dataDirectory: String?,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Connection {
        let givenPort = port ?? environment["ANYBROWSER_PORT"].flatMap { $0.isEmpty ? nil : $0 }
        let givenToken = token ?? environment["ANYBROWSER_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        var number: Int?
        if let givenPort {
            guard let value = Int(givenPort), (1...65535).contains(value) else { throw Failure.usage("端口须为 1–65535 的整数：\(givenPort)") }
            number = value
        }
        if let givenToken, let number { return Connection(port: number, token: givenToken) }
        let directory = dataDirectory ?? environment["ANYBROWSER_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let saved = try savedSettings(in: directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory())
        if givenToken == nil {
            guard let saved else {
                throw Failure.local("没有访问令牌：请用 --token 或环境变量 ANYBROWSER_TOKEN 指定，或在 AnyBrowser 的「自动化接口…」里打开自动化接口。")
            }
            guard saved.enabled else {
                throw Failure.local("自动化接口未开启：请在 AnyBrowser 菜单「自动化接口…」里打开开关，或用 --token 和 --port 指定。")
            }
        }
        return Connection(port: number ?? saved?.port ?? AutomationConfiguration.defaultPort, token: givenToken ?? saved?.token ?? "")
    }

    private static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnyBrowser", isDirectory: true)
    }

    /// The automation settings in the database under `directory`, or nil without one.
    static func savedSettings(in directory: URL?) throws -> AutomationConfiguration? {
        // SQLITE_OPEN_NOFOLLOW refuses a symbolic link anywhere in the path, such as /tmp, so the
        // directory is resolved first, as AnyBrowser resolves it before opening the database.
        guard let directory, let root = ProcessInspection.canonicalURL(directory, isDirectory: true) else { return nil }
        let path = root.appendingPathComponent(ProfileStore.databaseFileName).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            throw Failure.local("无法读取 AnyBrowser 的数据库 \(path)。")
        }
        sqlite3_busy_timeout(database, 2000)
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM settings WHERE key=?", -1, &query, nil) == SQLITE_OK,
              sqlite3_bind_text(query, 1, ProfileStore.automationKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
            throw Failure.local("无法读取 AnyBrowser 数据库中的自动化接口设置。")
        }
        guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        return try? JSONDecoder().decode(AutomationConfiguration.self, from: data).validated()
    }
}

/// The automation API on 127.0.0.1, without proxies, cookies or stored credentials. Where it
/// listens is worked out at the first request, so usage errors come first.
final class Client {
    private let resolve: () throws -> Connection
    private var resolved: Connection?
    private let session: URLSession

    init(_ resolve: @escaping () throws -> Connection) {
        self.resolve = resolve
        let configuration = URLSessionConfiguration.loopback
        // Starting browsers for a cookie transfer or checking many proxies takes a while.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    /// Sends one request and returns the JSON body of a 2xx answer.
    func send(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil,
              raw: Data? = nil) async throws -> Data {
        let connection = try resolved ?? resolve()
        resolved = connection
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = connection.port
        components.percentEncodedPath = path
        if !query.isEmpty {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            components.percentEncodedQuery = query.map { name, value in
                "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }.joined(separator: "&")
        }
        guard let url = components.url else { throw Failure.usage("无法组成请求地址：\(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let raw {
            request.httpBody = raw
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.local("无法连接 127.0.0.1:\(connection.port)：请确认 AnyBrowser 正在运行并已打开自动化接口。（\(error.localizedDescription)）")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw Failure.api(status: status, code: error?["code"] as? String ?? "error",
                              message: error?["message"] as? String ?? "自动化接口返回了错误。")
        }
        return data
    }

    func object(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil) async throws -> [String: Any] {
        let data = try await send(method, path, query: query, json: json)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.local("自动化接口返回的内容无法识别。")
        }
        return object
    }

    /// The id of the Profile named `text` (an id is taken as it is), among the saved Profiles, those
    /// in the recycle bin, or both. A name has to be unique across every list searched, so one shared
    /// by a saved and a trashed Profile is refused rather than read as either.
    func profileID(_ text: String, saved: Bool = true, trashed: Bool = false) async throws -> String {
        if let id = UUID(uuidString: text) { return id.uuidString }
        var matches: [String] = []
        for (searched, path) in [(saved, "/api/v1/profiles"), (trashed, "/api/v1/trash")] where searched {
            let list = try await object("GET", path)
            matches += (list["profiles"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == text }
                .compactMap { $0["id"] as? String }
        }
        let place = trashed ? (saved ? "（含回收站）" : "（回收站中）") : ""
        guard let id = matches.first else { throw Failure.name("找不到名为「\(text)」的 Profile\(place)。") }
        guard matches.count == 1 else { throw Failure.name("有 \(matches.count) 个名为「\(text)」的 Profile\(place)，请改用 id。") }
        return id
    }
}

/// Options and positional arguments of one command. Options take `--name value` or `--name=value`;
/// `--` ends them.
struct Arguments {
    var positionals: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ tokens: [String], valued: Set<String>, flags known: Set<String>) throws {
        var index = 0
        var optionsEnded = false
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard !optionsEnded, token.hasPrefix("--"), token.count > 2 else {
                if token == "--", !optionsEnded { optionsEnded = true } else { positionals.append(token) }
                continue
            }
            let body = token.dropFirst(2)
            let name = String(body.prefix { $0 != "=" })
            let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
            if valued.contains(name) {
                if let inline {
                    values[name, default: []].append(inline)
                } else {
                    guard index < tokens.count else { throw Failure.usage("--\(name) 需要一个值。") }
                    values[name, default: []].append(tokens[index])
                    index += 1
                }
            } else if known.contains(name), inline == nil {
                flags.insert(name)
            } else {
                throw Failure.usage("无法识别的选项：--\(name)")
            }
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func values(_ name: String) -> [String] { values[name] ?? [] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    func integer(_ name: String) throws -> Int? {
        guard let text = value(name) else { return nil }
        guard let number = Int(text) else { throw Failure.usage("--\(name) 须为整数：\(text)") }
        return number
    }

    /// `--json` as an object: inline JSON, or `@<file>`.
    func json() throws -> [String: Any] {
        guard let text = value("json") else { return [:] }
        let data: Data
        if text.hasPrefix("@") {
            guard let contents = FileManager.default.contents(atPath: String(text.dropFirst())) else {
                throw Failure.local("无法读取文件 \(text.dropFirst())。")
            }
            data = contents
        } else {
            data = Data(text.utf8)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.usage("--json 须为 JSON 对象。")
        }
        return object
    }

    func expect(_ count: ClosedRange<Int>, _ usage: String) throws {
        guard count.contains(positionals.count) else { throw Failure.usage("用法：anybrowserctl \(usage)") }
    }
}
