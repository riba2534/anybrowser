import Darwin
import Foundation

/// Files only the current user can read, written without following links and swapped in atomically.
enum PrivateFile {
    /// Replaces `url` with a new 0600 file holding `data`. The file is staged in `staging`, by default
    /// next to `url`; it must be on the same volume. Any failure throws `failure`.
    static func write(_ data: Data, to url: URL, stagingIn staging: URL? = nil, failure: String) throws {
        let temporary = (staging ?? url.deletingLastPathComponent())
            .appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileError.invalid(failure) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            // The umask can narrow the mode passed to open.
            guard fchmod(fd, 0o600) == 0 else { throw ProfileError.invalid(failure) }
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
            guard rename(temporary.path, url.path) == 0 else { throw ProfileError.invalid(failure) }
        } catch {
            unlink(temporary.path)
            throw ProfileError.invalid(failure)
        }
    }

    /// Like `write`, but leaves `url` alone when it already is this user's 0600 file with `data`.
    static func update(_ data: Data, at url: URL, stagingIn staging: URL? = nil, failure: String) throws {
        var details = stat()
        if lstat(url.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
           details.st_mode & 0o777 == 0o600, (try? Data(contentsOf: url)) == data {
            return
        }
        try write(data, to: url, stagingIn: staging, failure: failure)
    }

    /// Up to `limit + 1` bytes of the file, so callers can tell a larger one apart. Only regular files
    /// are read, and opening never blocks on a pipe. Throws `notAFile` (or `failure`) for anything else.
    static func read(_ url: URL, limit: Int, failure: String, notAFile: String? = nil) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileError.invalid(failure) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            throw ProfileError.invalid(notAFile ?? failure)
        }
        guard let data = try? file.read(upToCount: limit + 1) ?? Data() else { throw ProfileError.invalid(failure) }
        return data
    }
}

/// Directories only the current user can write.
enum PrivateDirectory {
    static let unavailable = "资料目录不可用，请检查本机目录权限。"

    /// The metadata of `url` when it is a real directory of this user that nobody else can write,
    /// at its canonical path; throws `failure` otherwise.
    @discardableResult
    static func check(_ url: URL, failure: String = unavailable) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o022 == 0,
              ProcessInspection.canonicalURL(url, isDirectory: true)?.path == url.path else {
            throw ProfileError.invalid(failure)
        }
        return metadata
    }

    /// Creates `url` and any missing parents as 0700, then checks it.
    @discardableResult
    static func ensure(_ url: URL, failure: String = unavailable) throws -> stat {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try check(url, failure: failure)
    }
}
