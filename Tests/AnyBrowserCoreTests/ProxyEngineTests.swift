@testable import AnyBrowserCore
import CryptoKit
import Foundation
import Testing

// Debug port 9303 belongs to this suite.
@Suite(.serialized)
struct ProxyEngineTests {
    @Test(
        "Chromium signs in to an HTTP proxy with the Profile's credentials",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the proxy sign-in test.")
    )
    @MainActor
    func signsInToTheProxy() async throws {
        let engine = try testEngine()
        let directory = try scratchDirectory("proxy-engine")
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = "AnyBrowser signed-in proxy"
        let stub = try await ProxyStub.start(credentials: "user:pass") { _ in
            .init(status: 200, body: "<!doctype html><meta charset=utf-8><title>\(title)</title>")
        }
        defer { stub.stop() }
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = 9303
        profile.proxy = "http://user:pass@127.0.0.1:\(stub.port)"
        try store.save(profile)

        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        try await runtime.start(profile)
        do {
            guard case let .running(pid, _, true) = runtime.status(for: profile.id) else {
                throw VerificationFailure.message("CDP 未就绪：\(runtime.status(for: profile.id))")
            }
            let arguments = try #require(ProcessInspection.arguments(pid))
            let helper = ProxyAuthExtension.directory(in: store.directory, for: profile.id)
            #expect(arguments.contains("--proxy-server=http://127.0.0.1:\(stub.port)"))
            #expect(arguments.contains { $0.hasPrefix("--load-extension=") && $0.contains(helper.path) })
            #expect(!arguments.contains { $0.contains("user:pass") })
            let worker = "chrome-extension://\(Self.extensionID(helper))/background.js"
            try await DevToolsPage.waitForTargets(port: profile.port) { $0.contains { $0["url"] as? String == worker } }

            let signedIn = "Basic " + Data("user:pass".utf8).base64EncodedString()
            let first = try #require(URL(string: "http://anybrowser-proxy.invalid/"))
            let page = try await DevToolsPage.open(port: profile.port, url: first)
            defer { page.socket.cancel(with: .normalClosure, reason: nil) }
            #expect(try await page.evaluate("document.title") as? String == title)
            let firstAttempts = stub.requests.filter { $0.target == first.absoluteString }.map(\.authorization)
            #expect(firstAttempts == [nil, signedIn])

            // HTTPS sites go through CONNECT; a challenge there is answered the same way. The stub
            // cannot finish TLS, so only the tunnel requests are checked.
            let tunnel = "anybrowser-proxy-tls.invalid:443"
            stub.challengeNext(tunnel)
            _ = try await page.evaluate("fetch('https://anybrowser-proxy-tls.invalid/', {mode: 'no-cors'}).catch(() => null); true")
            try await waitFor { stub.requests.filter { $0.target == tunnel }.count >= 2 }
            let tunnelAttempts = stub.requests.filter { $0.target == tunnel }
            #expect(tunnelAttempts.allSatisfy { $0.method == "CONNECT" })
            #expect(tunnelAttempts.last?.authorization == signedIn)

            // Chromium reuses the credentials preemptively; once the worker has gone idle, a fresh
            // challenge has to wake it.
            try await DevToolsPage.waitForTargets(port: profile.port, timeout: 90) { !$0.contains { $0["url"] as? String == worker } }
            let second = try #require(URL(string: "http://anybrowser-proxy-second.invalid/"))
            stub.challengeNext(second.absoluteString)
            try await page.navigate(to: second)
            #expect(try await page.evaluate("document.title") as? String == title)
            let secondAttempts = stub.requests.filter { $0.target == second.absoluteString }.map(\.authorization)
            #expect(secondAttempts == [signedIn, signedIn])

            // Rejected credentials are answered once; the second challenge is cancelled, so Chromium
            // shows its HTTP 407 error page instead of retrying forever or waiting on a sign-in dialog.
            stub.expect("user:other")
            let rejected = "http://anybrowser-proxy-rejected.invalid/"
            _ = try await page.evaluate("location.href = '\(rejected)'; true")
            var refusal = ""
            for _ in 0..<50 where !refusal.contains("407") {
                try await Task.sleep(nanoseconds: 100_000_000)
                refusal = try await page.evaluate("location.protocol === 'chrome-error:' ? document.body.innerText : ''")
                    as? String ?? ""
            }
            #expect(refusal.contains("HTTP ERROR 407"))
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let rejectedAttempts = stub.requests.filter { $0.target == rejected }.map(\.authorization)
            #expect(rejectedAttempts.count == 2 && rejectedAttempts.last == signedIn, "\(rejectedAttempts)")

            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
        #expect(runtime.status(for: profile.id) == .stopped)
    }

    /// Chromium's id for an unpacked extension: the SHA-256 of its path, first 16 bytes as a-p digits.
    private static func extensionID(_ directory: URL) -> String {
        SHA256.hash(data: Data(directory.path.utf8)).prefix(16).map { byte in
            String([Character(UnicodeScalar(97 + byte >> 4)), Character(UnicodeScalar(97 + byte & 15))])
        }.joined()
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw VerificationFailure.message("Timed out waiting for the proxy stub") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
