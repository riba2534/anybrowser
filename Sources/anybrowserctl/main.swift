import Darwin
import Foundation

// A command-line client for AnyBrowser's automation API. It prints the API's JSON answer, or with
// an error a message on stderr and a non-zero exit status.

let usage = """
用法：anybrowserctl [--port 端口] [--token 令牌] [--data-dir 目录] [--pretty] <命令> [参数]

Profile（<Profile> 为 id 或名称）：
  list [--query 搜索] [--group 分组] [--tag 标签]... [--status 运行状态] [--account-status 账号状态] [--trash]
  show <Profile> [--secrets]
  create [--name 名称] [--group 分组] [--preset 模板] [--proxy 地址 | --proxy-from-library <id|unused>]
         [--tag 标签]... [--notes 备注] [--account-status 状态] [--no-exit-locale] [--json 字段|@文件]
         [--count 数量 [--prefix 前缀]]
  update <Profile> [--name 名称] [--group 分组] [--proxy 地址] [--tag 标签]... [--notes 备注]
         [--account-status 状态] [--json 字段|@文件]
  clone <Profile> [--name 名称]
  delete <Profile> [--purge [--delete-data]]
  restore <Profile>

启动与停止：
  start <Profile> [--headless] [--url 网址]... [--arg 开关]...
  stop <Profile> [--force]
  restart <Profile> [--headless] [--url 网址]... [--arg 开关]...

运维：
  log <Profile>
  cookies export <Profile> [--format cookieEditor|devTools] [--output 文件]
  cookies import <Profile> <文件|->
  selfcheck <Profile>
  arrange [<Profile>...] [--columns 列数]

代理库：
  proxies list [--secrets]
  proxies add [--label 名称] (<地址>... | --file 文件 | -)
  proxies check [<id>...]

令牌和端口依次取自 --token、--port，环境变量 ANYBROWSER_TOKEN、ANYBROWSER_PORT，最后只读读取
AnyBrowser 保存的自动化接口设置（数据目录默认 ~/Library/Application Support/AnyBrowser，可用
--data-dir 或 ANYBROWSER_DATA_DIR 指定）。退出状态：0 成功，1 接口返回错误，2 用法错误，3 无法连接或读取。
"""

/// The options each command accepts, beside the global ones.
let commandOptions: [String: (valued: Set<String>, flags: Set<String>)] = [
    "list": (["query", "group", "tag", "status", "account-status"], ["trash"]),
    "show": ([], ["secrets"]),
    "create": (["name", "group", "preset", "proxy", "proxy-from-library", "tag", "notes", "account-status", "json",
                "count", "prefix"], ["no-exit-locale"]),
    "update": (["name", "group", "proxy", "tag", "notes", "account-status", "json"], []),
    "clone": (["name"], []),
    "delete": ([], ["purge", "delete-data"]),
    "restore": ([], []),
    "start": (["url", "arg"], ["headless"]),
    "stop": ([], ["force"]),
    "restart": (["url", "arg"], ["headless"]),
    "log": ([], []),
    "cookies": (["format", "output"], []),
    "selfcheck": ([], []),
    "arrange": (["columns"], []),
    "proxies": (["label", "file"], ["secrets"]),
]
let globalValued: Set<String> = ["port", "token", "data-dir"]
let globalFlags: Set<String> = ["pretty", "help"]

func write(_ text: String, to handle: FileHandle) {
    handle.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
}

/// The answer as the API sent it, or re-indented with `--pretty`.
func output(_ data: Data, pretty: Bool) {
    if pretty, let value = try? JSONSerialization.jsonObject(with: data),
       let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        write(String(decoding: formatted, as: UTF8.self), to: .standardOutput)
    } else {
        write(String(decoding: data, as: UTF8.self), to: .standardOutput)
    }
}

