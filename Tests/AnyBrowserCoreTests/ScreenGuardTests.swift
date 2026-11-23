@testable import AnyBrowserCore
import Foundation
import JavaScriptCore
import Testing

/// The screen/device half of the identity guard: the engine reports the host display for every
/// Profile, so the content script has to supply the values without adding own keys to
/// `navigator`/`document` (Stripe reads `Object.keys` of both).
struct ScreenGuardTests {
    // MARK: Values

    @Test("The guard literal carries only the configured values")
    func guardLiteral() {
        var fingerprint = FingerprintSettings(seed: 22223)
        #expect(IdentityShim.ScreenGuard.from(fingerprint) == nil)

        fingerprint.platform = .windows
        fingerprint.screenWidth = 1920
        fingerprint.deviceScaleFactor = 1.25
        let screen = try? #require(IdentityShim.ScreenGuard.from(fingerprint))
        #expect(screen?.literal.contains("\"screen\":{\"width\":1920,\"height\":1920,\"availWidth\":1920,\"availHeight\":1920}") == true)
        #expect(screen?.literal.contains("\"dpr\":1.25") == true)
        #expect(screen?.literal.contains("\"deviceMemory\"") == false)

        fingerprint.availWidth = 1900
        fingerprint.availHeight = 1000
        fingerprint.colorDepth = 24
        fingerprint.deviceMemory = 16
        fingerprint.touch = false
        let full = try? #require(IdentityShim.ScreenGuard.from(fingerprint))
        #expect(full?.literal.contains("\"availWidth\":1900") == true)
        #expect(full?.literal.contains("\"colorDepth\":24") == true)
        #expect(full?.literal.contains("\"deviceMemory\":16") == true)
        #expect(full?.literal.contains("\"touch\":false") == true)

        // Screen values without a platform belong to no identity; the device values stand alone.
        var platformless = FingerprintSettings(seed: 22223)
        platformless.screenWidth = 1440
        platformless.deviceScaleFactor = 2
        #expect(IdentityShim.ScreenGuard.from(platformless) == nil)
        platformless.deviceMemory = 8
        #expect(IdentityShim.ScreenGuard.from(platformless)?.literal == "{\"deviceMemory\":8}")
    }

    @Test("Either half of the shim keeps it mounted")
    func mountCondition() {
        var profile = BrowserProfile(name: "Mount", port: 9311, fingerprint: FingerprintSettings(seed: 1))
        #expect(IdentityShim.isNeeded(for: "999.0.0.0"))
        #expect(IdentityShim.isNeeded(for: "999.0.0.0", profile: profile))
        profile.fingerprint.touch = false
        #expect(IdentityShim.isNeeded(for: "999.0.0.0", profile: profile))
    }

    // MARK: Files

    @Test("Preparing still writes a MAIN-world, all-frame manifest and the guard script")
    func preparesExtension() throws {
        let storage = try scratchDirectory("screen-guard")
        defer { try? FileManager.default.removeItem(at: storage) }
        var profile = BrowserProfile(name: "Guard", port: 9312, fingerprint: FingerprintSettings(seed: 22223))
        profile.fingerprint.platform = .macOS
        profile.fingerprint.screenWidth = 1512
        profile.fingerprint.screenHeight = 982
        profile.fingerprint.colorDepth = 30
        profile.fingerprint.deviceScaleFactor = 2
        profile = try profile.validated()

        try IdentityShim.prepare(for: profile, in: storage)
        let directory = IdentityShim.directory(in: storage, for: profile.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            == ["content.js", "manifest.json"])
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let scripts = try #require((manifest["content_scripts"] as? [[String: Any]])?.first)
        #expect(scripts["world"] as? String == "MAIN")
        #expect(scripts["all_frames"] as? Bool == true)
        #expect(scripts["run_at"] as? String == "document_start")

        let script = try String(contentsOf: directory.appendingPathComponent("content.js"), encoding: .utf8)
        #expect(script.contains("\"screen\":{\"width\":1512,\"height\":982"))
        #expect(script.contains("\"colorDepth\":30"))
        #expect(script.contains("\"dpr\":2"))
        #expect(!script.contains("\"touch\""))
    }

    @Test("A plain Profile carries no guard and installs nothing")
    func withoutConfiguration() throws {
        let context = try realm()
        let script = IdentityShim.script(seed: 22223)
        #expect(script.contains("const fake = null;"))
        let before = context.evaluateScript(snapshot()).toString()
        context.evaluateScript(script)
        #expect(context.evaluateScript(snapshot()).toString() == before)
        #expect(context.evaluateScript("nativeCalls.length").toInt32() == 0)
    }

