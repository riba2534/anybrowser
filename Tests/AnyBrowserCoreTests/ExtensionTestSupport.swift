@testable import AnyBrowserCore
import CryptoKit
import Foundation
import Testing

// Unpacked extensions and CRX files for the shared extension library suites.

func makeExtension(at directory: URL, manifest: String?, files: [String: String] = [:]) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var files = files
    if let manifest { files["manifest.json"] = manifest }
    for (path, contents) in files {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    return directory
}

/// A CRX3 file: magic, version, header length, a CrxFileHeader with one RSA proof per key and
/// the CRX ID, then a ZIP of the extension.
func makeCRX(at file: URL, in root: URL, manifest: String?, files: [String: String] = [:],
             keys: [Data], crxID: Data?) throws -> URL {
    let source = try makeExtension(at: root.appendingPathComponent("crx-\(UUID().uuidString)"), manifest: manifest, files: files)
    let zip = root.appendingPathComponent("crx-\(UUID().uuidString).zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", source.path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
    try #require(ditto.terminationStatus == 0)

    var header = Data()
    for key in keys {
        header += field(2, field(1, key) + field(2, Data(repeating: 1, count: 256)))
    }
    header += varint(5 << 3) + varint(300) // An unknown varint field is skipped.
    if let crxID { header += field(10000, field(1, crxID)) }
    try (Data("Cr24".utf8) + le32(3) + le32(UInt32(header.count)) + header + Data(contentsOf: zip)).write(to: file)
    return file
}

/// A CRX3 file whose header proves `key` and names its CRX ID.
func makeCRX(at file: URL, in root: URL, manifest: String?, files: [String: String] = [:], key: Data) throws -> URL {
    try makeCRX(at: file, in: root, manifest: manifest, files: files, keys: [key], crxID: crxID(key))
}

func crxID(_ key: Data) -> Data { Data(SHA256.hash(data: key).prefix(16)) }

/// The names starting with a dot in `directory`.
func hidden(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
}

func expectFailure(containing text: String, _ body: () throws -> Void) throws {
    do {
        try body()
        Issue.record("Expected a failure containing \(text)")
    } catch let ProfileError.invalid(message) {
        #expect(message.contains(text), "\(message)")
    }
}

private func field(_ number: UInt64, _ value: Data) -> Data {
    varint(number << 3 | 2) + varint(UInt64(value.count)) + value
}

private func varint(_ value: UInt64) -> Data {
    var value = value
    var bytes = Data()
    repeat {
        bytes.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
        value >>= 7
    } while value != 0
    return bytes
}

func le32(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
}
