import CryptoKit
import Darwin
import Foundation

/// An unpacked extension in the shared library.
public struct SharedExtension: Identifiable, Equatable, Sendable {
    /// The library folder name, as `LaunchOptions.sharedExtensions` lists it.
    public var name: String
    /// manifest.json's `name`, with a `__MSG_…__` placeholder looked up in the default locale.
    public var manifestName: String
    public var version: String
    public var directory: URL
    /// False when manifest.json is missing or unreadable; Profiles that load the extension then do not start.
    public var isValid: Bool

    public var id: String { name }
}

/// Unpacked extensions any Profile can load, under `<storage>/Extensions/Shared/<name>/`. The
/// library is read-only to the browser: each Profile keeps the extension's data in its own
/// browser data, under the extension's ID.
///
/// Chromium takes an unpacked extension's ID from the manifest's `key`, or else from its path. An
/// entry keeps its folder for good, and an imported CRX keeps its Web Store key, so the ID, and with
/// it the data in every Profile, stays the same. Adding and removing block on file copies; call
/// them off the main thread.
public enum SharedExtensions {
    public static func root(in storage: URL) -> URL {
        storage.appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent("Shared", isDirectory: true)
    }

    public static func directory(named name: String, in storage: URL) -> URL {
        root(in: storage).appendingPathComponent(name, isDirectory: true)
    }

