import Darwin
import Foundation

/// Full backups of Profiles in one `.anybrowser` file, for moving them to another Mac with their
/// sign-ins: the saved configuration with its secrets, every cookie, and the browser data
/// directory without its caches.
///
/// Chromium encrypts cookies with a key in the login keychain, so a data directory copied to
/// another Mac or user keeps its site storage but loses its cookies. A backup therefore works in
/// two steps: it starts each stopped Profile without windows, reads its cookies in clear over
/// DevTools and stops it again, and only then copies the data directory under the runtime lock.
/// A restore puts the data directory in place and sets the cookies again in a headless launch.
/// Within one Mac, or after Migration Assistant or Time Machine, which bring the keychain along,
/// the data directory alone would do.
///
/// A Profile that is already running is left running: its cookies come from that browser, but its
/// data directory is not copied, because Chromium is writing to its databases. Its entry says so
/// in `warnings`; stopping it first gives a complete backup.
///
/// A Profile saved with a new identity whose old site data has not been deleted yet
/// (`ProfileStore.pendingIdentityReset`) has it deleted first when it is stopped. While its
/// browser still runs with that data, it is backed up without cookies and data directory.
///
/// The file is not encrypted. It holds proxy passwords, Passkey Box accounts and cookies in clear
/// and is written readable by the current user only.
///
/// Callers make sure nothing else starts or stops the Profiles involved while a backup or restore
/// runs (the UI marks them busy). The runtime lock only covers the copying of a data directory.
///
/// The file is a ZIP archive (`ditto -c -k`) of:
///
///     manifest.json                  format, version, creation time, app and engine versions, Profiles
///     Profiles/<uuid>/Cookies.json   the Profile's cookies, as `CookieTransfer` exports them for DevTools
///     Profiles/<uuid>/Data/          its data directory without caches, when `browserData` is set
public enum ProfileBackup {
    public static let format = "anybrowser-backup"
    public static let version = 1
    public static let fileExtension = "anybrowser"
    static let maxManifestBytes = 16 << 20

