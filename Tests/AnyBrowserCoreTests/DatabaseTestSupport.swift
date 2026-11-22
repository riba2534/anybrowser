@testable import AnyBrowserCore
import Foundation
import SQLite3

// Raw access to a data directory's database, as another version or process would see the file.

func databaseURL(_ directory: URL) -> URL { directory.appendingPathComponent(ProfileStore.databaseFileName) }

func withDatabase<Value>(_ directory: URL, _ body: (OpaquePointer) throws -> Value) throws -> Value {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL(directory).path, &database) == SQLITE_OK, let database else {
        throw ProfileError.invalid("open")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

/// Runs one statement with `values` bound in order (String, Int or Data).
func execute(_ sql: String, in directory: URL, binding values: [Any] = []) throws {
    try withDatabase(directory) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ProfileError.invalid("prepare") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient) }
            default: throw ProfileError.invalid("bind")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileError.invalid("step") }
    }
}

func scalar(_ sql: String, in directory: URL) throws -> Int64 {
    try withDatabase(directory) { database in
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, sql, -1, &read, nil) == SQLITE_OK, sqlite3_step(read) == SQLITE_ROW else {
            throw ProfileError.invalid("scalar")
        }
        return sqlite3_column_int64(read, 0)
    }
}

func rowCount(_ table: String, in directory: URL) throws -> Int {
    Int(try scalar("SELECT COUNT(*) FROM \(table)", in: directory))
}