    /// Every extension in the library, by name.
    public static func list(in storage: URL) -> [SharedExtension] {
        let root = root(in: storage)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter(LaunchOptions.isSharedExtensionName).compactMap { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var details = stat()
            guard stat(directory.path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR else { return nil }
            let manifest = try? Manifest(in: directory)
            return SharedExtension(name: name, manifestName: manifest?.name ?? "", version: manifest?.version ?? "",
                                   directory: directory, isValid: manifest != nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies an unpacked extension folder (with manifest.json at its top) into the library. Adding
    /// one the library already holds returns that entry; see `duplicate(of:at:in:)`.
    @discardableResult
    public static func add(folder source: URL, in storage: URL) throws -> SharedExtension {
        let folder = source.resolvingSymlinksInPath()
        var details = stat()
        guard stat(folder.path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR else {
            throw ProfileError.invalid("请选择扩展所在的文件夹（含 manifest.json）。")
        }
        _ = try Manifest(in: folder)
        return try install(in: storage, fallbackName: folder.lastPathComponent) { staging in
            try FileManager.default.copyItem(at: folder, to: staging)
        }
    }

    /// Unpacks a CRX3 file into the library. The signature is not checked: the file is one the
    /// user picked, and the browser loads the result as an unpacked extension either way. The same
    /// CRX added again returns the existing entry.
    @discardableResult
    public static func add(crx file: URL, in storage: URL) throws -> SharedExtension {
        let limit = 256 << 20
        let data = try PrivateFile.read(file, limit: limit, failure: "无法读取 CRX 扩展文件。",
                                        notAFile: "请选择 .crx 扩展文件。")
        guard data.count <= limit else { throw ProfileError.invalid("CRX 扩展文件不能超过 256 MB。") }
        let (archive, key) = try unpackCRX(data)
        let name = file.deletingPathExtension().lastPathComponent
        return try install(in: storage, fallbackName: name) { staging in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let zip = staging.deletingLastPathComponent().appendingPathComponent(staging.lastPathComponent + ".zip")
            defer { try? FileManager.default.removeItem(at: zip) }
            do {
                try archive.write(to: zip, options: .withoutOverwriting)
            } catch {
                throw ProfileError.invalid("无法解压 CRX 扩展文件。")
            }
            try extract(zip, to: staging)
            if let key { try addKey(key, toManifestIn: staging) }
        }
    }

    /// Deletes an extension from the library. Profiles that still list it no longer start until
    /// it is added again or unticked.
    public static func remove(_ name: String, in storage: URL) throws {
        guard LaunchOptions.isSharedExtensionName(name) else {
            throw ProfileError.invalid("共享扩展名称无效：\(name.prefix(64))")
        }
        let root = root(in: storage)
        var details = stat()
        guard lstat(root.path, &details) == 0 else { return }
        try locked(ProfileExtensions.prepare(root)) {
            let target = root.appendingPathComponent(name, isDirectory: true)
            guard lstat(target.path, &details) == 0 else { return }
            // Out of the library in one step; a partial deletion is finished by the next change.
            let retired = root.appendingPathComponent(".removing-\(UUID().uuidString)", isDirectory: true)
            guard rename(target.path, retired.path) == 0 else {
                throw ProfileError.invalid("无法删除共享扩展「\(name)」。")
            }
            try? FileManager.default.removeItem(at: retired)
        }
    }

    /// The names in `names` that would keep a Profile from starting.
    public static func unavailable(_ names: [String], in storage: URL) -> [String] {
        names.filter { problem(with: $0, in: storage) != nil }
    }

    /// Why the library's `name` cannot be loaded, or nil when it can. Links are followed, as
    /// Chromium does when it loads an unpacked extension.
    static func problem(with name: String, in storage: URL) -> String? {
        guard LaunchOptions.isSharedExtensionName(name) else { return "共享扩展名称无效：\(name.prefix(64))" }
        let directory = directory(named: name, in: storage)
        var details = stat()
        guard stat(directory.path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR else {
            return "共享扩展「\(name)」已不在扩展库中，请重新添加，或在启动选项里取消勾选。"
        }
        guard stat(directory.path + "/manifest.json", &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            return "共享扩展「\(name)」缺少 manifest.json，请在扩展库中删除后重新添加。"
        }
        return nil
    }

    /// A folder name for an extension called `name`: runs of anything `isSharedExtensionName`
    /// rejects become one space, leading punctuation goes, and it is cut to 64 characters. Falls
    /// back to `fallback` (the source file or folder name), then to "Extension". A `__MSG_…__`
    /// name that could not be looked up counts as no name.
    static func folderName(for name: String, fallback: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for candidate in [name, fallback] where !candidate.hasPrefix("__MSG_") {
            var result = ""
            var gap = false
            for scalar in candidate.unicodeScalars {
                guard allowed.contains(scalar) else {
                    gap = true
                    continue
                }
                if result.isEmpty {
                    guard CharacterSet.alphanumerics.contains(scalar) else { continue }
                } else if gap {
                    result.append(" ")
                }
                gap = false
                result.unicodeScalars.append(scalar)
            }
            result = String(result.prefix(64)).trimmingCharacters(in: .whitespaces)
            if LaunchOptions.isSharedExtensionName(result) { return result }
        }
        return "Extension"
    }

    /// The ZIP archive inside a CRX3 file, and the public key the extension's Web Store ID comes from.
    static func unpackCRX(_ data: Data) throws -> (archive: Data, key: Data?) {
        let invalid = ProfileError.invalid("不是有效的 CRX 扩展文件。")
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count == 12, bytes.prefix(4).elementsEqual("Cr24".utf8) else { throw invalid }
        let word = { (offset: Int) in (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) } }
        guard word(4) == 3 else { throw ProfileError.invalid("只支持 CRX3 格式的扩展文件。") }
        let headerLength = word(8)
        guard headerLength <= data.count - 12 else { throw invalid }
        let start = data.startIndex + 12
        let archive = data[(start + headerLength)...]
        guard archive.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw invalid }
        return (Data(archive), publicKey(in: data[start..<(start + headerLength)]))
    }

    /// Fills a hidden staging folder, checks it holds an extension and moves it into the library
    /// under a free name; returns the existing entry instead when the library already holds it.
    private static func install(in storage: URL, fallbackName: String,
                                fill: (URL) throws -> Void) throws -> SharedExtension {
        let root = try ProfileExtensions.prepare(root(in: storage))
        return try locked(root) {
            let staging = root.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try fill(staging)
            let manifest = try Manifest(in: staging)
            if let existing = try duplicate(of: manifest, at: staging, in: root) { return existing }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            let base = folderName(for: manifest.name, fallback: fallbackName)
            for number in 1...1000 {
                let suffix = number == 1 ? "" : " \(number)"
                let name = String(base.prefix(64 - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
                let target = root.appendingPathComponent(name, isDirectory: true)
                // Never replaces an entry, including one that differs only in case.
                if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                    return SharedExtension(name: name, manifestName: manifest.name, version: manifest.version,
                                           directory: target, isValid: true)
                }
                guard errno == EEXIST else { break }
            }
            throw ProfileError.invalid("无法把扩展放入扩展库。")
        }
    }

    /// The entry that already holds the extension in `staging`, which is then not added again: one
    /// with the same `key`, which gives the same extension ID, or without a key the same name,
    /// version and files. The same key in another version is refused: both would load under one
    /// ID, and replacing the files of an entry Profiles may be running is left to the user.
    private static func duplicate(of manifest: Manifest, at staging: URL, in root: URL) throws -> SharedExtension? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var digest: Data?
        for name in names.filter(LaunchOptions.isSharedExtensionName).sorted() {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let existing = try? Manifest(in: directory), existing.key == manifest.key else { continue }
            let entry = SharedExtension(name: name, manifestName: existing.name, version: existing.version,
                                        directory: directory, isValid: true)
            if manifest.key != nil {
                guard existing.version == manifest.version else {
                    throw ProfileError.invalid("扩展库里已有这个扩展「\(name)」（版本 \(existing.version)）。"
                        + "要换成版本 \(manifest.version)，请先在扩展库中删除旧版本，再重新添加。")
                }
                return entry
            }
            guard existing.name == manifest.name, existing.version == manifest.version else { continue }
            digest = digest ?? contentDigest(of: staging)
            if digest != nil, contentDigest(of: directory) == digest { return entry }
        }
        return nil
    }

    /// A digest of every file and link under `directory` with its relative path; nil when
    /// something cannot be read. Finder's .DS_Store files do not count.
    static func contentDigest(of directory: URL) -> Data? {
        let base = directory.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: base) else { return nil }
        var entries: [(path: String, digest: Data)] = []
        while let path = walker.nextObject() as? String {
            guard (path as NSString).lastPathComponent != ".DS_Store" else { continue }
            let full = base + "/" + path
            var details = stat()
            guard lstat(full, &details) == 0 else { return nil }
            switch details.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFLNK:
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) else { return nil }
                entries.append((path, Data(SHA256.hash(data: Data(("link:" + target).utf8)))))
            case S_IFREG:
                guard let data = FileManager.default.contents(atPath: full) else { return nil }
                entries.append((path, Data(SHA256.hash(data: data))))
            default:
                return nil
            }
        }
        var hash = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(entry.path.utf8) + Data([0]) + entry.digest)
        }
        return Data(hash.finalize())
    }

    /// Runs `body` holding the library lock, so changes from other threads or processes wait.
    /// Starts by deleting what an interrupted change left behind.
    private static func locked<Value>(_ root: URL, _ body: () throws -> Value) throws -> Value {
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileError.invalid("扩展库不可用，请检查本机目录权限。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ProfileError.invalid("扩展库不可用，请检查本机目录权限。") }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(".incoming-") || name.hasPrefix(".removing-") {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        return try body()
    }

    private static func extract(_ archive: URL, to directory: URL) throws {
        // ditto keeps entries such as "../x" or "/x" inside the destination.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, directory.path]
        ditto.standardInput = FileHandle.nullDevice
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        do {
            try ditto.run()
        } catch {
            throw ProfileError.invalid("无法解压 CRX 扩展文件。")
        }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ProfileError.invalid("无法解压 CRX 扩展文件。") }
    }

    /// Writes the CRX's public key into manifest.json so the unpacked copy keeps the Web Store ID.
    /// A manifest that has its own key keeps it.
    private static func addKey(_ key: Data, toManifestIn directory: URL) throws {
        let url = directory.appendingPathComponent("manifest.json")
        let data = try Manifest.read(url)
        guard let object = Manifest.parse(data), object["key"] == nil,
              let brace = data.firstIndex(of: UInt8(ascii: "{")) else { return }
        // Inserted as text, so the rest of the file, comments included, stays as it was.
        let encoded = key.base64EncodedString()
        var updated = data
        updated.insert(contentsOf: Data(#""key":"\#(encoded)","#.utf8), at: brace + 1)
        guard Manifest.parse(updated)?["key"] as? String == encoded else { return }
        try PrivateFile.write(updated, to: url, failure: "无法写入扩展的 manifest.json。")
    }

    /// The key proof whose SHA-256 starts with the header's CRX ID (`SignedData.crx_id`).
    private static func publicKey(in header: Data) -> Data? {
        // CrxFileHeader: 2 and 3 are AsymmetricKeyProof (1 = public_key), 10000 is signed_header_data.
        guard let fields = protobufFields(header),
              let signed = fields.first(where: { $0.number == 10000 }),
              let crxID = protobufFields(signed.value)?.first(where: { $0.number == 1 })?.value,
              crxID.count == 16 else { return nil }
        return fields.filter { $0.number == 2 || $0.number == 3 }
            .compactMap { protobufFields($0.value)?.first(where: { $0.number == 1 })?.value }
            .first { Data(SHA256.hash(data: $0).prefix(16)) == crxID }
    }

    /// The length-delimited fields of a protobuf message; nil when it is malformed.
    private static func protobufFields(_ message: Data) -> [(number: UInt64, value: Data)]? {
        let bytes = [UInt8](message)
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) where index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << UInt64(shift)
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        var fields: [(number: UInt64, value: Data)] = []
        while index < bytes.count {
            guard let tag = varint() else { return nil }
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                index += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                fields.append((tag >> 3, Data(bytes[index..<(index + Int(length))])))
                index += Int(length)
            case 5:
                index += 4
            default:
                return nil
            }
            guard index <= bytes.count else { return nil }
        }
        return fields
    }
}

