@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

/// The data directory lock waits briefly for a lock that is being released, such as one a
/// process being spawned still holds a copy of, but not for one that stays held.
@MainActor
struct DirectoryLockTests {
    private func holdLock(in directory: URL) throws -> Int32 {
        let fd = open(directory.appendingPathComponent(".anybrowser-runtime.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    private func runtime(_ label: String) throws -> (BrowserRuntime, URL) {
        let storage = try scratchDirectory(label)
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/true"), passkeyBoxDirectory: storage)
        let directory = storage.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return (BrowserRuntime(engine: engine, storage: storage), directory)
    }

    @Test("A lock released a moment later is taken")
    func waitsForARelease() throws {
        let (runtime, directory) = try runtime("lock-release")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let held = try holdLock(in: directory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { close(held) }
        let fd = try runtime.lockDirectory(directory)
        close(fd)
    }

    @Test("A lock that stays held is refused after a short wait")
    func refusesAHeldLock() throws {
        let (runtime, directory) = try runtime("lock-held")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let held = try holdLock(in: directory)
        defer { close(held) }
        let started = Date()
        #expect(throws: BrowserRuntimeError.self) { _ = try runtime.lockDirectory(directory) }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.2 && elapsed < 2)
    }
}
