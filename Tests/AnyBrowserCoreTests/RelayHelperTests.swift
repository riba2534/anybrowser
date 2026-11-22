@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

/// The AnyBrowserRelay executable, built next to the test bundle.
private let helperPath: String? = {
    let bundle = Bundle(for: HelperMarker.self).bundleURL
    let candidate = bundle.deletingLastPathComponent().appendingPathComponent("AnyBrowserRelay").path
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
}()

private final class HelperMarker {}

@Suite("Relay helper process", .serialized,
       .enabled(if: helperPath != nil, "Build the AnyBrowserRelay product (swift build) to run the helper tests."))
struct RelayHelperTests {
    private struct Fixture {
        let directory: URL
        let origins: EchoStub
        let upstream: UpstreamHTTPStub

        static func make() throws -> Fixture {
            let directory = try scratchDirectory("relay-helper")
            let origins = try EchoStub()
            let echo = origins.port
            let upstream = try UpstreamHTTPStub(credentials: "helper:s3cret") { $0.hasPrefix("echo.test") ? echo : nil }
            return Fixture(directory: directory, origins: origins, upstream: upstream)
        }

        var config: Data { Data(#"{"upstream": "http://helper:s3cret@127.0.0.1:\#(upstream.port)", "connectTimeout": 5}"#.utf8) }
        var portFile: URL { directory.appendingPathComponent("relay.port") }

        func writeConfig(mode: Int = 0o600, name: String = "relay.json") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try config.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }

        func stop() {
            upstream.stop()
            origins.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func launch(_ arguments: [String], input: Pipe? = nil) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(helperPath))
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()
        return (process, errors)
    }

    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    private func port(in file: URL, timeout: TimeInterval = 5) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n"), let port = Int(text.dropLast()) {
                return port
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw VerificationFailure.message("The helper wrote no port file")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else { throw VerificationFailure.message("The helper is still running") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test("The helper relays with credentials from a private file and exits with the process it watches")
    func followsTheWatchedProcess() async throws {
        let fixture = try Fixture.make()
        defer { fixture.stop() }
        let browser = try sleeper()
        defer { browser.terminate() }
        let config = try fixture.writeConfig()
        let (helper, _) = try launch(["--config", config.path, "--port-file", fixture.portFile.path,
                                      "--watch-pid", String(browser.processIdentifier)])
        defer { if helper.isRunning { helper.terminate() } }

        let port = try await port(in: fixture.portFile)
        #expect(try permissions(fixture.portFile) == 0o600)
        let tunnel = try #require(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("helper".utf8)))
        #expect(tunnel.text == "echo:helper")
        #expect(fixture.upstream.requests.last?.authorization == fixture.upstream.signIn)
        // The credentials stay out of the arguments other processes can read.
        let arguments = try #require(ProcessInspection.arguments(helper.processIdentifier))
        #expect(!arguments.joined(separator: " ").contains("s3cret"))
        #expect(FileManager.default.fileExists(atPath: fixture.portFile.path))

        browser.terminate()
        try await waitForExit(helper)
        #expect(helper.terminationReason == .exit && helper.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.portFile.path))
    }

    @Test("Standard input carries the configuration and hands the watch over to another process")
    func readsStandardInput() async throws {
        let fixture = try Fixture.make()
        defer { fixture.stop() }
        let app = try sleeper()
        defer { app.terminate() }
        let browser = try sleeper()
        defer { browser.terminate() }
        let input = Pipe()
        let (helper, _) = try launch(["--config", "-", "--port-file", fixture.portFile.path,
                                      "--watch-pid", String(app.processIdentifier)], input: input)
        defer { if helper.isRunning { helper.terminate() } }
        input.fileHandleForWriting.write(fixture.config + Data("\n".utf8))
        let port = try await port(in: fixture.portFile)
        #expect(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("stdin".utf8))?.text == "echo:stdin")

        input.fileHandleForWriting.write(Data("watch \(browser.processIdentifier)\n".utf8))
        try input.fileHandleForWriting.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        // The app may quit once the browser runs; only the browser's exit ends the relay.
        app.terminate()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(helper.isRunning)
        #expect(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("still".utf8))?.text == "echo:still")
        browser.terminate()
        try await waitForExit(helper)
        #expect(helper.terminationStatus == 0)
    }

    @Test("SIGTERM stops the helper cleanly, and a process already gone ends it at once")
    func stopsOnSignals() async throws {
        let fixture = try Fixture.make()
        defer { fixture.stop() }
        let config = try fixture.writeConfig()
        let (helper, _) = try launch(["--config", config.path, "--port-file", fixture.portFile.path])
        defer { if helper.isRunning { helper.terminate() } }
        _ = try await port(in: fixture.portFile)
        helper.terminate()
        try await waitForExit(helper)
        #expect(helper.terminationReason == .exit && helper.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.portFile.path))

        let gone = try sleeper()
        gone.terminate()
        gone.waitUntilExit()
        let (orphan, _) = try launch(["--config", config.path, "--port-file", fixture.portFile.path,
                                      "--watch-pid", String(gone.processIdentifier)])
        defer { if orphan.isRunning { orphan.terminate() } }
        try await waitForExit(orphan)
        #expect(orphan.terminationStatus == 0)
    }

    @Test("Unsafe or unreadable configurations are refused")
    func refusesBadConfigurations() async throws {
        let fixture = try Fixture.make()
        defer { fixture.stop() }
        let portFile = fixture.portFile.path
        let shared = try fixture.writeConfig(mode: 0o644, name: "shared.json")
        let link = fixture.directory.appendingPathComponent("link.json")
        let target = try fixture.writeConfig()
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let garbage = fixture.directory.appendingPathComponent("garbage.json")
        try Data(#"{"upstream": "ftp://127.0.0.1:21"}"#.utf8).write(to: garbage)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: garbage.path)
        let cases: [([String], Int32, String)] = [
            (["--config", shared.path, "--port-file", portFile], 78, "0600"),
            (["--config", link.path, "--port-file", portFile], 66, "无法读取配置文件"),
            (["--config", garbage.path, "--port-file", portFile], 78, "代理"),
            (["--config", target.path], 64, "用法"),
            (["--config", target.path, "--port-file", portFile, "--watch-pid", "x"], 64, "用法"),
            (["--config", target.path, "--port-file", portFile, "--upstream", "http://a:b@c:1"], 64, "用法"),
        ]
        for (arguments, status, message) in cases {
            let (process, errors) = try launch(arguments)
            do {
                try await waitForExit(process)
            } catch {
                process.terminate()
                throw error
            }
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == status, "\(arguments): \(output)")
            #expect(output.contains(message), "\(arguments): \(output)")
        }
        #expect(!FileManager.default.fileExists(atPath: portFile))
    }
}
