@testable import AnyBrowserCore
import Foundation
import Testing

@Suite("Shared extension library duplicates", .serialized)
struct SharedExtensionDedupTests {
    @Test("The same CRX added twice keeps one entry; another version of it is refused")
    func sameCRX() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data((0..<294).map { UInt8($0 % 239) })
        let manifest = #"{"manifest_version":3,"name":"Store Wallet","version":"11.4.2"}"#
        let first = try makeCRX(at: root.appendingPathComponent("wallet.crx"), in: root, manifest: manifest,
                                files: ["background.js": "worker"], key: key)
        let added = try SharedExtensions.add(crx: first, in: storage)
        let copy = root.appendingPathComponent("wallet copy.crx")
        try FileManager.default.copyItem(at: first, to: copy)
        #expect(try SharedExtensions.add(crx: copy, in: storage) == added)
        #expect(SharedExtensions.list(in: storage).map(\.name) == ["Store Wallet"])

        // The same key means the same extension ID, whatever else changed.
        let update = try makeCRX(at: root.appendingPathComponent("wallet-12.crx"), in: root,
                                 manifest: #"{"manifest_version":3,"name":"Store Wallet","version":"12.0"}"#,
                                 files: ["background.js": "new"], key: key)
        try expectFailure(containing: "请先在扩展库中删除旧版本") { try SharedExtensions.add(crx: update, in: storage) }
        #expect(SharedExtensions.list(in: storage).map(\.version) == ["11.4.2"])
        #expect(try String(contentsOf: added.directory.appendingPathComponent("background.js"), encoding: .utf8) == "worker")

        // Another key is another extension, even with the same name.
        let other = try makeCRX(at: root.appendingPathComponent("other.crx"), in: root, manifest: manifest,
                                files: ["background.js": "worker"], key: Data(repeating: 3, count: 294))
        #expect(try SharedExtensions.add(crx: other, in: storage).name == "Store Wallet 2")
        #expect(try hidden(in: SharedExtensions.root(in: storage)) == [".lock"])
    }

    @Test("A folder added again with the same files keeps one entry")
    func sameFolder() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeExtension(at: root.appendingPathComponent("Tool"),
                                       manifest: #"{"manifest_version":3,"name":"Tool","version":"1"}"#,
                                       files: ["a.js": "one", "icons/16.png": "png"])
        let added = try SharedExtensions.add(folder: source, in: storage)
        // Finder's bookkeeping does not make it another extension.
        try Data("finder".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        #expect(try SharedExtensions.add(folder: source, in: storage) == added)

        // Different files, or the same files under another version, are another entry.
        try Data("two".utf8).write(to: source.appendingPathComponent("a.js"))
        #expect(try SharedExtensions.add(folder: source, in: storage).name == "Tool 2")
        try Data("one".utf8).write(to: source.appendingPathComponent("a.js"))
        try Data(#"{"manifest_version":3,"name":"Tool","version":"2"}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        #expect(try SharedExtensions.add(folder: source, in: storage).name == "Tool 3")
        #expect(SharedExtensions.list(in: storage).count == 3)

        // A folder whose manifest has a key is matched by the key, as a CRX is.
        let keyed = try makeExtension(at: root.appendingPathComponent("Keyed"),
                                      manifest: #"{"manifest_version":3,"name":"Keyed","version":"1","key":"QUJD"}"#)
        let keyedEntry = try SharedExtensions.add(folder: keyed, in: storage)
        try Data("extra".utf8).write(to: keyed.appendingPathComponent("extra.js"))
        #expect(try SharedExtensions.add(folder: keyed, in: storage) == keyedEntry)
    }

    @Test("The content digest covers paths, contents and links")
    func digest() throws {
        let root = try scratchDirectory("shared-digest")
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try makeExtension(at: root.appendingPathComponent("one"), manifest: "{}", files: ["a/b.js": "x"])
        let two = try makeExtension(at: root.appendingPathComponent("two"), manifest: "{}", files: ["a/b.js": "x"])
        #expect(SharedExtensions.contentDigest(of: one) != nil)
        #expect(SharedExtensions.contentDigest(of: one) == SharedExtensions.contentDigest(of: two))
        try FileManager.default.moveItem(at: two.appendingPathComponent("a/b.js"), to: two.appendingPathComponent("a/c.js"))
        #expect(SharedExtensions.contentDigest(of: one) != SharedExtensions.contentDigest(of: two))
        try FileManager.default.moveItem(at: two.appendingPathComponent("a/c.js"), to: two.appendingPathComponent("a/b.js"))
        try FileManager.default.createSymbolicLink(atPath: two.appendingPathComponent("link").path, withDestinationPath: "a/b.js")
        #expect(SharedExtensions.contentDigest(of: one) != SharedExtensions.contentDigest(of: two))
    }

    // MARK: - Helpers

    private func scratch() throws -> (root: URL, storage: URL) {
        let root = try scratchDirectory("shared-dedup")
        let storage = root.appendingPathComponent("Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        return (root, storage)
    }
}