    /// Directories Chromium rebuilds by itself, left out at any depth of a data directory. With
    /// the data directory in Application Support the HTTP and code caches live in
    /// `BrowserRuntime.cacheDirectory(for:)` instead, which is never copied.
    static let cacheDirectories: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "GraphiteDawnCache",
        "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "component_crx_cache", "extensions_crx_cache",
    ]
    /// Files at the top of a data directory that belong to the browser that last ran there.
    static let runtimeFiles: Set<String> = [".anybrowser-runtime.json", ".anybrowser-runtime.lock", "DevToolsActivePort"]

    /// How far a backup or restore has come, for the UI.
    public struct Progress: Equatable, Sendable {
        /// Profiles done so far, out of `total`.
        public var completed: Int
        public var total: Int
        /// The Profile being worked on (its id in the backup during a restore); nil while the
        /// file itself is read or written.
        public var profile: UUID?
        /// What is happening, e.g. "正在导出「工作号」的 Cookie".
        public var message: String
    }

    // MARK: Backup

    public struct ExportedProfile: Equatable, Sendable {
        public var id: UUID
        /// Empty when the Profile was not found.
        public var name: String
        /// Why the Profile is not in the backup; nil when it is.
        public var skipped: String?
        public var cookies = 0
        /// Whether its data directory is in the backup.
        public var browserData = false
        /// What the backup lacks for this Profile and why, such as the data directory of a running browser.
        public var warnings: [String] = []
    }

    public struct ExportResult: Equatable, Sendable {
        public var file: URL
        /// In the order the ids were given.
        public var profiles: [ExportedProfile]
    }

    /// Writes a backup of the saved Profiles in `ids` to `destination`, replacing any file there.
    /// Each Profile is backed up as completely as it can be, and its entry says what is missing;
    /// it throws only when the file cannot be written or no Profile was found.
    @MainActor
    public static func export(_ ids: [UUID], to destination: URL, store: ProfileStore, runtime: BrowserRuntime,
                              progress: (Progress) -> Void = { _ in }) async throws -> ExportResult {
        var order: [UUID] = []
        for id in ids where !order.contains(id) { order.append(id) }
        guard !order.isEmpty else { throw ProfileError.invalid("请选择要备份的 Profile。") }
        let staging = try makeStaging(near: runtime.storage)
        defer { try? FileManager.default.removeItem(at: staging) }
        var entries: [Entry] = []
        var results: [ExportedProfile] = []
        for (index, id) in order.enumerated() {
            guard let profile = store.profiles.first(where: { $0.id == id }) else {
                results.append(ExportedProfile(id: id, name: "", skipped: "找不到此 Profile，可能已被移除。"))
                continue
            }
            func report(_ message: String) {
                progress(Progress(completed: index, total: order.count, profile: id, message: message))
            }
            let folder = entryFolder(id, in: staging)
            do {
                let result = try await backUp(profile, into: folder, store: store, runtime: runtime, report: report)
                entries.append(Entry(id: id, name: profile.name, cookies: result.cookies,
                                     browserData: result.browserData, profile: profile))
                results.append(result)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                results.append(ExportedProfile(id: id, name: profile.name, skipped: error.localizedDescription))
            }
        }
        guard !entries.isEmpty else {
            let reasons = results.compactMap { result in result.skipped.map { "\(result.name)：\($0)" } }
            throw ProfileError.invalid("没有可备份的 Profile。\(reasons.joined(separator: "；"))")
        }
        progress(Progress(completed: order.count, total: order.count, profile: nil, message: "正在写入备份文件"))
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let manifest = Manifest(format: format, version: version, createdAt: Date(), appVersion: app,
                                engineVersion: BundledVersions.engine, profiles: entries)
        try write(manifest, in: staging)
        try await Task.detached { try pack(staging, to: destination) }.value
        return ExportResult(file: destination, profiles: results)
    }

    /// Fills `folder` with one Profile's cookies and data directory; see the type's notes.
    @MainActor
    private static func backUp(_ profile: BrowserProfile, into folder: URL, store: ProfileStore,
                               runtime: BrowserRuntime, report: (String) -> Void) async throws -> ExportedProfile {
        let id = profile.id
        var result = ExportedProfile(id: id, name: profile.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var cookies = Data("[]\n".utf8)
        // A new identity was saved and the old one's site data is still there. A stopped Profile
        // has it deleted now, as its next launch would; otherwise it stays out of the backup, which
        // would bring it back under the new identity.
        if store.pendingIdentityReset(id) {
            var problem = "浏览器还在用旧身份的网站数据（重启后才清除），没有备份 Cookie 和浏览器资料。"
            var cleared = false
            switch runtime.status(for: id) {
            case .stopped, .failed:
                report("正在清除「\(profile.name)」旧身份的网站数据")
                do {
                    try await runtime.clearSiteData(for: id)
                    cleared = true
                    // A mark that stays only makes the next launch delete the site data once more, and
                    // the data now matches the new fingerprint, so the next launch must not ask again.
                    try? store.setPendingIdentityReset(id, false)
                    store.recordLaunchFingerprint(id, profile.fingerprint)
                } catch {
                    problem = "未能清除旧身份的网站数据，没有备份 Cookie 和浏览器资料：\(error.localizedDescription)"
                }
            case .running, .starting, .stopping:
                break
            }
            guard cleared else {
                result.warnings.append(problem)
                try cookies.write(to: folder.appendingPathComponent("Cookies.json"))
                return result
            }
        }
        var launched = false
        switch runtime.status(for: id) {
        case .stopped, .failed:
            report("正在以无窗口方式启动「\(profile.name)」")
            do {
                // As on a normal launch, so Passkey Box stays signed in to the same account.
                let outcome = try await runtime.start(profile, passkeyBox: profile.passkeyBox ?? store.passkeyBoxAccount,
                                                      overrides: LaunchOverrides(headless: true, urls: []))
                // Not fresh: the browser was running after all, and stays as it is.
                launched = outcome.startedFresh
            } catch {
                result.warnings.append("未能启动浏览器导出 Cookie，在另一台 Mac 上恢复后需要重新登录：\(error.localizedDescription)")
            }
        case .starting, .stopping:
            result.warnings.append("浏览器正在启动或停止，没有导出 Cookie。")
        case .running:
            break
        }
        if case .running = runtime.status(for: id) {
            report("正在导出「\(profile.name)」的 Cookie")
            do {
                guard let endpoint = await runtime.devToolsEndpoint(for: id) else {
                    throw ProfileError.invalid("浏览器调试接口未就绪。")
                }
                // DevTools' own format, which Storage.setCookies takes back unchanged, partition keys included.
                let export = try await CookieTransfer.exportCookies(from: endpoint, format: .devTools)
                cookies = export.data
                result.cookies = export.count
                if export.skipped > 0 { result.warnings.append("有 \(export.skipped) 条 Cookie 无法迁移，没有备份。") }
            } catch {
                result.warnings.append("未能导出 Cookie：\(error.localizedDescription)")
            }
        }
        if launched {
            report("正在停止「\(profile.name)」")
            if let problem = await stopLaunched(id, runtime: runtime) { result.warnings.append(problem) }
        }
        switch runtime.status(for: id) {
        case .stopped, .failed:
            report("正在复制「\(profile.name)」的浏览器资料")
            do {
                result.browserData = try await copyData(of: id, runtime: runtime,
                                                        to: folder.appendingPathComponent("Data", isDirectory: true))
            } catch {
                result.warnings.append("未能备份浏览器资料：\(error.localizedDescription)")
            }
        case .running, .starting, .stopping:
            result.warnings.append(launched ? "浏览器没有退出，没有备份浏览器资料。"
                                            : "浏览器正在运行，没有备份浏览器资料（站点存储、扩展数据、历史记录等），停止后再备份可以包含它们。")
        }
        try cookies.write(to: folder.appendingPathComponent("Cookies.json"))
        return result
    }

    /// Copies the data directory of a stopped Profile; false when it has none yet.
    @MainActor
    private static func copyData(of id: UUID, runtime: BrowserRuntime, to target: URL) async throws -> Bool {
        let source = runtime.dataDirectory(for: id)
        var details = stat()
        guard lstat(source.path, &details) == 0 else { return false }
        // Holding the runtime lock keeps a launch of this Profile out until the copy is done.
        let lock = try runtime.lockDirectory(source)
        defer { close(lock) }
        guard !runtime.profileInUse(source) else {
            throw ProfileError.invalid("资料目录正被另一个浏览器进程使用。")
        }
        try await Task.detached { try copyBrowserData(from: source, to: target) }.value
        return true
    }

    /// Copies a data directory to the new directory `target`, without `cacheDirectories` and
    /// `runtimeFiles`. Symbolic links (SingletonLock and its siblings) and other special files are
    /// left out too. Files are cloned where the volume allows, which is quick and takes no space.
    nonisolated static func copyBrowserData(from source: URL, to target: URL) throws {
        let manager = FileManager.default
        func copy(_ from: URL, to: URL, top: Bool) throws {
            try manager.createDirectory(at: to, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in try manager.contentsOfDirectory(atPath: from.path) {
                if top && runtimeFiles.contains(name) { continue }
                let item = from.appendingPathComponent(name)
                var details = stat()
                guard lstat(item.path, &details) == 0 else { continue }
                switch details.st_mode & S_IFMT {
                case S_IFDIR where !cacheDirectories.contains(name):
                    try copy(item, to: to.appendingPathComponent(name, isDirectory: true), top: false)
                case S_IFREG:
                    try manager.copyItem(at: item, to: to.appendingPathComponent(name))
                default:
                    continue
                }
            }
        }
        do {
            try copy(source, to: target, top: true)
        } catch {
            throw ProfileError.invalid("无法复制浏览器资料：\(error.localizedDescription)")
        }
    }

    /// Stops a browser that a backup or restore started; `stop` closes a headless one over DevTools,
    /// which writes cookies set a moment ago to disk. One that does not exit in time is ended, which
    /// may lose those cookies; the warning says so.
    @MainActor
    private static func stopLaunched(_ id: UUID, runtime: BrowserRuntime) async -> String? {
        // A second try covers a browser caught half way through exiting.
        for attempt in 0..<2 {
            do {
                try await runtime.stop(id)
                return nil
            } catch where attempt == 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch {}
        }
        do {
            try await runtime.stop(id, force: true)
        } catch {
            return "浏览器未能退出：\(error.localizedDescription)"
        }
        return "浏览器没有及时退出，已强制结束，最近写入的数据可能没有保存。"
    }

    // MARK: Restore

    /// How restored Profiles get their ids.
    public enum IdentityPolicy: Equatable, Sendable {
        /// Keeps each Profile's id; one whose id is already taken here is skipped with the reason.
        case keepOriginal
        /// Keeps each Profile's id unless it is taken here, in which case that Profile gets a new one.
        case keepOriginalOrRenew
        /// Gives every restored Profile a new id, as importing a Profile file does.
        case renew
    }

    public struct RestoredProfile: Equatable, Sendable {
        /// The id in the backup.
        public var originalID: UUID
        public var name: String
        /// The Profile as saved, with the id, port and seed it got; nil when skipped.
        public var profile: BrowserProfile?
        /// Why the Profile was not restored; nil when it was.
        public var skipped: String?
        /// Whether its data directory was restored.
        public var browserData = false
        public var importedCookies = 0
        /// Cookies the file held that could not be read or that the browser refused.
        public var skippedCookies = 0
        /// Problems that did not stop the restore, such as cookies that could not be imported.
        public var warnings: [String] = []
    }

    public struct RestoreResult: Equatable, Sendable {
        public var createdAt: Date
        public var appVersion: String?
        public var engineVersion: String
        /// In the order of the backup.
        public var profiles: [RestoredProfile]
        public var warnings: [String]
    }

    /// Restores the Profiles of a backup, or those of `selection` (ids in the backup). Each one
    /// gets its id by `identity`, and a new debug port or seed when its own is taken, as on
    /// import. Its data directory goes in place, its configuration is saved, and its cookies are
    /// set in a headless launch, stopped right after. Throws when the file is not a usable backup;
    /// problems with single Profiles are reported in their entries.
    @MainActor
    public static func restore(from file: URL, store: ProfileStore, runtime: BrowserRuntime,
                               identity: IdentityPolicy = .renew, selection: Set<UUID>? = nil,
                               progress: (Progress) -> Void = { _ in }) async throws -> RestoreResult {
        progress(Progress(completed: 0, total: 0, profile: nil, message: "正在读取备份文件"))
        let staging = try makeStaging(near: runtime.storage)
        defer { try? FileManager.default.removeItem(at: staging) }
        let manifest = try await Task.detached {
            try unpack(file, into: staging)
            return try readManifest(in: staging, name: file.lastPathComponent)
        }.value
        var warnings: [String] = []
        if let major = manifest.engineVersion.split(separator: ".").first.flatMap({ Int($0) }),
           major > BundledVersions.engineMajor {
            warnings.append("备份来自更新的内核 \(manifest.engineVersion)，当前内核可能读不了其中的浏览器资料。")
        }
        let entries = manifest.profiles.filter { selection?.contains($0.id) ?? true }
        let plans = plan(entries, identity: identity, takenIDs: takenIDs(for: entries, store: store, runtime: runtime),
                         takenPorts: store.takenPorts, takenSeeds: store.takenSeeds,
                         takenCombinations: store.takenScreenFontCombinations)
        var results: [RestoredProfile] = []
        for (index, planned) in plans.enumerated() {
            func report(_ message: String) {
                progress(Progress(completed: index, total: plans.count, profile: planned.entry.id, message: message))
            }
            var result = RestoredProfile(originalID: planned.entry.id, name: planned.entry.name)
            guard var profile = planned.profile else {
                result.skipped = planned.skipped
                results.append(result)
                continue
            }
            if let warning = planned.warning { result.warnings.append(warning) }
            report("正在恢复「\(profile.name)」")
            let folder = entryFolder(planned.entry.id, in: staging)
            let target = runtime.dataDirectory(for: profile.id)
            do {
                if planned.entry.browserData {
                    let data = folder.appendingPathComponent("Data", isDirectory: true)
                    try await Task.detached { try place(data, at: target) }.value
                    result.browserData = true
                }
                let avoided = try avoidingTaken(profile, store: store, planned: plans)
                profile = avoided.profile
                profile = try store.saveAll([profile])[0]
                if let warning = avoided.warning { result.warnings.append(warning) }
            } catch {
                // The directory was only just put there, for a Profile that is not saved.
                if result.browserData { try? FileManager.default.removeItem(at: target) }
                result.browserData = false
                result.skipped = error.localizedDescription
                results.append(result)
                continue
            }
            result.profile = profile
            if planned.entry.cookies > 0 {
                report("正在以无窗口方式启动「\(profile.name)」")
                do {
                    let cookies = try CookieTransfer.readFile(folder.appendingPathComponent("Cookies.json"))
                    let imported = try await importCookies(cookies, into: profile, store: store, runtime: runtime,
                                                           report: report)
                    result.importedCookies = imported.result.imported
                    result.skippedCookies = imported.result.skipped
                    // Over Chromium's per-site or overall limit.
                    if imported.result.evicted > 0 || imported.result.displaced > 0 {
                        result.warnings.append(imported.result.summary)
                    }
                    if let warning = imported.warning { result.warnings.append(warning) }
                } catch {
                    result.warnings.append("Cookie 未能导入，在另一台 Mac 上恢复时可能需要重新登录：\(error.localizedDescription)")
                }
            }
            results.append(result)
        }
        progress(Progress(completed: plans.count, total: plans.count, profile: nil, message: "恢复完成"))
        return RestoreResult(createdAt: manifest.createdAt, appVersion: manifest.appVersion,
                             engineVersion: manifest.engineVersion, profiles: results, warnings: warnings)
    }

    /// `profile` with a new port, seed, display or font for one taken here since `plan` ran: the
    /// automation API may create a Profile while a restore runs. What `planned` gives the other
    /// entries is avoided.
    @MainActor
    private static func avoidingTaken(_ profile: BrowserProfile, store: ProfileStore,
                                      planned: [Planned]) throws -> (profile: BrowserProfile, warning: String?) {
        var profile = profile
        let others = planned.compactMap(\.profile).filter { $0.id != profile.id }
        if store.takenPorts.contains(profile.port) {
            profile.port = try ProfileLibrary.freePort(excluding: store.takenPorts.union(others.map(\.port)))
        }
        if store.takenSeeds.contains(profile.fingerprint.seed) {
            profile.fingerprint.seed = FingerprintSettings.newSeed(excluding: store.takenSeeds.union(others.map(\.fingerprint.seed)),
                                                                   sameHardwareAs: profile.fingerprint.seed)
        }
        let warning = ProfileLibrary.renewDevice(
            in: &profile,
            excluding: store.takenScreenFontCombinations.union(others.compactMap { ScreenFontCombination($0.fingerprint) }),
            seeds: store.takenSeeds.union(others.map(\.fingerprint.seed)))
        return (profile, warning)
    }

    /// Sets the cookies in the restored Profile's browser, started without windows. This is what
    /// brings sign-ins back on another Mac, where the copied cookie database cannot be decrypted.
    @MainActor
    private static func importCookies(_ data: Data, into profile: BrowserProfile, store: ProfileStore, runtime: BrowserRuntime,
                                      report: (String) -> Void) async throws -> (result: CookieTransfer.ImportResult, warning: String?) {
        let outcome = try await runtime.start(profile, passkeyBox: profile.passkeyBox ?? store.passkeyBoxAccount,
                                              overrides: LaunchOverrides(headless: true, urls: []))
        let imported: CookieTransfer.ImportResult
        do {
            report("正在导入「\(profile.name)」的 Cookie")
            guard let endpoint = await runtime.devToolsEndpoint(for: profile.id) else {
                throw ProfileError.invalid("浏览器调试接口未就绪。")
            }
            imported = try await CookieTransfer.importCookies(data, into: endpoint)
        } catch {
            if outcome.startedFresh { _ = await stopLaunched(profile.id, runtime: runtime) }
            throw error
        }
        // Chromium writes the cookies to disk as it quits.
        let warning = outcome.startedFresh ? await stopLaunched(profile.id, runtime: runtime) : nil
        return (imported, warning)
    }

    /// Ids a restored Profile cannot keep, with the reason: those of saved, trashed and unreadable
    /// Profiles, and those of `entries` that already have a data directory without a Profile.
    @MainActor
    private static func takenIDs(for entries: [Entry], store: ProfileStore, runtime: BrowserRuntime) -> [UUID: String] {
        var taken: [UUID: String] = [:]
        for entry in entries {
            var details = stat()
            if lstat(runtime.dataDirectory(for: entry.id).path, &details) == 0 {
                taken[entry.id] = "本机已有这个 ID 的浏览器资料目录。"
            }
        }
        for row in store.unreadableRows {
            if let id = UUID(uuidString: row.id) { taken[id] = "本机已有一份 ID 相同、无法读取的 Profile。" }
        }
        for entry in store.trashed { taken[entry.id] = "回收站中已有 ID 相同的 Profile「\(entry.profile.name)」。" }
        for profile in store.profiles { taken[profile.id] = "本机已有 ID 相同的 Profile「\(profile.name)」。" }
        return taken
    }

    struct Planned: Equatable {
        var entry: Entry
        /// What to save, with its id, port, seed, display and font; nil when the entry is skipped.
        var profile: BrowserProfile?
        var skipped: String?
        /// A combination that had to repeat because every display and font is in use.
        var warning: String? = nil
    }

    /// Decides each entry's id, port, seed, display and font. Ids follow `identity`; ports, seeds
    /// and combinations taken here or by an earlier entry are replaced as
    /// `ProfileLibrary.importProfiles` does. Entries this version cannot read or that fail
    /// validation are skipped with the reason.
    nonisolated static func plan(_ entries: [Entry], identity: IdentityPolicy, takenIDs: [UUID: String],
                                 takenPorts: Set<Int>, takenSeeds: Set<Int>,
                                 takenCombinations: Set<ScreenFontCombination> = []) -> [Planned] {
        var ids = takenIDs
        var ports = takenPorts
        var seeds = takenSeeds
        var combinations = takenCombinations
        return entries.map { entry in
            func skip(_ reason: String) -> Planned { Planned(entry: entry, profile: nil, skipped: reason) }
            guard let stored = entry.profile else { return skip(entry.unreadable ?? "无法读取此 Profile 的配置。") }
            var profile: BrowserProfile
            do {
                profile = try stored.validated()
            } catch {
                return skip(error.localizedDescription)
            }
            var renewed = false
            switch identity {
            case .keepOriginal:
                if let reason = ids[entry.id] { return skip(reason) }
                profile.id = entry.id
            case .keepOriginalOrRenew:
                if ids[entry.id] == nil {
                    profile.id = entry.id
                } else {
                    profile.id = UUID()
                    renewed = true
                }
            case .renew:
                profile.id = UUID()
                renewed = true
            }
            if ports.contains(profile.port) {
                guard let port = try? ProfileLibrary.freePort(excluding: ports) else { return skip("没有可分配的调试端口。") }
                profile.port = port
            }
            if seeds.contains(profile.fingerprint.seed) {
                profile.fingerprint.seed = FingerprintSettings.newSeed(excluding: seeds, sameHardwareAs: profile.fingerprint.seed)
                renewed = true
            }
            var warning: String?
            if renewed {
                // Keeping the original id also keeps its device; a new id is a new device.
                warning = ProfileLibrary.renewDevice(in: &profile, excluding: combinations, seeds: seeds)
            } else if let combination = ScreenFontCombination(profile.fingerprint), combinations.contains(combination),
                      !ProfileLibrary.freshCombination(in: &profile.fingerprint, excluding: combinations) {
                // The id and seed stay, but two entries of the same backup may share a display.
                warning = ProfileLibrary.exhaustedCombinations
            }
            combinations.formUnion(ScreenFontCombination.set(ScreenFontCombination(profile.fingerprint)))
            ids[profile.id] = "备份中有两个 ID 相同的 Profile。"
            ports.insert(profile.port)
            seeds.insert(profile.fingerprint.seed)
            return Planned(entry: entry, profile: profile, skipped: nil, warning: warning)
        }
    }

    /// Moves a restored data directory to `target`, never over one that exists.
    nonisolated static func place(_ source: URL, at target: URL) throws {
        let failure = ProfileError.invalid("无法写入浏览器资料。")
        try PrivateDirectory.ensure(target.deletingLastPathComponent())
        var details = stat()
        guard lstat(target.path, &details) != 0 else { throw ProfileError.invalid("本机已有这个 ID 的浏览器资料目录。") }
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EXDEV else { throw failure }
            do {
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw failure
            }
        }
        // The runtime only uses a data directory nobody else can write.
        guard chmod(target.path, 0o700) == 0 else { throw failure }
    }

    // MARK: The file

    struct Manifest: Codable, Equatable {
        var format: String
        var version: Int
        var createdAt: Date
        var appVersion: String?
        var engineVersion: String
        var profiles: [Entry]
    }

    struct Entry: Codable, Equatable {
        var id: UUID
        var name: String
        var cookies: Int
        var browserData: Bool
        /// Nil when this version cannot read the configuration; `unreadable` says why.
        var profile: BrowserProfile?
        var unreadable: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, cookies, browserData, profile
        }

        init(id: UUID, name: String, cookies: Int, browserData: Bool, profile: BrowserProfile) {
            self.id = id
            self.name = name
            self.cookies = cookies
            self.browserData = browserData
            self.profile = profile
        }

        /// A configuration written by a newer version skips that Profile, not the whole backup.
        init(from decoder: Decoder) throws {
            let data = try decoder.container(keyedBy: CodingKeys.self)
            id = try data.decode(UUID.self, forKey: .id)
            name = try data.decode(String.self, forKey: .name)
            cookies = try data.decode(Int.self, forKey: .cookies)
            browserData = try data.decode(Bool.self, forKey: .browserData)
            do {
                profile = try data.decode(BrowserProfile.self, forKey: .profile)
            } catch {
                unreadable = ProfileStore.readFailure(error, below: decoder.codingPath.count + 1)
            }
        }

        func encode(to encoder: Encoder) throws {
            var data = encoder.container(keyedBy: CodingKeys.self)
            try data.encode(id, forKey: .id)
            try data.encode(name, forKey: .name)
            try data.encode(cookies, forKey: .cookies)
            try data.encode(browserData, forKey: .browserData)
            try data.encodeIfPresent(profile, forKey: .profile)
        }
    }

    private struct Header: Decodable {
        var format: String
        var version: Int?
    }

    static func entryFolder(_ id: UUID, in root: URL) -> URL {
        root.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    nonisolated static func write(_ manifest: Manifest, in root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    /// The manifest of an unpacked backup, once every file it lists is there.
    nonisolated static func readManifest(in root: URL, name: String) throws -> Manifest {
        let notBackup = ProfileError.invalid("「\(name)」不是 AnyBrowser 备份文件。")
        guard let data = try? PrivateFile.read(root.appendingPathComponent("manifest.json"), limit: maxManifestBytes,
                                               failure: ""),
              data.count <= maxManifestBytes,
              let header = try? JSONDecoder().decode(Header.self, from: data), header.format == format else {
            throw notBackup
        }
        guard let fileVersion = header.version, (1...version).contains(fileVersion) else {
            let newer = (header.version ?? 0) > version ? "，请升级 AnyBrowser 后再恢复" : ""
            throw ProfileError.invalid("不支持此版本的备份文件（版本 \(header.version.map(String.init) ?? "未知")）\(newer)。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            throw ProfileError.invalid("「\(name)」的备份清单已损坏。")
        }
        var seen: Set<UUID> = []
        for entry in manifest.profiles {
            guard seen.insert(entry.id).inserted else {
                throw ProfileError.invalid("「\(name)」的备份清单已损坏：重复列出了「\(entry.name)」。")
            }
            let folder = entryFolder(entry.id, in: root)
            var details = stat()
            guard lstat(folder.appendingPathComponent("Cookies.json").path, &details) == 0,
                  details.st_mode & S_IFMT == S_IFREG else {
                throw ProfileError.invalid("「\(name)」不完整：缺少「\(entry.name)」的 Cookie。")
            }
            if entry.browserData {
                guard lstat(folder.appendingPathComponent("Data").path, &details) == 0,
                      details.st_mode & S_IFMT == S_IFDIR else {
                    throw ProfileError.invalid("「\(name)」不完整：缺少「\(entry.name)」的浏览器资料。")
                }
            }
        }
        return manifest
    }

    /// A new private directory on the volume of `storage`, so restored data directories move into
    /// place with a rename and copies of them are clones.
    nonisolated static func makeStaging(near storage: URL) throws -> URL {
        let manager = FileManager.default
        let staging = (try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: storage, create: true))
            ?? manager.temporaryDirectory.appendingPathComponent("anybrowser-backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        } catch {
            throw ProfileError.invalid("无法创建临时目录。")
        }
        return staging
    }

    /// Archives `staging` into a 0600 file staged next to `destination` and renamed over it.
    nonisolated static func pack(_ staging: URL, to destination: URL) throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        defer { unlink(partial.path) }
        // Resource forks and extended attributes mean nothing to Chromium and would add AppleDouble entries.
        guard ditto(["-c", "-k", "--norsrc", staging.path, partial.path]), chmod(partial.path, 0o600) == 0,
              rename(partial.path, destination.path) == 0 else {
            throw ProfileError.invalid("无法写入备份文件「\(destination.lastPathComponent)」，请换一个位置。")
        }
    }

    nonisolated static func unpack(_ file: URL, into staging: URL) throws {
        var details = stat()
        guard stat(file.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            throw ProfileError.invalid("请选择一个 AnyBrowser 备份文件。")
        }
        // ditto keeps entries such as "../x" or "/x" inside the destination.
        guard ditto(["-x", "-k", file.path, staging.path]) else {
            throw ProfileError.invalid("「\(file.lastPathComponent)」不是有效的 AnyBrowser 备份文件，或已损坏。")
        }
    }
}

/// Runs /usr/bin/ditto without input or output; whether it succeeded.
func ditto(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
