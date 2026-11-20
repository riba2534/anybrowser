import Darwin
import Foundation

struct ProcessStamp: Codable, Equatable {
    let seconds: UInt64
    let microseconds: UInt64

    static func read(_ pid: Int32) -> ProcessStamp? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard pid > 1,
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        return ProcessStamp(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

enum ProcessInspection {
    struct Image {
        let executablePath: String
        let arguments: [String]
    }

    static func canonicalURL(_ url: URL, isDirectory: Bool = false) -> URL? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: isDirectory)
    }

    static func executable(_ pid: Int32) -> URL? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let size = UInt32(path.count)
        guard proc_pidpath(pid, &path, size) > 0 else { return nil }
        return canonicalURL(URL(fileURLWithPath: String(cString: path)))
    }

    static func arguments(_ pid: Int32) -> [String]? { image(pid)?.arguments }

    static func image(_ pid: Int32) -> Image? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > 4, size <= bytes.count else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        // The initial executable path precedes argv in the process argument area.
        guard (1..<16_384).contains(count),
              let firstEnd = bytes[4..<size].firstIndex(of: 0), firstEnd > 4,
              let executablePath = String(bytes: bytes[4..<firstEnd], encoding: .utf8) else { return nil }
        var cursor = firstEnd + 1
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var resultArguments: [String] = []
        for _ in 0..<count {
            guard let end = bytes[cursor..<size].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            resultArguments.append(argument)
            cursor = end + 1
        }
        return Image(executablePath: executablePath, arguments: resultArguments)
    }

    static func hasFlag(_ flag: String, value: String, arguments: [String]) -> Bool {
        let prefix = flag + "="
        let matches = arguments.dropFirst().prefix { $0 != "--" }.filter {
            $0 == flag || $0.hasPrefix(prefix)
        }
        return matches.count == 1 && matches.first == prefix + value
    }

    // Query the identified browser's own listening sockets, not a global process-name match.
    static func hasLoopbackDebugListener(pid: Int32, port: Int) -> Bool {
        let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard needed > 0, needed <= 1_048_576 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: needed / stride + 32)
        let got = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard got > 0 else { return false }
        var hasIPv4Loopback = false
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        for descriptor in descriptors.prefix(Int(got) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var metadata = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &metadata, socketSize) == socketSize,
                  metadata.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = metadata.psi.soi_proto.pri_tcp
            let ip = tcp.tcpsi_ini
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ip.insi_lport))) == port else { continue }
            switch metadata.psi.soi_family {
            case AF_INET:
                guard ip.insi_laddr.ina_46.i46a_addr4.s_addr == UInt32(INADDR_LOOPBACK).bigEndian else { return false }
                hasIPv4Loopback = true
            case AF_INET6:
                let address = ip.insi_laddr.ina_6
                guard withUnsafeBytes(of: address, { bytes in
                    withUnsafeBytes(of: in6addr_loopback) { bytes.elementsEqual($0) }
                }) else { return false }
            default:
                return false
            }
        }
        return hasIPv4Loopback
    }

    static func portAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let v4 = socket(AF_INET, SOCK_STREAM, 0)
        guard v4 >= 0 else { return false }
        defer { close(v4) }
        var reuse: Int32 = 1
        guard setsockopt(v4, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }
        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        ipv4.sin_port = UInt16(port).bigEndian
        ipv4.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        guard withUnsafePointer(to: &ipv4, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(v4, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else { return false }

        let v6 = socket(AF_INET6, SOCK_STREAM, 0)
        if v6 < 0 { return errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT }
        defer { close(v6) }
        guard setsockopt(v6, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }
        var ipv6 = sockaddr_in6()
        ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        ipv6.sin6_family = sa_family_t(AF_INET6)
        ipv6.sin6_port = UInt16(port).bigEndian
        ipv6.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &ipv6) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(v6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return result == 0 || errno == EADDRNOTAVAIL
    }
}
