import Foundation

/// The hardware the bundled engine derives from the seed on its own: the WebGL GPU (`seed %` the
/// platform's GPU count), `navigator.deviceMemory` (`[8, 16, 32][seed % 3]`) and, without an explicit
/// CPU count, `hardwareConcurrency` (`((seed % 13) + 4) * 2`). AnyBrowser chooses CPU counts and seeds
/// so that the three together describe a machine that exists.
///
/// The orders come from the engine's internal arrays (Fingerprint Chromium 148, patches 005, 011
/// and 021), so every engine upgrade has to be checked again; IsolationProbeTests reads them back.
public struct EngineHardwareTable: Equatable, Sendable {
    public struct GPU: Equatable, Sendable {
        /// `UNMASKED_VENDOR_WEBGL`.
        public let vendor: String
        /// `UNMASKED_RENDERER_WEBGL`.
        public let renderer: String
        /// A short name for hints, e.g. "Apple M4".
        public let model: String
        /// Logical CPU counts of machines that ship with this GPU.
        public let cpuCounts: [Int]
        /// `navigator.deviceMemory` values such machines report.
        public let deviceMemory: [Int]
    }

    public let engineMajor: Int
    public let macOS: [GPU]
    public let windows: [GPU]
    /// `navigator.deviceMemory`, indexed by `seed % count`.
    public let deviceMemoryValues: [Int]

    /// The table for an engine version, or nil when AnyBrowser has not checked that engine.
    public static func forEngine(_ version: String) -> EngineHardwareTable? {
        let major = version.split(separator: ".").first.flatMap { Int($0) }
        return all.first { $0.engineMajor == major }
    }

    /// The table for the engine `scripts/build-app.sh` bundles.
    public static var bundled: EngineHardwareTable {
        forEngine(BundledVersions.engine) ?? engine148
    }

    /// The GPU WebGL reports: Linux and disabled GPU spoofing show the Mac's own GPU, which is
    /// not in the table. Without a platform the engine uses its Windows set.
    public func gpu(for platform: BrowserPlatform?, seed: Int) -> GPU? {
        let set: [GPU]
        switch platform {
        case .macOS: set = macOS
        case .windows, nil: set = windows
        case .linux: return nil
        }
        return set.isEmpty ? nil : set[seed % set.count]
    }

    public func deviceMemory(seed: Int) -> Int {
        deviceMemoryValues[seed % deviceMemoryValues.count]
    }

    /// `hardwareConcurrency` when no CPU count is passed to the engine.
    public func defaultCPUCount(seed: Int) -> Int {
        ((seed % 13) + 4) * 2
    }

    /// Whether the seed's GPU and memory, with `cpuCount` (nil: the engine's own value), exist as
    /// one machine. Platforms whose GPU is not spoofed are not judged.
    public func exists(platform: BrowserPlatform?, seed: Int, cpuCount: Int?) -> Bool {
        guard let platform, let gpu = gpu(for: platform, seed: seed) else { return true }
        return gpu.cpuCounts.contains(cpuCount ?? defaultCPUCount(seed: seed))
            && gpu.deviceMemory.contains(deviceMemory(seed: seed))
    }

    /// Seeds that agree modulo this period get the same GPU on every platform, the same memory and
    /// the same default CPU count, so a Profile can change seed without changing machine.
    var hardwarePeriod: Int {
        [macOS.count, windows.count, deviceMemoryValues.count, 13].filter { $0 > 0 }.reduce(1) { lcm($0, $1) }
    }

    private func lcm(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return a / x * b
    }

    /// Whether a macOS identity with this seed can get a real machine at all: its GPU and memory
    /// are fixed by the seed, only the CPU count can still be chosen.
    func macOSSeedExists(_ seed: Int) -> Bool {
        guard let gpu = gpu(for: .macOS, seed: seed) else { return true }
        return gpu.deviceMemory.contains(deviceMemory(seed: seed))
    }

    // MARK: Fingerprint Chromium 148

    private static func intel(_ name: String, _ id: String, _ cpus: [Int]) -> GPU {
        GPU(vendor: "Google Inc. (Intel)",
            renderer: "ANGLE (Intel, Intel(R) \(name) (0x0000\(id)) Direct3D11 vs_5_0 ps_5_0, D3D11)",
            model: "Intel \(name.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: ""))",
            cpuCounts: cpus, deviceMemory: [8, 16, 32])
    }

    private static func nvidia(_ name: String, _ id: String, _ cpus: [Int]) -> GPU {
        GPU(vendor: "Google Inc. (NVIDIA)",
            renderer: "ANGLE (NVIDIA, NVIDIA \(name) (0x0000\(id)) Direct3D11 vs_5_0 ps_5_0, D3D11)",
            model: "NVIDIA \(name)", cpuCounts: cpus, deviceMemory: [8, 16, 32])
    }

    private static func apple(_ chip: String, cpus: [Int], memory: [Int]) -> GPU {
        GPU(vendor: "Google Inc. (Apple)",
            renderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple \(chip), Unspecified Version)",
            model: "Apple \(chip)", cpuCounts: cpus, deviceMemory: memory)
    }

    /// CPU counts follow the laptops these GPUs ship in: Tiger Lake U (4 cores, 8 threads),
    /// Alder/Raptor Lake P and H (12–14 cores, 16–20 threads), Comet/Whiskey Lake U (2–4 cores),
    /// Meteor Lake H (18–22 threads), Ryzen 5000 U/H (12–16 threads). M4 ships with 8 or 10 CPU
    /// cores and at least 16 GB; the base M2 has 8 cores and at most 24 GB.
    static let engine148 = EngineHardwareTable(
        engineMajor: 148,
        macOS: [
            apple("M4", cpus: [8, 10], memory: [16, 32]),
            apple("M2", cpus: [8], memory: [8, 16]),
        ],
        windows: [
            intel("Iris(R) Xe Graphics", "9A49", [8]),
            intel("Iris(R) Xe Graphics", "46A6", [16, 20]),
            nvidia("GeForce RTX 3060 Laptop GPU", "2560", [12, 16, 20]),
            intel("Iris(R) Xe Graphics", "A7A0", [16, 20]),
            intel("Iris(R) Xe Graphics", "A7A0", [16, 20]),
            GPU(vendor: "Google Inc. (AMD)",
                renderer: "ANGLE (AMD, AMD Radeon(TM) Graphics (0x00001638) Direct3D11 vs_5_0 ps_5_0, D3D11)",
                model: "AMD Radeon Graphics", cpuCounts: [12, 16], deviceMemory: [8, 16, 32]),
            intel("UHD Graphics", "9B41", [4, 8]),
            intel("Iris(R) Xe Graphics", "46A6", [16, 20]),
            intel("Arc(TM) Graphics", "7D55", [18, 22]),
            intel("Iris(R) Xe Graphics", "9A49", [8]),
            intel("UHD Graphics 620", "3EA0", [4, 8]),
            nvidia("GeForce RTX 4060 Laptop GPU", "28E0", [16, 20]),
            intel("UHD Graphics", "A78B", [8, 12, 16]),
        ],
        deviceMemoryValues: [8, 16, 32])

    static let all = [engine148]
}