    // MARK: The script against a stand-in page

    @Test("Screen, dpr and media queries report the Profile's values")
    func installsValues() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        print("debug:", context.evaluateScript("globalThis.debugError || 'none'").toString() ?? "nil")
        print("desc:", context.evaluateScript("String(Object.getOwnPropertyDescriptor(Screen.prototype, 'width').get)").toString() ?? "nil")
        #expect(context.evaluateScript("screen.width").toInt32() == 1280)
        #expect(context.evaluateScript("screen.height").toInt32() == 720)
        #expect(context.evaluateScript("screen.availWidth").toInt32() == 1280)
        #expect(context.evaluateScript("screen.availHeight").toInt32() == 680)
        #expect(context.evaluateScript("screen.colorDepth").toInt32() == 24)
        #expect(context.evaluateScript("screen.pixelDepth").toInt32() == 24)
        #expect(context.evaluateScript("window.devicePixelRatio").toDouble() == 2)
        #expect(context.evaluateScript("navigator.deviceMemory").toInt32() == 16)
        #expect(context.evaluateScript("navigator.maxTouchPoints").toInt32() == 5)
        #expect(context.evaluateScript("'ontouchstart' in window").toBool())
        #expect(context.evaluateScript("window.ontouchstart").isNull)

        // Native descriptors keep their shape: a getter named after the key, no setter, enumerable.
        let descriptor = context.evaluateScript("""
        (() => {
          const d = Object.getOwnPropertyDescriptor(Screen.prototype, 'width');
          let threw = '';
          try { Screen.prototype.width; } catch (e) { threw = e.message; }
          return { name: d.get.name, set: typeof d.set, enumerable: d.enumerable, threw };
        })()
        """).toDictionary() ?? [:]
        #expect(descriptor["name"] as? String == "get width")
        #expect(descriptor["set"] as? String == "undefined")
        #expect(descriptor["enumerable"] as? Bool == true)
        #expect(descriptor["threw"] as? String == "Illegal invocation")

