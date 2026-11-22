import Darwin
import Foundation

/// A per-Profile MV3 content script that repairs the engine-148 Canvas text metrics until the
/// engine itself is patched.
///
/// `CanvasRenderingContext2D.measureText` (and the OffscreenCanvas one on the page) multiplies
/// every metric of non-empty text by a seed constant k in ±0.000005 instead of 1 + k, so widths
/// come back as 0.0016 or negative numbers. The constant is computed here and written into the
/// script, which divides it back out in the `TextMetrics` getters; Workers are not affected.
///
/// The script leaves nothing on the page: no globals or symbols, `measureText` stays native and
/// returns real `TextMetrics`, and the getters are accessor-shorthand functions without a
/// prototype. Their source text and stack frames remain visible; only an engine fix removes those.
/// Language and Intl defaults come from `-AppleLanguages` instead (see `FingerprintSettings.arguments()`).
enum IdentityShim {
    static func directory(in storage: URL, for id: UUID) -> URL {
        ProfileExtensions.root(in: storage, for: id).appendingPathComponent("IdentityShim", isDirectory: true)
    }

    /// Engines 148 and 150 both carry the factor bug (upstream issue #96), and the script checks
    /// at runtime, so it is loaded whatever the version: a fixed engine leaves it inactive.
    static func isNeeded(for engineVersion: String) -> Bool {
        true
    }

    static func prepare(for profile: BrowserProfile, in storage: URL) throws {
        try ProfileExtensions.prepareRoot(in: storage, for: profile.id)
        let target = directory(in: storage, for: profile.id)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)

