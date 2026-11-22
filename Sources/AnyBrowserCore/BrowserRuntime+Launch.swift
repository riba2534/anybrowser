import Darwin
import Foundation

/// The last 64 KB a browser wrote to stdout and stderr. The pipe is read until it closes, so
/// Chromium never blocks on a full pipe, however long it runs.
final class LaunchLog: @unchecked Sendable {
    static let capacity = 64 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var ended = false

    func read(from handle: FileHandle) {
        // The handler keeps the log alive until every process holding the pipe has exited.
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.ended = true
                self.lock.unlock()
                return
            }
            self.append(data)
        }
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > Self.capacity {
            buffer.removeFirst(buffer.count - Self.capacity)
        }
    }

    /// A line from AnyBrowser itself, such as how the browser exited.
    func note(_ line: String) {
        append(Data("[AnyBrowser] \(line)\n".utf8))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// The last non-empty lines, each cut to 300 characters.
    func tail(lines count: Int) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
            .joined(separator: "\n")
    }

    private var hasEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    /// Waits for the pipe to close, so lines written just before an exit are in the log.
    func waitForEnd(seconds: TimeInterval) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline && !hasEnded {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
            }
        }
    }
}

/// How a browser process ended.
struct ExitStatus: Sendable, CustomStringConvertible {
    let code: Int32
    let signaled: Bool

    /// Only valid once `process` has exited.
    init(_ process: Process) {
        code = process.terminationStatus
        signaled = process.terminationReason == .uncaughtSignal
    }

    private static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP",
        SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGSEGV: "SIGSEGV",
        SIGPIPE: "SIGPIPE", SIGTERM: "SIGTERM",
    ]

    var description: String {
        guard signaled else { return "退出码 \(code)" }
        return Self.signalNames[code].map { "被 \($0) 信号终止" } ?? "被信号 \(code) 终止"
    }
}

/// Warnings collected while the start pages open; nothing is added once the budget has run out.
private final class StartPageReport: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var closed = false
    private var navigating = false

    func warn(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if !closed { items.append(text) }
    }

    /// Everything but the first page's navigation is done.
    func markNavigating() {
        lock.lock()
        navigating = true
        lock.unlock()
    }

    func close() -> (warnings: [String], navigating: Bool) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return (items, navigating)
    }
}

private let placeholderURL = #"^https?://\([^/]*\)/?$"#
private let placeholderTitle = #"^\([^/]*\)$"#

extension BrowserRuntime {
    /// Chromium opens a tab for every positional argument; the `(de-DE)` value of -AppleLanguages
    /// becomes an `http://(de-de)/` tab. These positional arguments are expected placeholders.
    nonisolated static func placeholderCount(_ arguments: [String]) -> Int {
        arguments.filter { !$0.hasPrefix("-") && $0.range(of: placeholderTitle, options: .regularExpression) != nil }.count
    }

    /// A tab for such an argument, or the error page Chromium shows in it, which keeps the
    /// placeholder as its title.
    nonisolated static func isPlaceholder(_ target: [String: Any]) -> Bool {
        guard let url = target["url"] as? String else { return false }
        if url.range(of: placeholderURL, options: .regularExpression) != nil { return true }
        return url.hasPrefix("chrome-error://")
            && (target["title"] as? String)?.range(of: placeholderTitle, options: .regularExpression) != nil
    }

    private nonisolated static func isNewTabPage(_ target: [String: Any]) -> Bool {
        ["chrome://newtab/", "chrome://new-tab-page/", "about:blank"].contains(target["url"] as? String ?? "")
    }

    /// Opens the start pages over DevTools once the browser is ready, so nothing loads before
    /// AnyBrowser has had its turn: the first reuses a placeholder tab or the new tab page, the
    /// rest open behind it. Spare placeholder tabs are closed, or the only one shows the new tab
    /// page when there are no start pages. Best effort within `budget`; problems become warnings.
    nonisolated static func openStartPages(_ urls: [String], endpoint: URL, placeholders: Int,
                                           budget: TimeInterval) async -> [String] {
        let client: DevToolsClient
        do {
            client = try DevToolsClient(endpoint: endpoint, timeout: budget)
        } catch {
            return ["启动网址未能打开：\(error.localizedDescription)"]
        }
        let report = StartPageReport()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await arrangeTabs(client, urls: urls, placeholders: placeholders, report: report)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            let outcome = report.close()
            group.cancelAll()
            // Fails whatever is still waiting for the browser.
            client.close()
            return first || outcome.navigating
        }
        var warnings = report.close().warnings
        if !finished {
            warnings.append("启动网址没有在 \(Int(budget.rounded())) 秒内全部打开。")
        }
        return warnings
    }

    private nonisolated static func arrangeTabs(_ client: DevToolsClient, urls: [String], placeholders expected: Int,
                                                report: StartPageReport) async {
        var pages: [[String: Any]] = []
        do {
            // The first tabs appear a moment after the endpoint does.
            while true {
                let targets = try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
                pages = targets.filter { $0["type"] as? String == "page" }
                if !pages.isEmpty && pages.filter(isPlaceholder).count >= expected { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            report.warn("无法读取浏览器的标签页：\(error.localizedDescription)")
            return
        }
        let placeholders = pages.filter(isPlaceholder)
        let reusable = placeholders.first ?? pages.first(where: isNewTabPage)
        let reusableID = reusable?["targetId"] as? String
        var closing = placeholders.compactMap { $0["targetId"] as? String }.filter { $0 != reusableID }
        var navigation: String?
        var opening = urls
        if let reusable, reusableID != nil {
            if !opening.isEmpty {
                navigation = opening.removeFirst()
            } else if isPlaceholder(reusable) {
                if pages.contains(where: { !isPlaceholder($0) }) {
                    closing.append(reusableID!)
                } else {
                    navigation = "chrome://newtab/"
                }
            }
        }
        // Without a tab to reuse the first page opens in front and the others behind it.
        for (index, url) in opening.enumerated() {
            do {
                _ = try await client.send("Target.createTarget", ["url": url, "background": navigation != nil || index > 0])
            } catch {
                report.warn("未能打开启动网址 \(url)：\(error.localizedDescription)")
            }
        }
        for target in closing {
            do {
                _ = try await client.send("Target.closeTarget", ["targetId": target])
            } catch {
                report.warn("未能关闭多余的标签页：\(error.localizedDescription)")
            }
        }
        guard let navigation, let reusableID else { return }
        do {
            let attached = try await client.send("Target.attachToTarget", ["targetId": reusableID, "flatten": true])
            guard let session = attached["sessionId"] as? String else {
                throw ProfileError.invalid("无法连接标签页。")
            }
            // Page.navigate answers once the site responds. A page still loading when the budget
            // runs out keeps loading, and a site that fails shows its error page as any tab would.
            report.markNavigating()
            _ = try await client.send("Page.navigate", ["url": navigation], sessionId: session)
            _ = try? await client.send("Target.detachFromTarget", ["sessionId": session])
        } catch {
            report.warn("未能打开启动网址 \(navigation)：\(error.localizedDescription)")
        }
    }
}