/// The parts of manifest.json the library shows and names folders by.
private struct Manifest {
    var name: String
    var version: String
    /// The public key the extension ID comes from, when the manifest has one.
    var key: String?

    init(in directory: URL) throws {
        let invalid = ProfileError.invalid("manifest.json 无效：须为包含 manifest_version、name 和 version 的 JSON 对象。")
        let data = try Self.read(directory.appendingPathComponent("manifest.json"))
        guard let object = Self.parse(data), object["manifest_version"] is NSNumber,
              let name = object["name"] as? String, !name.isEmpty,
              let version = object["version"] as? String, !version.isEmpty else { throw invalid }
        self.name = Self.localized(name, manifest: object, in: directory)
        self.version = version
        key = (object["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// manifest.json itself, not a link to one elsewhere.
    static func read(_ url: URL) throws -> Data {
        let missing = ProfileError.invalid("所选扩展缺少 manifest.json。")
        var details = stat()
        guard lstat(url.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG else { throw missing }
        let limit = 1 << 20
        let data = try PrivateFile.read(url, limit: limit, failure: "无法读取扩展的 manifest.json。")
        guard data.count <= limit else { throw ProfileError.invalid("扩展的 manifest.json 过大。") }
        return data
    }

    /// Chromium accepts comments in manifest.json; JSON5 is the closest Foundation parses.
    static func parse(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
    }

    /// `__MSG_key__` replaced by the message in `_locales/<default_locale>/messages.json`, whose
    /// keys are case-insensitive; anything else, or a message that cannot be found, as it is.
    private static func localized(_ text: String, manifest: [String: Any], in directory: URL) -> String {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8,
              let locale = manifest["default_locale"] as? String,
              locale.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return text }
        let key = text.dropFirst(6).dropLast(2).lowercased()
        let file = directory.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = try? read(file), let messages = parse(data),
              let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
              let message = entry["message"] as? String, !message.isEmpty else { return text }
        return message
    }
}