func encoded(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Reads a file, or standard input for `-`.
func contents(of path: String) throws -> Data {
    if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
    guard let data = FileManager.default.contents(atPath: path) else { throw Failure.local("无法读取文件 \(path)。") }
    return data
}

/// Profile fields from the shared options of create and update; `--json` first, options over it.
func profileFields(_ arguments: Arguments) throws -> [String: Any] {
    var fields = try arguments.json()
    for (option, key) in [("name", "name"), ("group", "group"), ("proxy", "proxy"), ("notes", "notes"),
                          ("account-status", "accountStatus")] {
        if let value = arguments.value(option) { fields[key] = value }
    }
    if !arguments.values("tag").isEmpty { fields["tags"] = arguments.values("tag") }
    return fields
}

func launchBody(_ arguments: Arguments) -> [String: Any] {
    var body: [String: Any] = [:]
    if arguments.flag("headless") { body["headless"] = true }
    if !arguments.values("url").isEmpty { body["urls"] = arguments.values("url") }
    if !arguments.values("arg").isEmpty { body["args"] = arguments.values("arg") }
    return body
}

func run(_ command: String, _ subcommand: String?, _ arguments: Arguments, _ client: Client) async throws -> Data {
    let positionals = arguments.positionals
    func profile(_ index: Int = 0) async throws -> String { try await client.profileID(positionals[index]) }
    switch command {
    case "list":
        try arguments.expect(0...0, "list [选项]")
        if arguments.flag("trash") { return try await client.send("GET", "/api/v1/trash") }
        var query: [(String, String)] = []
        for (option, name) in [("query", "q"), ("group", "group"), ("tag", "tag"), ("status", "status"),
                               ("account-status", "accountStatus")] {
            query += arguments.values(option).map { (name, $0) }
        }
        return try await client.send("GET", "/api/v1/profiles", query: query)
    case "show":
        try arguments.expect(1...1, "show <Profile> [--secrets]")
        return try await client.send("GET", "/api/v1/profiles/\(try await profile())",
                                     query: arguments.flag("secrets") ? [("secrets", "1")] : [])
    case "create":
        try arguments.expect(0...0, "create [选项]")
        var body = try profileFields(arguments)
        if let preset = arguments.value("preset") { body["preset"] = preset }
        if let library = arguments.value("proxy-from-library") { body["proxyFromLibrary"] = library }
        if arguments.flag("no-exit-locale") { body["localeFromExit"] = false }
        guard let count = try arguments.integer("count") else {
            if arguments.value("prefix") != nil { throw Failure.usage("--prefix 只能与 --count 一起使用。") }
            return try await client.send("POST", "/api/v1/profiles", json: body)
        }
        if body["name"] != nil { throw Failure.usage("批量新建时用 --prefix 指定名称前缀，不能用 --name。") }
        body["count"] = count
        if let prefix = arguments.value("prefix") { body["prefix"] = prefix }
        return try await client.send("POST", "/api/v1/profiles/batch", json: body)
    case "update":
        try arguments.expect(1...1, "update <Profile> [选项]")
        let fields = try profileFields(arguments)
        guard !fields.isEmpty else { throw Failure.usage("没有要修改的字段，请用 --name、--json 等选项指定。") }
        return try await client.send("PATCH", "/api/v1/profiles/\(try await profile())", json: fields)
    case "clone":
        try arguments.expect(1...1, "clone <Profile> [--name 名称]")
        let body: [String: Any] = arguments.value("name").map { ["name": $0] } ?? [:]
        return try await client.send("POST", "/api/v1/profiles/\(try await profile())/clone", json: body)
    case "delete":
        try arguments.expect(1...1, "delete <Profile> [--purge [--delete-data]]")
        let purge = arguments.flag("purge")
        guard purge || !arguments.flag("delete-data") else { throw Failure.usage("--delete-data 须与 --purge 一起使用。") }
        var id: String
        do {
            id = try await profile()
        } catch Failure.local(_) where purge {
            // Purging also reaches Profiles already in the recycle bin.
            id = try await client.profileID(positionals[0], inTrash: true)
        }
        var query: [(String, String)] = purge ? [("purge", "1")] : []
        if arguments.flag("delete-data") { query.append(("deleteData", "1")) }
        return try await client.send("DELETE", "/api/v1/profiles/\(id)", query: query)
    case "restore":
        try arguments.expect(1...1, "restore <Profile>")
        return try await client.send("POST", "/api/v1/profiles/\(try await client.profileID(positionals[0], inTrash: true))/restore")
    case "start", "restart":
        try arguments.expect(1...1, "\(command) <Profile> [--headless] [--url 网址]... [--arg 开关]...")
        return try await client.send("POST", "/api/v1/profiles/\(try await profile())/\(command)", json: launchBody(arguments))
    case "stop":
        try arguments.expect(1...1, "stop <Profile> [--force]")
        return try await client.send("POST", "/api/v1/profiles/\(try await profile())/stop",
                                     query: arguments.flag("force") ? [("force", "1")] : [])
    case "log", "selfcheck":
        try arguments.expect(1...1, "\(command) <Profile>")
        return try await client.send("GET", "/api/v1/profiles/\(try await profile())/\(command)")
    case "cookies":
        return try await cookies(subcommand, arguments, client)
    case "arrange":
        var body: [String: Any] = [:]
        if !positionals.isEmpty {
            var ids: [String] = []
            for name in positionals { ids.append(try await client.profileID(name)) }
            body["ids"] = ids
        }
        if let columns = try arguments.integer("columns") { body["columns"] = columns }
        return try await client.send("POST", "/api/v1/windows/arrange", json: body)
    case "proxies":
        return try await proxies(subcommand, arguments, client)
    default:
        throw Failure.usage("没有这个命令：\(command)")
    }
}

func cookies(_ subcommand: String?, _ arguments: Arguments, _ client: Client) async throws -> Data {
    switch subcommand {
    case "export":
        try arguments.expect(1...1, "cookies export <Profile> [--format cookieEditor|devTools] [--output 文件]")
        let id = try await client.profileID(arguments.positionals[0])
        let data = try await client.send("GET", "/api/v1/profiles/\(id)/cookies",
                                         query: arguments.value("format").map { [("format", $0)] } ?? [])
        guard let path = arguments.value("output") else { return data }
        // The file holds just the cookie list, ready for import elsewhere; only this user may read it.
        guard var answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let cookies = answer["cookies"] else {
            throw Failure.local("自动化接口返回的内容无法识别。")
        }
        let file = try JSONSerialization.data(withJSONObject: cookies, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.createFile(atPath: url.path, contents: file, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.local("无法写入文件 \(path)。")
        }
        answer["cookies"] = nil
        answer["output"] = url.path
        return try encoded(answer)
    case "import":
        try arguments.expect(2...2, "cookies import <Profile> <文件|->")
        let id = try await client.profileID(arguments.positionals[0])
        let file = try contents(of: arguments.positionals[1])
        return try await client.send("POST", "/api/v1/profiles/\(id)/cookies", raw: file)
    default:
        throw Failure.usage("用法：anybrowserctl cookies export|import <Profile> …")
    }
}

func proxies(_ subcommand: String?, _ arguments: Arguments, _ client: Client) async throws -> Data {
    switch subcommand {
    case "list":
        try arguments.expect(0...0, "proxies list [--secrets]")
        return try await client.send("GET", "/api/v1/proxies", query: arguments.flag("secrets") ? [("secrets", "1")] : [])
    case "add":
        var body: [String: Any] = [:]
        if let label = arguments.value("label") { body["label"] = label }
        let positionals = arguments.positionals
        if let file = arguments.value("file") {
            guard positionals.isEmpty else { throw Failure.usage("--file 与地址参数只能用一种。") }
            body["text"] = String(decoding: try contents(of: file), as: UTF8.self)
        } else if positionals == ["-"] {
            body["text"] = String(decoding: try contents(of: "-"), as: UTF8.self)
        } else {
            guard !positionals.isEmpty else { throw Failure.usage("用法：anybrowserctl proxies add [--label 名称] (<地址>... | --file 文件 | -)") }
            body["urls"] = positionals
        }
        return try await client.send("POST", "/api/v1/proxies", json: body)
    case "check":
        var body: [String: Any] = [:]
        if !arguments.positionals.isEmpty { body["ids"] = arguments.positionals }
        return try await client.send("POST", "/api/v1/proxies/check", json: body)
    default:
        throw Failure.usage("用法：anybrowserctl proxies list|add|check …")
    }
}

/// The command and, for cookies and proxies, its subcommand: the first words that are neither
/// options nor option values. The rest is left for the command's own options.
func split(_ tokens: [String]) -> (command: String?, subcommand: String?, rest: [String]) {
    var rest: [String] = []
    var command: String?
    var subcommand: String?
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        index += 1
        if token.hasPrefix("--"), token.count > 2 {
            rest.append(token)
            let name = String(token.dropFirst(2).prefix { $0 != "=" })
            let valued = globalValued.union(command.flatMap { commandOptions[$0]?.valued } ?? [])
            if valued.contains(name), !token.contains("="), index < tokens.count {
                rest.append(tokens[index])
                index += 1
            }
        } else if command == nil {
            command = token
        } else if subcommand == nil, command == "cookies" || command == "proxies" {
            subcommand = token
        } else {
            rest.append(token)
        }
    }
    return (command, subcommand, rest)
}

func main() async -> Int32 {
    let (command, subcommand, rest) = split(Array(CommandLine.arguments.dropFirst()))
    guard let command, command != "help" else {
        write(usage, to: command == nil && !rest.contains("--help") ? .standardError : .standardOutput)
        return command == nil && !rest.contains("--help") ? 2 : 0
    }
    do {
        guard let options = commandOptions[command] else { throw Failure.usage("没有这个命令：\(command)") }
        let arguments = try Arguments(rest, valued: globalValued.union(options.valued), flags: globalFlags.union(options.flags))
        if arguments.flag("help") {
            write(usage, to: .standardOutput)
            return 0
        }
        let client = Client {
            try Connection.resolve(port: arguments.value("port"), token: arguments.value("token"),
                                   dataDirectory: arguments.value("data-dir"))
        }
        let data = try await run(command, subcommand, arguments, client)
        output(data, pretty: arguments.flag("pretty"))
        return 0
    } catch let failure as Failure {
        write("anybrowserctl：\(failure.message)", to: .standardError)
        return failure.status
    } catch {
        write("anybrowserctl：\(error.localizedDescription)", to: .standardError)
        return 1
    }
}

exit(await main())
