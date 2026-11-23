import Darwin
import Foundation

/// A per-Profile MV3 content script with two jobs: repairing the engine-148 Canvas text metrics,
/// and serving the screen/device values the engine does not spoof.
///
/// `CanvasRenderingContext2D.measureText` (and the OffscreenCanvas one on the page) multiplies
/// every metric of non-empty text by a seed constant k in ±0.000005 instead of 1 + k, so widths
/// come back as 0.0016 or negative numbers. The constant is computed here and written into the
/// script, which divides it back out in the `TextMetrics` getters; Workers are not affected.
///
/// `--fingerprint-screen-*` and `--fingerprint-device-scale-factor` are dead strings in engine 148:
/// `screen.*`, `avail*`, `colorDepth` and `devicePixelRatio` all show the host, identical for every
/// Profile. The script therefore rewrites the existing `Screen.prototype` getters and the
/// `devicePixelRatio` property, `navigator.deviceMemory`/`maxTouchPoints` on `Navigator.prototype`,
/// `window.matchMedia` for the affected queries, and `ontouchstart` only for touch identities. It
/// adds no own enumerable keys to `navigator` or `document` (Stripe reads `Object.keys` of both,
/// which are `[]` and `["location"]`).
///
/// Otherwise the script leaves nothing on the page: no globals or symbols, `measureText` stays
/// native and returns real `TextMetrics`, and the getters are accessor-shorthand functions without
/// a prototype. Their source text and stack frames remain visible; only an engine fix removes those.
/// Language and Intl defaults come from `-AppleLanguages` instead (see `FingerprintSettings.arguments()`).
enum IdentityShim {
    static func directory(in storage: URL, for id: UUID) -> URL {
        ProfileExtensions.root(in: storage, for: id).appendingPathComponent("IdentityShim", isDirectory: true)
    }

    /// Engines 148 and 150 both carry the factor bug (upstream issue #96), and the script checks
    /// at runtime, so it is loaded whatever the version: a fixed engine leaves the Canvas part
    /// inactive. The guard part still has to reach pages until the engine spoofs the values itself.
    static func isNeeded(for engineVersion: String) -> Bool {
        true
    }