        let media = context.evaluateScript("""
        (() => {
          const ask = (query) => matchMedia(query).matches;
          return [
            ask('(resolution: 2dppx)'), ask('(resolution: 1dppx)'),
            ask('(min-resolution: 1dppx)'), ask('(max-resolution: 1dppx)'),
            ask('(min-width: 1000px)'), ask('(min-width: 2000px)'),
            ask('(max-width: 2000px)'), ask('(width: 1280px)'),
            ask('(min-width: 1000px) and (max-width: 1400px)'),
            ask('(orientation: portrait)'),
          ].join(',');
        })()
        """).toString()
        #expect(media == "true,false,true,false,true,false,true,true,true,true")
        // The unknown clause was left to the native implementation.
        #expect(context.evaluateScript("nativeCalls[nativeCalls.length - 1]").toString() == "(orientation: portrait)")
        #expect(context.evaluateScript("matchMedia('(resolution: 2dppx)').media").toString() == "(resolution: 2dppx)")
        // `media` shadows the prototype getter without becoming an own enumerable key.
        #expect(context.evaluateScript("Object.keys(matchMedia('(width: 1280px)')).includes('media')").toBool() == false)
    }

    @Test("navigator and document keep their own-key invariant")
    func ownKeys() throws {
        let context = try realm()
        #expect(context.evaluateScript("Object.keys(navigator).join(',')").toString() == "")
        #expect(context.evaluateScript("Object.keys(document).join(',')").toString() == "location")
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        #expect(context.evaluateScript("Object.keys(navigator).join(',')").toString() == "")
        #expect(context.evaluateScript("Object.keys(document).join(',')").toString() == "location")
    }

    @Test("A second injection changes nothing")
    func idempotent() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        let first = context.evaluateScript(snapshot()).toString()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        #expect(context.evaluateScript(snapshot()).toString() == first)
    }

    @Test("touch false pins maxTouchPoints to 0 and removes ontouchstart")
    func nonTouch() throws {
        let context = try realm(touch: true)
        #expect(context.evaluateScript("'ontouchstart' in window").toBool())
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(touch: false, screen: false, scale: false)))
        #expect(context.evaluateScript("'ontouchstart' in window").toBool() == false)
        #expect(context.evaluateScript("navigator.maxTouchPoints").toInt32() == 0)
        // Screen getters were not configured, so they keep the host answer.
        #expect(context.evaluateScript("screen.width").toInt32() == 800)
        #expect(context.evaluateScript("window.devicePixelRatio").toDouble() == 1)
    }

    @Test("touch true keeps a touch host's own ontouchstart")
    func touchHostTogether() throws {
        let context = try realm(touch: true)
        let native = context.evaluateScript("Object.getOwnPropertyDescriptor(window, 'ontouchstart').get")
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(touch: true, screen: false, scale: false)))
        #expect(context.evaluateScript("Object.getOwnPropertyDescriptor(window, 'ontouchstart').get")
            .isEqual(to: native) == true)
        #expect(context.evaluateScript("navigator.maxTouchPoints").toInt32() == 5)
    }

    // MARK: Stand-in page

    private func values(touch: Bool? = true, screen: Bool = true, scale: Bool = true)
        -> IdentityShim.ScreenGuard {
        IdentityShim.ScreenGuard(
            screen: screen
                ? .init(width: 1280, height: 720, availWidth: 1280, availHeight: 680, colorDepth: 24)
                : nil,
            scale: scale ? 2 : nil,
            deviceMemory: 16,
            touch: touch)
    }

    /// Descriptor identities for every patched target, plus the visible values.
    private func snapshot() -> String {
        """
        (() => {
          const get = (object, key) => (Object.getOwnPropertyDescriptor(object, key) || {}).get
            || (Object.getOwnPropertyDescriptor(object, key) || {}).value;
          return [
            get(Screen.prototype, 'width'), get(Screen.prototype, 'height'),
            get(Screen.prototype, 'availWidth'), get(Screen.prototype, 'availHeight'),
            get(Screen.prototype, 'colorDepth'), get(Screen.prototype, 'pixelDepth'),
            get(window, 'devicePixelRatio'), get(window, 'matchMedia'),
            get(Navigator.prototype, 'deviceMemory'), get(Navigator.prototype, 'maxTouchPoints'),
            get(window, 'ontouchstart'), screen.width, window.devicePixelRatio,
            navigator.deviceMemory, navigator.maxTouchPoints,
            Object.getOwnPropertyNames(window).join(','),
          ].join('|');
        })()
        """
    }

    /// A document realm shaped like Chromium's: native-looking descriptors on the interfaces,
    /// no own `ontouchstart` (desktop Chromium has none), and a matchMedia that answers the two
    /// queries the guard uses for its own answers.
    private func realm(touch: Bool = false) throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JavaScript error: \(exception?.toString() ?? "")") }
        context.evaluateScript("""
        (() => {
          const native = (fn) => new Proxy(fn, {});
          const define = Object.defineProperty;
          globalThis.Screen = native(function Screen() { throw new TypeError('Illegal constructor'); });
          for (const key of ['width', 'height', 'availWidth', 'availHeight', 'colorDepth', 'pixelDepth']) {
            define(Screen.prototype, key, { get: native(function () { return 800; }), enumerable: true, configurable: true });
          }
          globalThis.Navigator = native(function Navigator() { throw new TypeError('Illegal constructor'); });
          define(Navigator.prototype, 'deviceMemory', { get: native(function () { return 8; }), enumerable: true, configurable: true });
          define(Navigator.prototype, 'maxTouchPoints', { get: native(function () { return 0; }), enumerable: true, configurable: true });
          define(globalThis, 'navigator', { value: Object.create(Navigator.prototype), configurable: true });
          define(globalThis, 'window', { value: globalThis, configurable: true });
          globalThis.screen = Object.create(Screen.prototype);
          globalThis.document = { location: {} };
          globalThis.isSecureContext = true;
          define(globalThis, 'devicePixelRatio', {
            get: native(function () { return 1; }), set: native(function (value) {}),
            enumerable: true, configurable: true,
          });
          globalThis.MediaQueryList = native(function MediaQueryList() { throw new TypeError('Illegal constructor'); });
          define(MediaQueryList.prototype, 'matches', {
            get: native(function () { return !this.query.includes('1000000'); }), enumerable: true, configurable: true });
          define(MediaQueryList.prototype, 'media', {
            get: native(function () { return this.query; }), enumerable: true, configurable: true });
          globalThis.nativeCalls = [];
          define(globalThis, 'matchMedia', {
            value: native(function matchMedia(query) {
              globalThis.nativeCalls.push(String(query));
              const list = Object.create(MediaQueryList.prototype);
              define(list, 'query', { value: String(query), configurable: true });
              return list;
            }),
            writable: true, enumerable: true, configurable: true,
          });
          if (\(touch)) {
            define(window, 'ontouchstart', {
              get: native(function () { return null; }), set: native(function (value) {}),
              enumerable: true, configurable: true,
            });
          }
        })();
        """)
        return context
    }
}