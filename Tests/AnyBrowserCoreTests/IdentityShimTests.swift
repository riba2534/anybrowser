@testable import AnyBrowserCore
import Foundation
import JavaScriptCore
import Testing

struct IdentityShimTests {
    @Test("The shim is loaded for every engine version; its script checks the engine at runtime")
    func versionGate() {
        #expect(IdentityShim.isNeeded(for: "148.0.7778.215"))
        #expect(IdentityShim.isNeeded(for: "150.0.7871.186"))
        #expect(IdentityShim.isNeeded(for: "not-a-version"))
    }

    @Test("The measureText factor follows the engine's libc++ hash of the seed")
    func measureTextFactor() {
        // 22223 was read back from engine 148 (0.0015734002554705154 / 337.4765625); the others
        // come from an independent BigInt port of libc++'s CityHash64 branch.
        let expected: [Int: Double] = [
            1: 0.0000037828547923785764,
            7: 6.098178624198348e-7,
            4244: -7.401266486244563e-8,
            22223: 0.000004662250450267981,
            22224: 0.0000010581590132923235,
            2147483647: 0.0000026852478570503294,
        ]
        for (seed, factor) in expected {
            #expect(IdentityShim.measureTextFactor(seed: seed) == factor, "\(seed)")
        }
        #expect(0.0015734002554705154 / 337.4765625 == IdentityShim.measureTextFactor(seed: 22223))
        // Out-of-range seeds leave the script inactive instead of trapping.
        #expect(IdentityShim.measureTextFactor(seed: Int.max) == 0)
    }

    @Test("Preparing the shim writes a per-Profile script without globals and drops the old config")
    func preparesExtension() throws {
        let storage = try scratchDirectory("identity-shim")
        defer { try? FileManager.default.removeItem(at: storage) }
        var profile = BrowserProfile(name: "Shim", port: 9301, fingerprint: FingerprintSettings(seed: 22223))
        profile.fingerprint.language = "en-US"
        profile = try profile.validated()
        let directory = IdentityShim.directory(in: storage, for: profile.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("globalThis.__ANYBROWSER_INTL__ = {};".utf8).write(to: directory.appendingPathComponent("config.js"))

        try IdentityShim.prepare(for: profile, in: storage)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["content.js", "manifest.json"])
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let scripts = try #require((manifest["content_scripts"] as? [[String: Any]])?.first)
        #expect(scripts["world"] as? String == "MAIN")
        #expect(scripts["all_frames"] as? Bool == true)
        #expect(scripts["match_origin_as_fallback"] as? Bool == true)
        #expect(scripts["js"] as? [String] == ["content.js"])

        let script = try String(contentsOf: directory.appendingPathComponent("content.js"), encoding: .utf8)
        #expect(script.contains("const factor = \(IdentityShim.measureTextFactor(seed: 22223));"))
        for marker in ["anybrowser", "Symbol.for", "globalThis.__", "DateTimeFormat", "Intl"] {
            #expect(!script.localizedCaseInsensitiveContains(marker), "\(marker)")
        }

        var other = profile
        other.id = UUID()
        other.fingerprint.seed = 22224
        try IdentityShim.prepare(for: other, in: storage)
        let otherScript = try String(contentsOf: IdentityShim.directory(in: storage, for: other.id)
            .appendingPathComponent("content.js"), encoding: .utf8)
        #expect(otherScript != script)
        #expect(otherScript.contains("const factor = \(IdentityShim.measureTextFactor(seed: 22224));"))
    }

    // MARK: The script against a stand-in engine