        let files = [
            "manifest.json": Data(manifest.utf8),
            "content.js": Data(script(seed: profile.fingerprint.seed).utf8),
        ]
        for (name, data) in files {
            try PrivateFile.update(data, at: target.appendingPathComponent(name),
                                   failure: "无法写入身份一致性扩展。")
        }
        // Also drops config.js, which earlier versions put on every page as a global.
        for name in try FileManager.default.contentsOfDirectory(atPath: target.path) where files[name] == nil {
            try FileManager.default.removeItem(at: target.appendingPathComponent(name))
        }
    }

    /// The factor engine 148 multiplies Canvas text metrics by:
    /// `(uint32(std::hash<std::string>(seed + "clientrects_noise_x")) / 0xFFFFFFFF - 0.5) * 0.00001`,
    /// where libc++'s 64-bit `std::hash` is its CityHash64 variant.
    /// Seeds outside the valid range give 0, which leaves the script inactive.
    static func measureTextFactor(seed: Int) -> Double {
        guard let hash = cityHash64(Array((String(seed) + "clientrects_noise_x").utf8)) else { return 0 }
        return (Double(UInt32(truncatingIfNeeded: hash)) / 4294967295.0 - 0.5) * 0.00001
    }

    static let manifest = """
    {
      "manifest_version": 3,
      "name": "AnyBrowser Identity Guard",
      "version": "1.1.0",
      "description": "Keeps Canvas text metrics consistent with this Profile.",
      "minimum_chrome_version": "111",
      "host_permissions": ["<all_urls>"],
      "content_scripts": [{
        "matches": ["<all_urls>"],
        "all_frames": true,
        "match_about_blank": true,
        "match_origin_as_fallback": true,
        "run_at": "document_start",
        "world": "MAIN",
        "js": ["content.js"]
      }]
    }

    """

    /// The content script for one seed. Everything it needs is a closure constant, and it
    /// installs itself only while `TextMetrics` still has its native getters, so a second
    /// injection into the same document changes nothing.
    static func script(seed: Int) -> String {
        scriptTemplate.replacingOccurrences(of: "__FACTOR__", with: "\(measureTextFactor(seed: seed))")
    }

    private static let scriptTemplate = #"""
    (() => {
      const factor = __FACTOR__;
      const proto = globalThis.TextMetrics && TextMetrics.prototype;
      if (!proto || !(factor !== 0 && isFinite(factor))) return;
      // Captured before page scripts run, so later changes to these globals cannot reach the getters.
      const apply = Reflect.apply;
      const describe = Object.getOwnPropertyDescriptor;
      const define = Object.defineProperty;
      const fround = Math.fround;
      const abs = Math.abs;
      const source = Function.prototype.toString;
      const cache = new WeakMap();
      const cacheGet = WeakMap.prototype.get;
      const cacheSet = WeakMap.prototype.set;
      const isNative = (fn) => {
        try { return apply(source, fn, []).includes('[native code]'); } catch (e) { return false; }
      };

      let broken = false;
      try {
        const probe = new OffscreenCanvas(1, 1).getContext('2d');
        probe.font = '18pt Arial';
        broken = abs(probe.measureText('Cwm fjordbank glyphs vext quiz').width) < 1;
      } catch (e) {}
      if (!broken) return;

      const natives = {};
      for (const key of ['width', 'actualBoundingBoxLeft', 'actualBoundingBoxRight',
        'fontBoundingBoxAscent', 'fontBoundingBoxDescent', 'actualBoundingBoxAscent',
        'actualBoundingBoxDescent', 'emHeightAscent', 'emHeightDescent', 'hangingBaseline',
        'alphabeticBaseline', 'ideographicBaseline']) {
        const descriptor = describe(proto, key);
        if (descriptor && typeof descriptor.get === 'function' && isNative(descriptor.get)) natives[key] = descriptor;
      }
      const width = natives.width && natives.width.get;
      const ascent = natives.fontBoundingBoxAscent && natives.fontBoundingBoxAscent.get;
      const descent = natives.fontBoundingBoxDescent && natives.fontBoundingBoxDescent.get;
      if (!width || !ascent || !descent) return;

      // The engine leaves empty text alone. Zero-width text is scaled too, and then even its
      // font ascent shrinks to a few thousandths of a pixel.
      const scaled = (metrics) => {
        let value = apply(cacheGet, cache, [metrics]);
        if (value === undefined) {
          value = apply(width, metrics, []) !== 0
            || abs(apply(ascent, metrics, [])) + abs(apply(descent, metrics, [])) < 0.01;
          apply(cacheSet, cache, [metrics, value]);
        }
        return value;
      };
      // Metrics are single-precision values; rounding back to one undoes the multiplication exactly.
      const restore = (value) => {
        const real = value / factor;
        const single = fround(real);
        return single * factor === value ? single : real;
      };
      for (const key of Object.keys(natives)) {
        const descriptor = natives[key];
        const get = descriptor.get;
        const hooked = describe({
          get [key]() {
            const value = apply(get, this, []);
            return typeof value === 'number' && scaled(this) ? restore(value) : value;
          },
        }, key).get;
        define(proto, key, { get: hooked, set: descriptor.set,
          enumerable: descriptor.enumerable, configurable: descriptor.configurable });
      }
    })();
    """#

    // MARK: libc++ std::hash

    /// libc++'s `__murmur2_or_cityhash<size_t, 64>`. Valid seeds make strings of 20–29 bytes, so
    /// only the 17–32 byte branch is implemented.
    private static func cityHash64(_ bytes: [UInt8]) -> UInt64? {
        guard (17...32).contains(bytes.count) else { return nil }
        let k0: UInt64 = 0xc3a5_c85c_97cb_3127
        let k1: UInt64 = 0xb492_b66f_be98_f273
        let k2: UInt64 = 0x9ae1_6a3b_2f90_404f
        let k3: UInt64 = 0xc949_d7c7_509e_6557
        func load(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
        }
        func rotate(_ value: UInt64, _ shift: UInt64) -> UInt64 {
            shift == 0 ? value : (value >> shift) | (value << (64 - shift))
        }
        func hash16(_ u: UInt64, _ v: UInt64) -> UInt64 {
            let mul: UInt64 = 0x9ddf_ea08_eb38_2d69
            var a = (u ^ v) &* mul
            a ^= a >> 47
            var b = (v ^ a) &* mul
            b ^= b >> 47
            return b &* mul
        }
        let length = UInt64(bytes.count)
        let a = load(0) &* k1
        let b = load(8)
        let c = load(bytes.count - 8) &* k2
        let d = load(bytes.count - 16) &* k0
        return hash16(rotate(a &- b, 43) &+ rotate(c, 30) &+ d,
                      a &+ rotate(b ^ k3, 20) &- c &+ length)
    }
}
