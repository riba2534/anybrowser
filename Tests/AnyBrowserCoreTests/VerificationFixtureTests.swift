import AnyBrowserCore
import Foundation
import Testing

// 9307 和 9308 仅用于本地校验用例。
struct VerificationFixtureTests {
    @Test("本地合成指纹：变化触发重新校验，重试幂等，Profile 互相隔离", .enabled(if: testAppPath != nil))
    @MainActor
    func syntheticFingerprintChecks() async throws {
        let engine = try testEngine()
        let root = try scratchDirectory("verification-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await LoopbackPage.start(title: "本地校验夹具", content: Self.fixtureHTML)
        defer { fixture.listener.cancel() }

        let runtime = BrowserRuntime(engine: engine, storage: root)
        let profiles = [9307, 9308].map { port in
            BrowserProfile(name: "本地校验 \(port)", port: port, fingerprint: FingerprintSettings(seed: port), proxy: "")
        }
        let (first, second) = (profiles[0], profiles[1])
        do {
            try await runtime.start(first)
            let page = try await DevToolsPage.open(port: first.port, url: fixture.url)
            defer { page.socket.cancel(with: .normalClosure, reason: nil) }

            #expect(try await check(page, 1, .a) == .init(decision: .baseline, replayed: false))
            #expect(try await check(page, 2, .a) == .init(decision: .unchanged, replayed: false))
            #expect(try await check(page, 3, .b) == .init(decision: .reverificationRequired, replayed: false))
            #expect(try await check(page, 3, .b) == .init(decision: .reverificationRequired, replayed: true))
            #expect(try await check(page, 3, .a) == .init(decision: .attemptConflict, replayed: false))

            // 另一个 Profile 在同一站点复用会话和请求 ID，也必须建立自己的基线。
            try await runtime.start(second)
            let otherPage = try await DevToolsPage.open(port: second.port, url: fixture.url)
            defer { otherPage.socket.cancel(with: .normalClosure, reason: nil) }
            #expect(try await check(otherPage, 1, .b) == .init(decision: .baseline, replayed: false))
            #expect(try await check(otherPage, 2, .b) == .init(decision: .unchanged, replayed: false))

            // 导航到同源的新文档后仍返回原有校验结果，变化检查不会自动替换基线。
            let reopenedURL = try #require(URL(string: "?retry=1", relativeTo: fixture.url)?.absoluteURL)
            try await page.navigate(to: reopenedURL)
            #expect(try await check(page, 3, .b) == .init(decision: .reverificationRequired, replayed: true))
            #expect(try await check(page, 4, .a) == .init(decision: .unchanged, replayed: false))
            for profile in profiles { try await runtime.stop(profile.id) }
        } catch {
            for profile in profiles { try? await runtime.stop(profile.id) }
            throw error
        }
    }

    private enum SyntheticFingerprint: String, Encodable {
        case a = "fixture-A"
        case b = "fixture-B"
    }

    private struct Request: Encodable {
        let sessionID = "local-verification-session"
        let attemptID: Int
        let fingerprint: SyntheticFingerprint
    }

    private struct Result: Decodable, Equatable {
        enum Decision: String, Decodable {
            case baseline, unchanged, reverificationRequired, attemptConflict
        }

        let decision: Decision
        let replayed: Bool
    }

    private func check(_ page: DevToolsPage, _ attemptID: Int, _ fingerprint: SyntheticFingerprint) async throws -> Result {
        let request = try JSONEncoder().encode(Request(attemptID: attemptID, fingerprint: fingerprint))
        let json = String(decoding: request, as: UTF8.self)
        let raw = try #require(try await page.evaluate("JSON.stringify(checkSyntheticFingerprint(\(json)))") as? String)
        return try JSONDecoder().decode(Result.self, from: Data(raw.utf8))
    }

    // 只读取显式提供的合成值。使用本地站点存储模拟会话；不读取浏览器指纹，也不发网络请求。
    private static let fixtureHTML = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <script>
        function checkSyntheticFingerprint({sessionID, attemptID, fingerprint}) {
            const key = 'synthetic-verification:' + sessionID;
            const state = JSON.parse(localStorage.getItem(key)) ?? {baseline: null, attempts: []};
            const previous = state.attempts.find(attempt => attempt.id === attemptID);
            if (previous) {
                if (previous.fingerprint !== fingerprint) return {decision: 'attemptConflict', replayed: false};
                return {decision: previous.decision, replayed: true};
            }
            let decision;
            if (state.baseline === null) {
                state.baseline = fingerprint;
                decision = 'baseline';
            } else {
                decision = state.baseline === fingerprint ? 'unchanged' : 'reverificationRequired';
            }
            state.attempts.push({id: attemptID, fingerprint, decision});
            localStorage.setItem(key, JSON.stringify(state));
            return {decision, replayed: false};
        }
        </script>
        """
}