    /// A JavaScriptCore realm with an engine-like `TextMetrics` whose getters look native, and an
    /// OffscreenCanvas that scales non-empty text by `scale`.
    private func realm(scale: Double) throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JavaScript error: \(exception?.toString() ?? "")") }
        context.evaluateScript("""
        (() => {
          const keys = ['width', 'actualBoundingBoxLeft', 'actualBoundingBoxRight', 'fontBoundingBoxAscent',
            'fontBoundingBoxDescent', 'actualBoundingBoxAscent', 'actualBoundingBoxDescent',
            'hangingBaseline', 'alphabeticBaseline', 'ideographicBaseline'];
          const slots = new WeakMap();
          globalThis.TextMetrics = function TextMetrics() { throw new TypeError('Illegal constructor'); };
          for (const key of keys) {
            // A function proxy prints as [native code] in JavaScriptCore, like a real getter.
            const get = new Proxy(function () {
              if (!slots.has(this)) throw new TypeError('Illegal invocation');
              return slots.get(this)[key];
            }, {});
            Object.defineProperty(TextMetrics.prototype, key, { get, enumerable: true, configurable: true });
          }
          const real = (text) => ({ width: Math.fround(text.length * 11.3), actualBoundingBoxLeft: -1.1953125,
            actualBoundingBoxRight: Math.fround(text.length * 11.2), fontBoundingBoxAscent: 22, fontBoundingBoxDescent: 5,
            actualBoundingBoxAscent: 17.47265625, actualBoundingBoxDescent: 5.05078125,
            hangingBaseline: Math.fround(17.6), alphabeticBaseline: 0, ideographicBaseline: -5 });
          globalThis.measure = (text, scale) => {
            const values = real(text);
            // Zero-width text is still scaled; only empty text is left alone.
            if (text === '\\u200b') { values.width = 0; values.actualBoundingBoxRight = 0; }
            if (text.length > 0) for (const key of keys) values[key] *= scale;
            const metrics = Object.create(TextMetrics.prototype);
            slots.set(metrics, values);
            return metrics;
          };
          globalThis.truth = real;
          globalThis.OffscreenCanvas = function () {};
          OffscreenCanvas.prototype.getContext = () => ({ font: '', measureText: (text) => measure(String(text), \(scale)) });
        })();
        """)
        return context
    }

    @Test("The script divides the factor out in the TextMetrics getters and leaves nothing behind")
    func scriptRestoresMetrics() throws {
        let factor = IdentityShim.measureTextFactor(seed: 22223)
        let context = try realm(scale: factor)
        let before = context.evaluateScript("Object.getOwnPropertyNames(globalThis).concat(Object.getOwnPropertySymbols(globalThis).map(String))")
            .toArray() as? [String] ?? []
        context.evaluateScript(IdentityShim.script(seed: 22223))
        let after = context.evaluateScript("Object.getOwnPropertyNames(globalThis).concat(Object.getOwnPropertySymbols(globalThis).map(String))")
            .toArray() as? [String] ?? []
        #expect(after == before)

        let restored = context.evaluateScript("""
        (() => {
          const keys = Object.keys(truth('x'));
          const same = (text) => keys.every((key) => Object.is(measure(text, \(factor))[key], truth(text)[key]));
          return same('Cwm fjordbank glyphs vext quiz') && same('a') && same('mmmmmmmmmmlli');
        })()
        """).toBool()
        #expect(restored)
        // Empty text is not scaled by the engine, so the script must not rescale it either.
        #expect(context.evaluateScript("measure('', \(factor)).fontBoundingBoxAscent").toDouble() == 22)
        #expect(context.evaluateScript("measure('\\u200b', \(factor)).fontBoundingBoxAscent").toDouble() == 22)

        let getter = context.evaluateScript("""
        (() => {
          const get = Object.getOwnPropertyDescriptor(TextMetrics.prototype, 'width').get;
          let threw = '';
          try { get.call({}); } catch (e) { threw = e.message; }
          let constructed = true;
          try { new get(); } catch (e) { constructed = false; }
          return { name: get.name, length: get.length, own: Object.getOwnPropertyNames(get).sort().join(','),
            prototype: 'prototype' in get, constructed, threw,
            enumerable: Object.getOwnPropertyDescriptor(TextMetrics.prototype, 'width').enumerable };
        })()
        """).toDictionary() ?? [:]
        #expect(getter["name"] as? String == "get width")
        #expect(getter["length"] as? Int == 0)
        #expect(getter["own"] as? String == "length,name")
        #expect(getter["prototype"] as? Bool == false)
        #expect(getter["constructed"] as? Bool == false)
        #expect(getter["threw"] as? String == "Illegal invocation")
        #expect(getter["enumerable"] as? Bool == true)

        // A second injection into the same document finds its own getters and changes nothing.
        context.evaluateScript(IdentityShim.script(seed: 22223))
        #expect(context.evaluateScript("measure('a', \(factor)).width === truth('a').width").toBool())
    }

    @Test("A fixed engine or disabled Canvas spoofing keeps the native getters")
    func scriptStaysInactiveWhenWidthsAreReal() throws {
        let context = try realm(scale: 1 + IdentityShim.measureTextFactor(seed: 22223))
        let native = context.evaluateScript("Object.getOwnPropertyDescriptor(TextMetrics.prototype, 'width').get")
        context.evaluateScript(IdentityShim.script(seed: 22223))
        let current = context.evaluateScript("Object.getOwnPropertyDescriptor(TextMetrics.prototype, 'width').get")
        #expect(current?.isEqual(to: native) == true)
    }
}