    /// The script is always loaded: the Canvas fix covers every engine build, and a Profile without
    /// guard values simply leaves that block inactive.
    static func isNeeded(for engineVersion: String, profile: BrowserProfile) -> Bool {
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
            "content.js": Data(script(seed: profile.fingerprint.seed,
                                      values: .from(profile.fingerprint)).utf8),
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

    /// The screen/device values one Profile wants a page to see. Screen values are only taken with
    /// a platform, because without one the engine identity is the host Mac; the other values stand
    /// alone. `touch` is tri-state: unset leaves the host alone, false pins a non-touch desktop.
    struct ScreenGuard: Equatable {
        struct Screen: Equatable {
            let width: Int
            let height: Int
            let availWidth: Int
            let availHeight: Int
            let colorDepth: Int?
        }

        let screen: Screen?
        /// `devicePixelRatio`; also answers the resolution media queries.
        let scale: Double?
        let deviceMemory: Int?
        let touch: Bool?

        static func from(_ fingerprint: FingerprintSettings) -> ScreenGuard? {
            var screen: Screen?
            if fingerprint.platform != nil, let width = fingerprint.screenWidth {
                let height = fingerprint.screenHeight ?? width
                screen = Screen(width: width, height: height,
                                availWidth: fingerprint.availWidth ?? width,
                                availHeight: fingerprint.availHeight ?? height,
                                colorDepth: fingerprint.colorDepth)
            }
            let scale = fingerprint.platform == nil ? nil : fingerprint.deviceScaleFactor
            let values = ScreenGuard(screen: screen, scale: scale,
                                     deviceMemory: fingerprint.deviceMemory,
                                     touch: fingerprint.touch)
            return values == ScreenGuard(screen: nil, scale: nil, deviceMemory: nil, touch: nil)
                ? nil : values
        }

        /// The object literal the script reads; absent fields stay keys the script skips.
        var literal: String {
            var entries: [String] = []
            if let screen {
                var values = ["\"width\":\(screen.width)", "\"height\":\(screen.height)",
                              "\"availWidth\":\(screen.availWidth)", "\"availHeight\":\(screen.availHeight)"]
                if let colorDepth = screen.colorDepth {
                    values.append("\"colorDepth\":\(colorDepth)")
                }
                entries.append("\"screen\":{\(values.joined(separator: ","))}")
            }
            if let scale {
                entries.append("\"dpr\":\(String(format: "%g", scale))")
            }
            if let deviceMemory {
                entries.append("\"deviceMemory\":\(deviceMemory)")
            }
            if let touch {
                entries.append("\"touch\":\(touch)")
            }
            return "{\(entries.joined(separator: ","))}"
        }
    }

    static let manifest = """
    {
      "manifest_version": 3,
      "name": "AnyBrowser Identity Guard",
      "version": "1.2.0",
      "description": "Keeps Canvas text metrics and screen values consistent with this Profile.",
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

    /// The content script for one seed. Everything it needs is a closure constant, and every part
    /// installs itself only while its targets still have their native functions, so a second
    /// injection into the same document changes nothing. Without a guard the second block returns
    /// immediately and the script only carries the Canvas fix.
    static func script(seed: Int) -> String {
        script(seed: seed, values: nil)
    }

    static func script(seed: Int, values: ScreenGuard?) -> String {
        scriptTemplate
            .replacingOccurrences(of: "__FACTOR__", with: "\(measureTextFactor(seed: seed))")
            .replacingOccurrences(of: "__GUARD__", with: values?.literal ?? "null")
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

    // The engine ignores its screen switches, so pages get the Profile's values here instead.
    (() => {
      const fake = __GUARD__;
      if (!fake) return;
      const apply = Reflect.apply;
      const describe = Object.getOwnPropertyDescriptor;
      const define = Object.defineProperty;
      const source = Function.prototype.toString;
      const isNative = (fn) => {
        try { return apply(source, fn, []).includes('[native code]'); } catch (e) { return true; }
      };
      // Only a target that still carries its native function is ours to replace; a getter of ours
      // (or one a page installed first) leaves the second injection with nothing to do.
      const unpatched = (object, key, accessor) => {
        const descriptor = describe(object, key);
        if (!descriptor) return null;
        const value = accessor ? descriptor.get : descriptor.value;
        return typeof value === 'function' && isNative(value) ? descriptor : null;
      };

      const screenPrototype = globalThis.Screen && Screen.prototype;
      if (fake.screen && screenPrototype) {
        for (const key of ['width', 'height', 'availWidth', 'availHeight', 'colorDepth', 'pixelDepth']) {
          const value = fake.screen[key === 'pixelDepth' ? 'colorDepth' : key];
          if (value === undefined) continue;
          const descriptor = unpatched(screenPrototype, key, true);
          if (!descriptor) continue;
          define(screenPrototype, key, {
            get: describe({
              get [key]() {
                if (!(this instanceof Screen)) throw new TypeError('Illegal invocation');
                return value;
              },
            }, key).get,
            enumerable: descriptor.enumerable, configurable: descriptor.configurable,
          });
        }
      }

      if (fake.dpr !== undefined) {
        const descriptor = unpatched(globalThis, 'devicePixelRatio', true);
        if (descriptor) {
          const value = fake.dpr;
          define(globalThis, 'devicePixelRatio', {
            get: describe({ get devicePixelRatio() { return value; } }, 'devicePixelRatio').get,
            set: descriptor.set,
            enumerable: descriptor.enumerable, configurable: descriptor.configurable,
          });
        }
      }

      const navigatorPrototype = globalThis.Navigator && Navigator.prototype;
      if (navigatorPrototype && fake.deviceMemory !== undefined) {
        const memory = fake.deviceMemory;
        const descriptor = unpatched(navigatorPrototype, 'deviceMemory', true);
        if (descriptor) {
          define(navigatorPrototype, 'deviceMemory', {
            // Like the native getter, which is secure-context only.
            get: describe({
              get deviceMemory() { return globalThis.isSecureContext ? memory : undefined; },
            }, 'deviceMemory').get,
            enumerable: descriptor.enumerable, configurable: descriptor.configurable,
          });
        }
      }
      if (navigatorPrototype && fake.touch !== undefined) {
        const points = fake.touch ? 5 : 0;
        const descriptor = unpatched(navigatorPrototype, 'maxTouchPoints', true);
        if (descriptor) {
          define(navigatorPrototype, 'maxTouchPoints', {
            get: describe({ get maxTouchPoints() { return points; } }, 'maxTouchPoints').get,
            enumerable: descriptor.enumerable, configurable: descriptor.configurable,
          });
        }
      }
      // Desktop Chromium carries no own ontouchstart at all: a touch identity adds one, a non-touch
      // one drops what a touch-enabled host left behind.
      if (fake.touch === true && !describe(globalThis, 'ontouchstart')) {
        const handler = describe({
          get ontouchstart() { return null; }, set ontouchstart(value) {},
        }, 'ontouchstart');
        define(globalThis, 'ontouchstart', {
          get: handler.get, set: handler.set,
          enumerable: true, configurable: true,
        });
      } else if (fake.touch === false) {
        const descriptor = describe(globalThis, 'ontouchstart');
        if (descriptor && descriptor.configurable) delete globalThis.ontouchstart;
      }

      const nativeMatchMedia = globalThis.matchMedia;
      const matchMediaDescriptor = unpatched(globalThis, 'matchMedia', false);
      if (nativeMatchMedia && matchMediaDescriptor && (fake.screen || fake.dpr !== undefined)) {
        const size = fake.screen;
        const dpr = fake.dpr;
        const feature = /^\(\s*(min-|max-)?(width|height|resolution)\s*:\s*(\d*\.?\d+)\s*(px|dppx|dpi)?\s*\)$/i;
        // `undefined` means the clause is outside the guard and the native answer decides.
        const evaluate = (query) => {
          let matches = true;
          for (const clause of query.split(/\s+and\s+/i)) {
            const found = feature.exec(clause.trim());
            if (!found) return undefined;
            const range = (found[1] || '').toLowerCase();
            const name = found[2].toLowerCase();
            const unit = (found[4] || '').toLowerCase();
            const value = parseFloat(found[3]);
            let actual;
            if (name === 'resolution') {
              if (unit === 'px' || typeof dpr !== 'number') return undefined;
              actual = unit === 'dpi' ? dpr * 96 : dpr;
            } else {
              if (!size || (unit && unit !== 'px')) return undefined;
              actual = size[name];
            }
            const ok = range === 'min-' ? actual >= value : range === 'max-' ? actual <= value
              : actual === value;
            if (!ok) matches = false;
          }
          return matches;
        };
        define(globalThis, 'matchMedia', {
          value: function matchMedia(query) {
            const matches = evaluate(String(query));
            if (matches === undefined) return apply(nativeMatchMedia, globalThis, [String(query)]);
            // The answer rides on a query the engine always respects.
            const list = apply(nativeMatchMedia, globalThis,
                               [matches ? '(min-width: 0px)' : '(min-width: 1000000px)']);
            define(list, 'media', { value: String(query), configurable: true });
            return list;
          },
          writable: matchMediaDescriptor.writable,
          enumerable: matchMediaDescriptor.enumerable,
          configurable: matchMediaDescriptor.configurable,
        });
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
