@testable import AnyBrowserCore
import Foundation
import JavaScriptCore
import Testing

/// The screen/device half of the identity guard: the engine reports the host display for every
/// Profile, so the content script has to supply the values without adding own keys to
/// `navigator`/`document` (Stripe reads `Object.keys` of both), and without looking like a script
/// that replaced them.
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
        #expect(screen?.literal.contains("\"screen\":{\"width\":1920,\"height\":1920,\"availWidth\":1920,\"availHeight\":1920,\"availLeft\":0,\"availTop\":0}") == true)
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

    @Test("Connection qualities carry the values Chrome reports for their class")
    func connectionLiteral() {
        #expect(IdentityShim.ConnectionQuality.fourG.literal
            == "{\"effectiveType\":\"4g\",\"rtt\":50,\"downlink\":10,\"saveData\":false}")
        #expect(IdentityShim.ConnectionQuality.threeG.literal
            == "{\"effectiveType\":\"3g\",\"rtt\":300,\"downlink\":1.5,\"saveData\":false}")
        #expect(IdentityShim.ConnectionQuality.slow2G.literal
            == "{\"effectiveType\":\"slow-2g\",\"rtt\":2000,\"downlink\":0.5,\"saveData\":true}")
        #expect(IdentityShim.script(seed: 1, values: nil, connection: .threeG)
            .contains("const link = {\"effectiveType\":\"3g\""))
        #expect(IdentityShim.script(seed: 1, values: nil).contains("const link = null;"))
        #expect(IdentityShim.script(seed: 1, values: nil, isPrivate: true).contains("const priv = true;"))
        #expect(IdentityShim.script(seed: 1, values: nil).contains("const priv = false;"))
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
        let source = context.evaluateScript("Function.prototype.toString")
        let before = context.evaluateScript(snapshot()).toString()
        context.evaluateScript(script)
        #expect(context.evaluateScript(snapshot()).toString() == before)
        #expect(context.evaluateScript("Function.prototype.toString").isEqual(to: source) == true)
        #expect(context.evaluateScript("nativeCalls.length").toInt32() == 0)
    }

    // MARK: The script against a stand-in page

    @Test("Screen, dpr and media queries report the Profile's values")
    func installsValues() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
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
        #expect(context.evaluateScript("'workerNavigatorPoints' in navigator").toBool() == false)

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
        #expect(context.evaluateScript("matchMedia('(width: 1280px)').query").toString() == "(width: 1280px)")
    }

    @Test("matchMedia is shaped like a WebIDL method")
    func matchMediaForm() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        let form = context.evaluateScript("""
        (() => {
          let zero = '';
          try { matchMedia(); } catch (e) { zero = e.message; }
          let receiver = '';
          try { matchMedia.call({}, '(width: 1280px)'); } catch (e) { receiver = e.message; }
          let symbol = '';
          try { matchMedia(Symbol('x')); } catch (e) { symbol = e.message; }
          let constructed = false;
          try { new matchMedia('(width: 1280px)'); } catch (e) { constructed = true; }
          const descriptor = Object.getOwnPropertyDescriptor(window, 'matchMedia');
          return {
            zero, receiver, symbol, constructed,
            name: matchMedia.name, length: matchMedia.length,
            prototype: 'prototype' in matchMedia,
            own: Object.getOwnPropertyNames(matchMedia).sort().join(','),
            writable: descriptor.writable, enumerable: descriptor.enumerable,
            source: String(matchMedia),
          };
        })()
        """).toDictionary() ?? [:]
        #expect(form["zero"] as? String
            == "Failed to execute 'matchMedia' on 'Window': 1 argument required, but only 0 present.")
        #expect(form["receiver"] as? String == "Illegal invocation")
        #expect(form["symbol"] as? String == "Cannot convert a Symbol value to a string")
        #expect(form["constructed"] as? Bool == true)
        #expect(form["name"] as? String == "matchMedia")
        #expect(form["length"] as? Int == 1)
        #expect(form["prototype"] as? Bool == false)
        #expect(form["own"] as? String == "length,name")
        #expect(form["writable"] as? Bool == true)
        #expect(form["enumerable"] as? Bool == true)
        #expect(form["source"] as? String == "function matchMedia() { [native code] }")
        // A window receiver still works.
        #expect(context.evaluateScript("matchMedia.call(window, '(width: 1280px)').matches").toBool())
    }

    @Test("Replaced functions print as native code; everything else keeps its own")
    func toStringForm() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        let shape = context.evaluateScript("""
        (() => {
          const get = (object, key) => Object.getOwnPropertyDescriptor(object, key);
          const printed = (fn) => String(fn);
          return {
            getter: get(Screen.prototype, 'width').get.toString(),
            method: printed(matchMedia),
            touch: get(Navigator.prototype, 'maxTouchPoints').get.toString(),
            memory: get(Navigator.prototype, 'deviceMemory').get.toString(),
            handler: get(window, 'ontouchstart').get.toString(),
            self: printed(Function.prototype.toString),
            eval: printed(eval),
            evalLength: printed(eval).length,
            native: printed(Object.keys),
            plainSource: (function sample() {
              return '[native code]';
            }).toString(),
            toStringLength: Function.prototype.toString.length,
            toStringName: Function.prototype.toString.name,
            getterOwn: Object.getOwnPropertyNames(get(Screen.prototype, 'width').get).sort().join(','),
          };
        })()
        """).toDictionary() ?? [:]
        #expect(shape["getter"] as? String == "function get width() { [native code] }")
        #expect(shape["method"] as? String == "function matchMedia() { [native code] }")
        #expect(shape["touch"] as? String == "function get maxTouchPoints() { [native code] }")
        #expect(shape["memory"] as? String == "function get deviceMemory() { [native code] }")
        #expect(shape["handler"] as? String == "function get ontouchstart() { [native code] }")
        #expect(shape["self"] as? String == "function toString() { [native code] }")
        #expect(shape["eval"] as? String == "function eval() { [native code] }")
        #expect(shape["evalLength"] as? Int == 33)
        #expect(shape["native"] as? String == "function keys() { [native code] }")
        // A page function whose source merely mentions the marker keeps its own text.
        #expect((shape["plainSource"] as? String)?.contains("return '[native code]'") == true)
        #expect((shape["plainSource"] as? String)?.contains("\n") == true)
        #expect(shape["toStringLength"] as? Int == 0)
        #expect(shape["toStringName"] as? String == "toString")
        #expect(shape["getterOwn"] as? String == "length,name")
        // The wrapper itself is shaped like the native it replaced: not constructible, no prototype.
        #expect(context.evaluateScript("'prototype' in Function.prototype.toString").toBool() == false)
    }

    @Test("Passkey Box replacements print as native whether it installed before or after")
    func passkeyToString() throws {
        let context = try realm()
        func passkeySlots() {
            context.evaluateScript("""
            (() => {
              globalThis.CredentialsContainer = function CredentialsContainer() { throw new TypeError('Illegal constructor'); };
              Object.defineProperty(CredentialsContainer.prototype, 'create', {
                value: function create(options) { return options; }, writable: true, enumerable: true, configurable: true });
              Object.defineProperty(CredentialsContainer.prototype, 'get', {
                value: function get(options) { return options; }, writable: true, enumerable: true, configurable: true });
              globalThis.PublicKeyCredential = function PublicKeyCredential() { throw new TypeError('Illegal constructor'); };
              Object.defineProperty(PublicKeyCredential, 'isUserVerifyingPlatformAuthenticatorAvailable', {
                value: function isUserVerifyingPlatformAuthenticatorAvailable() { return Promise.resolve(true); },
                writable: true, enumerable: true, configurable: true });
              Object.defineProperty(Navigator.prototype, 'credentials', {
                get: function () { return Object.create(CredentialsContainer.prototype); },
                enumerable: true, configurable: true });
            })();
            """)
        }
        // Installed before the guard.
        passkeySlots()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        #expect(context.evaluateScript("String(navigator.credentials.create)").toString()
            == "function create() { [native code] }")
        #expect(context.evaluateScript("String(navigator.credentials.get)").toString()
            == "function get() { [native code] }")
        #expect(context.evaluateScript("String(PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable)").toString()
            == "function isUserVerifyingPlatformAuthenticatorAvailable() { [native code] }")

        // Installed after the guard: recognized when asked for.
        let late = try realm()
        late.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        late.evaluateScript("""
        globalThis.CredentialsContainer = function CredentialsContainer() {};
        Object.defineProperty(CredentialsContainer.prototype, 'create', {
          value: function create() {}, writable: true, enumerable: true, configurable: true });
        """)
        #expect(late.evaluateScript("String(CredentialsContainer.prototype.create)").toString()
            == "function create() { [native code] }")
    }

    @Test("navigator and document keep their own-key invariant")
    func ownKeys() throws {
        let context = try realm()
        #expect(context.evaluateScript("Object.keys(navigator).join(',')").toString() == "")
        #expect(context.evaluateScript("Object.keys(document).join(',')").toString() == "location")
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), isPrivate: true,
                                                   connection: .fourG))
        #expect(context.evaluateScript("Object.keys(navigator).join(',')").toString() == "")
        #expect(context.evaluateScript("Object.keys(document).join(',')").toString() == "location")
        #expect(context.evaluateScript("Object.keys(navigator.connection).join(',')").toString() == "")
        #expect(context.evaluateScript("Object.keys(matchMedia('(width: 1280px)')).join(',')").toString() == "")
        #expect(context.evaluateScript("Object.getOwnPropertyNames(matchMedia('(width: 1280px)')).join(',')")
            .toString() == "")
    }

    @Test("A media query list is a proxy: answers from the guard, methods still reach the native list")
    func mediaListProxy() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        let list = context.evaluateScript("""
        (() => {
          const list = matchMedia('(width: 1280px)');
          list.addEventListener('change', () => {});
          const other = matchMedia('(width: 2000px)');
          return {
            matches: list.matches, media: list.media, query: list.query,
            other: other.matches,
            proto: Object.getPrototypeOf(list) === MediaQueryList.prototype,
            add: typeof list.addEventListener,
            calls: listenerCalls.join(','),
          };
        })()
        """).toDictionary() ?? [:]
        #expect(list["matches"] as? Bool == true)
        #expect(list["media"] as? String == "(width: 1280px)")
        #expect(list["query"] as? String == "(width: 1280px)")
        #expect(list["other"] as? Bool == false)
        #expect(list["proto"] as? Bool == true)
        #expect(list["add"] as? String == "function")
        #expect(list["calls"] as? String == "change")
    }

    @Test("A second injection changes nothing")
    func idempotent() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), isPrivate: true,
                                                   connection: .threeG))
        let first = context.evaluateScript(snapshot()).toString()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), isPrivate: true,
                                                   connection: .threeG))
        #expect(context.evaluateScript(snapshot()).toString() == first)
    }

    @Test("The plain script installs no toString wrapper")
    func plainScriptLeavesToString() throws {
        let context = try realm()
        let source = context.evaluateScript("Function.prototype.toString")
        context.evaluateScript(IdentityShim.script(seed: 22223))
        #expect(context.evaluateScript("Function.prototype.toString").isEqual(to: source) == true)
    }

    // MARK: Private mode

    @Test("Private mode compresses the storage quota below twice the heap")
    func privateQuota() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), isPrivate: true))
        context.evaluateScript("""
        globalThis.__settled = false;
        navigator.storage.estimate().then(
          (value) => { globalThis.__settledValue = JSON.stringify(value); globalThis.__settled = true; },
          (e) => { globalThis.__settledValue = 'rejected: ' + e.message; globalThis.__settled = true; });
        """)
        let result = settle(context)
        #expect(!result.hasPrefix("rejected"))
        let value = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(value["quota"] as? Int == 1500)   // 1.5 × 1000 byte heap
        #expect(value["usage"] as? Int == 700)
        #expect((value["quota"] as? Int ?? .max) < 2000)

        // Usage above the compressed quota is clamped to it.
        context.evaluateScript("storageUsage = 9000; storageQuota = 50000;")
        context.evaluateScript("""
        globalThis.__settled = false;
        navigator.storage.estimate().then((value) => {
          globalThis.__settledValue = JSON.stringify(value); globalThis.__settled = true; });
        """)
        let clampedValue = try #require(JSONSerialization.jsonObject(
            with: Data(settle(context).utf8)) as? [String: Any])
        #expect(clampedValue["quota"] as? Int == 1500)
        #expect(clampedValue["usage"] as? Int == 1500)

        // The callback form reports the same numbers.
        let callback = context.evaluateScript("""
        (() => {
          let answer = '';
          navigator.webkitTemporaryStorage.queryUsageAndQuota((usage, quota) => { answer = usage + '/' + quota; });
          return answer;
        })()
        """).toString()
        #expect(callback == "1500/1500")
    }

    @Test("Private mode leaves the quota alone when the API is healthy outside private mode")
    func publicQuota() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        let answer = context.evaluateScript("""
        (() => {
          let answer = '';
          navigator.webkitTemporaryStorage.queryUsageAndQuota((usage, quota) => { answer = usage + '/' + quota; });
          return answer;
        })()
        """).toString()
        #expect(answer == "700/100000")
    }

    @Test("An opaque origin reports zero storage instead of rejecting")
    func privateOpaqueOrigin() throws {
        let context = try realm(storageFailure: true)
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), isPrivate: true))
        context.evaluateScript("""
        globalThis.__settled = false;
        navigator.storage.estimate().then(
          (value) => { globalThis.__settledValue = JSON.stringify(value); globalThis.__settled = true; },
          (e) => { globalThis.__settledValue = 'rejected: ' + e.message; globalThis.__settled = true; });
        """)
        #expect(settle(context) == "{\"usage\":0,\"quota\":0}")
        let callback = context.evaluateScript("""
        (() => {
          let answer = '';
          navigator.webkitTemporaryStorage.queryUsageAndQuota((usage, quota) => { answer = usage + '/' + quota; });
          return answer;
        })()
        """).toString()
        #expect(callback == "0/0")
    }

    // MARK: Connection

    @Test("A connection quality fills navigator.connection, creating it when missing")
    func connectionCreation() throws {
        let context = try realm()
        #expect(context.evaluateScript("'connection' in navigator").toBool() == false)
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), connection: .threeG))
        #expect(context.evaluateScript("navigator.connection.effectiveType").toString() == "3g")
        #expect(context.evaluateScript("navigator.connection.rtt").toInt32() == 300)
        #expect(context.evaluateScript("navigator.connection.downlink").toDouble() == 1.5)
        #expect(context.evaluateScript("navigator.connection.saveData").toBool() == false)
        #expect(context.evaluateScript("Object.keys(navigator.connection).length").toInt32() == 0)
        #expect(context.evaluateScript("navigator.connection === navigator.connection").toBool())
        #expect(context.evaluateScript("Object.keys(navigator).join(',')").toString() == "")
    }

    @Test("A host connection's getters are replaced in place")
    func connectionOverride() throws {
        let context = try realm(connection: true)
        #expect(context.evaluateScript("navigator.connection.effectiveType").toString() == "slow-2g")
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(), connection: .fourG))
        #expect(context.evaluateScript("navigator.connection.effectiveType").toString() == "4g")
        #expect(context.evaluateScript("navigator.connection.downlink").toDouble() == 10)
        #expect(context.evaluateScript("navigator.connection.saveData").toBool() == false)
        #expect(context.evaluateScript("Object.keys(navigator.connection).length").toInt32() == 0)
        #expect(context.evaluateScript("String(Object.getOwnPropertyDescriptor(NetworkInformation.prototype, 'effectiveType').get)").toString()
            == "function get effectiveType() { [native code] }")
        // Slow 2g asks sites to save data.
        let slow = try realm(connection: true)
        slow.evaluateScript(IdentityShim.script(seed: 22223, values: values(), connection: .slow2G))
        #expect(slow.evaluateScript("navigator.connection.saveData").toBool())
        #expect(slow.evaluateScript("navigator.connection.effectiveType").toString() == "slow-2g")
        #expect(slow.evaluateScript("navigator.connection.rtt").toInt32() == 2000)
    }

    @Test("Without a quality the host connection is left alone")
    func connectionUntouched() throws {
        let context = try realm(connection: true)
        let getter = context.evaluateScript("Object.getOwnPropertyDescriptor(NetworkInformation.prototype, 'effectiveType').get")
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values()))
        #expect(context.evaluateScript("Object.getOwnPropertyDescriptor(NetworkInformation.prototype, 'effectiveType').get")
            .isEqual(to: getter) == true)
        #expect(context.evaluateScript("navigator.connection.effectiveType").toString() == "slow-2g")
    }

    // MARK: Touch

    @Test("A touch identity can build touch events and answers coarse pointers")
    func touchSurface() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(touch: true, screen: false, scale: false)))
        #expect(context.evaluateScript("typeof Touch").toString() == "function")
        #expect(context.evaluateScript("typeof TouchEvent").toString() == "function")
        #expect(context.evaluateScript("new Touch({ identifier: 3 }).identifier").toInt32() == 3)
        #expect(context.evaluateScript("document.createEvent('TouchEvent') instanceof TouchEvent").toBool())
        #expect(context.evaluateScript("new TouchEvent('touchstart').touches.length").toInt32() == 0)
        #expect(context.evaluateScript("String(Touch)").toString() == "function Touch() { [native code] }")
        #expect(context.evaluateScript("matchMedia('(pointer: coarse)').matches").toBool())
        #expect(context.evaluateScript("matchMedia('(pointer: fine)').matches").toBool() == false)
        #expect(context.evaluateScript("matchMedia('(any-pointer: fine)').matches").toBool())
        #expect(context.evaluateScript("matchMedia('(any-pointer: coarse)').matches").toBool())
        // The worker interface is patched with the same value when the realm exposes it.
        #expect(context.evaluateScript("WorkerNavigator.prototype.maxTouchPoints").toInt32() == 5)
        #expect(context.evaluateScript("Object.keys(document).join(',')").toString() == "location")
    }

    @Test("A non-touch identity answers fine pointers")
    func pointerQueriesWithoutTouch() throws {
        let context = try realm()
        context.evaluateScript(IdentityShim.script(seed: 22223, values: values(touch: false, screen: false, scale: false)))
        #expect(context.evaluateScript("matchMedia('(pointer: coarse)').matches").toBool() == false)
        #expect(context.evaluateScript("matchMedia('(pointer: fine)').matches").toBool())
        #expect(context.evaluateScript("matchMedia('(any-pointer: fine)').matches").toBool())
        #expect(context.evaluateScript("matchMedia('(any-pointer: coarse)').matches").toBool() == false)
        #expect(context.evaluateScript("WorkerNavigator.prototype.maxTouchPoints").toInt32() == 0)
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
            get(WorkerNavigator.prototype, 'maxTouchPoints'), get(window, 'ontouchstart'),
            get(Function.prototype, 'toString'), get(StorageManager.prototype, 'estimate'),
            get(StorageQuota.prototype, 'queryUsageAndQuota'), get(Navigator.prototype, 'connection'),
            get(Document.prototype, 'createEvent'),
            typeof Touch === 'function' ? get(Touch, 'prototype') : '',
            typeof TouchEvent === 'function' ? get(TouchEvent, 'prototype') : '',
            screen.width, window.devicePixelRatio,
            navigator.deviceMemory, navigator.maxTouchPoints,
            navigator.connection && navigator.connection.effectiveType,
            Object.getOwnPropertyNames(window).join(','), Object.getOwnPropertyNames(document).join(','),
          ].join('|');
        })()
        """
    }

    /// Drains JavaScriptCore's microtask queue until the last promise handler has stored its answer.
    private func settle(_ context: JSContext) -> String {
        for _ in 0..<16 {
            if context.evaluateScript("globalThis.__settled === true").toBool() { break }
            context.evaluateScript("void 0")
        }
        return context.evaluateScript("globalThis.__settledValue").toString()
    }

    /// A document realm shaped like Chromium's: native-looking descriptors on the interfaces,
    /// no own `ontouchstart` (desktop Chromium has none), and a matchMedia that keeps its query in
    /// a slot instead of an own property like the real one.
    private func realm(touch: Bool = false, connection: Bool = false, storage: Bool = true,
                       storageFailure: Bool = false) throws -> JSContext {
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
          globalThis.WorkerNavigator = native(function WorkerNavigator() { throw new TypeError('Illegal constructor'); });
          define(WorkerNavigator.prototype, 'maxTouchPoints', { get: native(function () { return 0; }), enumerable: true, configurable: true });
          define(globalThis, 'navigator', { value: Object.create(Navigator.prototype), configurable: true });
          define(globalThis, 'window', { value: globalThis, configurable: true });
          globalThis.screen = Object.create(Screen.prototype);
          globalThis.isSecureContext = true;
          define(globalThis, 'devicePixelRatio', {
            get: native(function () { return 1; }), set: native(function (value) {}),
            enumerable: true, configurable: true,
          });
          globalThis.Document = native(function Document() { throw new TypeError('Illegal constructor'); });
          define(Document.prototype, 'createEvent', {
            value: native(function createEvent(name) { return { type: String(name) }; }),
            writable: true, enumerable: true, configurable: true,
          });
          const documentObject = Object.create(Document.prototype);
          define(documentObject, 'location', { value: {}, enumerable: true, configurable: true });
          globalThis.document = documentObject;
          globalThis.MediaQueryList = native(function MediaQueryList() { throw new TypeError('Illegal constructor'); });
          const queries = new WeakMap();
          define(MediaQueryList.prototype, 'matches', {
            get: native(function () { return !queries.get(this).includes('1000000'); }), enumerable: true, configurable: true });
          define(MediaQueryList.prototype, 'media', {
            get: native(function () { return queries.get(this); }), enumerable: true, configurable: true });
          define(MediaQueryList.prototype, 'query', {
            get: native(function () { return queries.get(this); }), enumerable: true, configurable: true });
          globalThis.listenerCalls = [];
          define(MediaQueryList.prototype, 'addEventListener', {
            value: native(function addEventListener(type) { listenerCalls.push(type); }),
            writable: true, enumerable: true, configurable: true,
          });
          globalThis.nativeCalls = [];
          define(globalThis, 'matchMedia', {
            value: native(function matchMedia(query) {
              globalThis.nativeCalls.push(String(query));
              const list = Object.create(MediaQueryList.prototype);
              queries.set(list, String(query));
              return list;
            }),
            writable: true, enumerable: true, configurable: true,
          });
          define(globalThis, 'performance', { value: { memory: { jsHeapSizeLimit: 1000 } }, configurable: true });
          if (\(storage)) {
            globalThis.storageUsage = 700;
            globalThis.storageQuota = 100000;
            globalThis.storageCalls = [];
            globalThis.StorageManager = native(function StorageManager() { throw new TypeError('Illegal constructor'); });
            define(StorageManager.prototype, 'estimate', {
              value: native(function estimate() {
                storageCalls.push('estimate');
                if (\(storageFailure)) return Promise.reject(new Error('blocked'));
                return Promise.resolve({ usage: storageUsage, quota: storageQuota });
              }),
              writable: true, enumerable: true, configurable: true,
            });
            const manager = Object.create(StorageManager.prototype);
            define(Navigator.prototype, 'storage', {
              get: native(function () { return manager; }), enumerable: true, configurable: true });
            globalThis.StorageQuota = native(function StorageQuota() { throw new TypeError('Illegal constructor'); });
            define(StorageQuota.prototype, 'queryUsageAndQuota', {
              value: native(function queryUsageAndQuota(success, failure) {
                storageCalls.push('query');
                if (\(storageFailure)) { failure(new Error('blocked')); return; }
                success(storageUsage, storageQuota);
              }),
              writable: true, enumerable: true, configurable: true,
            });
            const temporary = Object.create(StorageQuota.prototype);
            define(Navigator.prototype, 'webkitTemporaryStorage', {
              get: native(function () { return temporary; }), enumerable: true, configurable: true });
          }
          if (\(connection)) {
            globalThis.NetworkInformation = native(function NetworkInformation() { throw new TypeError('Illegal constructor'); });
            const info = Object.create(NetworkInformation.prototype);
            define(NetworkInformation.prototype, 'effectiveType', {
              get: native(function () { return 'slow-2g'; }), enumerable: true, configurable: true });
            define(NetworkInformation.prototype, 'rtt', {
              get: native(function () { return 4000; }), enumerable: true, configurable: true });
            define(NetworkInformation.prototype, 'downlink', {
              get: native(function () { return 0.05; }), enumerable: true, configurable: true });
            define(NetworkInformation.prototype, 'saveData', {
              get: native(function () { return true; }), enumerable: true, configurable: true });
            define(Navigator.prototype, 'connection', {
              get: native(function () { return info; }), enumerable: true, configurable: true });
          }
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