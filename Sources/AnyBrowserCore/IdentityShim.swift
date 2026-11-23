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
/// `Function.prototype.toString` is wrapped once per document (the registry lives on the native
/// function under a symbol, so a second injection joins it): every function the script and Passkey
/// Box installed prints as V8 does for a built-in, `function get width() { [native code] }`, while
/// everything else, `eval` included, reaches the native implementation untouched. `matchMedia`
/// becomes an object-literal method with the WebIDL argument, receiver and Symbol checks, and its
/// lists are proxies over the native object without own keys. Private mode compresses the storage
/// quota below twice the JS heap, and a requested connection quality fills `navigator.connection`.
///
/// Otherwise the script stays out of the page: `measureText` stays native and returns real
/// `TextMetrics`, and the getters are accessor-shorthand functions without a prototype. The only
/// additions are the single registry symbol on `Function.prototype.toString` and, on a touch
/// identity whose engine lacks them, the `Touch`/`TouchEvent` constructors. Their stack frames
/// remain visible; only an engine fix removes those.
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
                                      values: .from(profile.fingerprint),
                                      connection: .from(profile)).utf8),
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
                let height = fingerprint.screenHeight ?? max(width, fingerprint.availHeight ?? width)
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
                              "\"availWidth\":\(screen.availWidth)", "\"availHeight\":\(screen.availHeight)",
                              "\"availLeft\":0", "\"availTop\":\(max(0, screen.height - screen.availHeight))"]
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

    /// `navigator.connection` as one of the three values `effectiveType` takes. The numbers are the
    /// ones Chrome reports for the matching network class; an unknown network leaves the host alone.
    enum ConnectionQuality: String, CaseIterable {
        case fourG = "4g"
        case threeG = "3g"
        case slow2G = "slow-2g"

        /// A proxied Profile is rarely on a poor link; an unproxied one keeps the host's values.
        static func from(_ profile: BrowserProfile) -> ConnectionQuality? {
            profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .fourG
        }

        var rtt: Int {
            switch self {
            case .fourG: return 50
            case .threeG: return 300
            case .slow2G: return 2000
            }
        }

        var downlink: Double {
            switch self {
            case .fourG: return 10
            case .threeG: return 1.5
            case .slow2G: return 0.5
            }
        }

        var saveData: Bool { self == .slow2G }

        var literal: String {
            "{\"effectiveType\":\"\(rawValue)\",\"rtt\":\(rtt),"
                + "\"downlink\":\(String(format: "%g", downlink)),\"saveData\":\(saveData)}"
        }
    }

    static let manifest = """
    {
      "manifest_version": 3,
      "name": "AnyBrowser Identity Guard",
      "version": "1.3.0",
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
    /// injection into the same document changes nothing. Without any values only the Canvas fix
    /// runs.
    static func script(seed: Int) -> String {
        script(seed: seed, values: nil)
    }

    /// `isPrivate` reports the compressed storage quota of an incognito window, `connection` the
    /// network class `navigator.connection` should show; both are off unless asked for.
    static func script(seed: Int, values: ScreenGuard?, isPrivate: Bool = false,
                       connection: ConnectionQuality? = nil) -> String {
        scriptTemplate
            .replacingOccurrences(of: "__FACTOR__", with: "\(measureTextFactor(seed: seed))")
            .replacingOccurrences(of: "__GUARD__", with: values?.literal ?? "null")
            .replacingOccurrences(of: "__PRIVATE__", with: isPrivate ? "true" : "false")
            .replacingOccurrences(of: "__CONNECTION__", with: connection?.literal ?? "null")
    }

    private static let scriptTemplate = #"""
    (() => {
      const factor = __FACTOR__;
      const fake = __GUARD__;
      const priv = __PRIVATE__;
      const link = __CONNECTION__;
      // Captured before page scripts run, so later changes to these globals cannot reach the getters.
      const apply = Reflect.apply;
      const describe = Object.getOwnPropertyDescriptor;
      const define = Object.defineProperty;
      const fround = Math.fround;
      const abs = Math.abs;
      const source = Function.prototype.toString;
      const nativeShape = /^function [^()]*\(\) \{\s*\[native code\]\s*\}$/;
      const cache = new WeakMap();
      const cacheGet = WeakMap.prototype.get;
      const cacheSet = WeakMap.prototype.set;
      const isNative = (fn) => {
        try { return apply(source, fn, []).includes('[native code]'); } catch (e) { return false; }
      };

      // Replacement functions print the way V8 prints a built-in, shaped from their name. The set of
      // them lives on the captured native under a symbol, so a second injection joins the existing
      // wrapper instead of stacking another one; everything unregistered reaches the native.
      const shape = (fn) => {
        let name = '';
        try { name = String(fn.name); } catch (e) {}
        return 'function ' + name + '() { [native code] }';
      };
      // Passkey Box replaces these on its own schedule, so they are recognized when asked for
      // rather than at install time.
      const passkeyReplacement = (fn) => {
        if (typeof fn !== 'function') return false;
        const container = globalThis.CredentialsContainer && CredentialsContainer.prototype;
        if (container) for (const key of ['create', 'get']) {
          const descriptor = describe(container, key);
          if (descriptor && descriptor.value === fn) return state.shaped.add(fn), true;
        }
        const credential = globalThis.PublicKeyCredential;
        if (credential) for (const key of ['isUserVerifyingPlatformAuthenticatorAvailable',
          'isConditionalMediationAvailable', 'getClientCapabilities']) {
          const descriptor = describe(credential, key);
          if (descriptor && descriptor.value === fn) return state.shaped.add(fn), true;
        }
        return false;
      };
      const sharedState = () => {
        for (const key of Object.getOwnPropertySymbols(Function.prototype.toString)) {
          const value = Function.prototype.toString[key];
          if (value && value.shaped instanceof WeakSet) return value;
        }
        return null;
      };
      let state = sharedState();
      const mark = (fn) => {
        if (typeof fn !== 'function') return fn;
        if (!state) {
          const native = Function.prototype.toString;
          state = { shaped: new WeakSet() };
          const proxy = new Proxy(native, {
            apply(target, self, args) {
              if (state.shaped.has(self) || passkeyReplacement(self)) return shape(self);
              const result = apply(target, self, args);
              // Other engines fold the native marker onto its own lines; V8 keeps one line.
              return typeof result === 'string' && nativeShape.test(result)
                ? result.replace(/\s*\n\s*/g, ' ') : result;
            },
          });
          state.shaped.add(proxy);
          define(native, Symbol(), { value: state });
          define(Function.prototype, 'toString', {
            value: proxy, writable: true, enumerable: false, configurable: true,
          });
        }
        state.shaped.add(fn);
        return fn;
      };
      // Only a target that still carries its native function is ours to replace; a replacement of
      // ours (or one a page installed first) leaves the second injection with nothing to do.
      const unpatched = (object, key, accessor) => {
        if (!object) return null;
        const descriptor = describe(object, key);
        if (!descriptor) return null;
        const value = accessor ? descriptor.get : descriptor.value;
        if (typeof value !== 'function' || (state && state.shaped.has(value))) return null;
        return isNative(value) ? descriptor : null;
      };
      const replace = (object, key, descriptor, value, accessor) => {
        const details = { enumerable: descriptor.enumerable, configurable: descriptor.configurable };
        if (accessor) {
          details.get = value;
          if (descriptor.set) details.set = descriptor.set;
        } else {
          details.value = value;
          details.writable = descriptor.writable;
        }
        define(object, key, details);
      };

      // Engine 148 multiplies every non-empty text metric by `factor` instead of `1 + factor`.
      const proto = globalThis.TextMetrics && TextMetrics.prototype;
      if (proto && factor !== 0 && isFinite(factor)) {
        let broken = false;
        try {
          const probe = new OffscreenCanvas(1, 1).getContext('2d');
          probe.font = '18pt Arial';
          broken = abs(probe.measureText('Cwm fjordbank glyphs vext quiz').width) < 1;
        } catch (e) {}
        if (broken) {
          const natives = {};
          for (const key of ['width', 'actualBoundingBoxLeft', 'actualBoundingBoxRight',
            'fontBoundingBoxAscent', 'fontBoundingBoxDescent', 'actualBoundingBoxAscent',
            'actualBoundingBoxDescent', 'emHeightAscent', 'emHeightDescent', 'hangingBaseline',
            'alphabeticBaseline', 'ideographicBaseline']) {
            const descriptor = describe(proto, key);
            if (descriptor && typeof descriptor.get === 'function' && isNative(descriptor.get)
                && !(state && state.shaped.has(descriptor.get))) natives[key] = descriptor;
          }
          const width = natives.width && natives.width.get;
          const ascent = natives.fontBoundingBoxAscent && natives.fontBoundingBoxAscent.get;
          const descent = natives.fontBoundingBoxDescent && natives.fontBoundingBoxDescent.get;
          if (width && ascent && descent) {
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
            // Metrics are single-precision values; rounding back to one undoes it exactly.
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
              replace(proto, key, descriptor, mark(hooked), true);
            }
          }
        }
      }

      if (!fake && !priv && !link) return;

      if (fake) {
        const screenPrototype = globalThis.Screen && Screen.prototype;
        if (fake.screen && screenPrototype) {
          for (const key of ['width', 'height', 'availWidth', 'availHeight', 'availLeft', 'availTop', 'colorDepth', 'pixelDepth']) {
            const value = fake.screen[key === 'pixelDepth' ? 'colorDepth' : key];
            if (value === undefined) continue;
            const descriptor = unpatched(screenPrototype, key, true);
            if (!descriptor) continue;
            const getter = describe({
              get [key]() {
                if (!(this instanceof Screen)) throw new TypeError('Illegal invocation');
                return value;
              },
            }, key).get;
            replace(screenPrototype, key, descriptor, mark(getter), true);
          }
        }

        if (fake.dpr !== undefined) {
          const descriptor = unpatched(globalThis, 'devicePixelRatio', true);
          if (descriptor) {
            const value = fake.dpr;
            const getter = describe({ get devicePixelRatio() { return value; } }, 'devicePixelRatio').get;
            replace(globalThis, 'devicePixelRatio', descriptor, mark(getter), true);
          }
        }

        const navigatorPrototype = globalThis.Navigator && Navigator.prototype;
        if (navigatorPrototype && fake.deviceMemory !== undefined) {
          const memory = fake.deviceMemory;
          const descriptor = unpatched(navigatorPrototype, 'deviceMemory', true);
          if (descriptor) {
            const getter = describe({
              // Like the native getter, which is secure-context only.
              get deviceMemory() { return globalThis.isSecureContext ? memory : undefined; },
            }, 'deviceMemory').get;
            replace(navigatorPrototype, 'deviceMemory', descriptor, mark(getter), true);
          }
        }
        if (fake.touch !== undefined) {
          const points = fake.touch ? 5 : 0;
          const getter = mark(describe({ get maxTouchPoints() { return points; } }, 'maxTouchPoints').get);
          const targets = [navigatorPrototype, globalThis.WorkerNavigator && WorkerNavigator.prototype];
          for (const target of targets) {
            const descriptor = unpatched(target, 'maxTouchPoints', true);
            if (descriptor) replace(target, 'maxTouchPoints', descriptor, getter, true);
          }
        }
        // A touch identity also has to be able to build touch events.
        if (fake.touch === true) {
          const page = globalThis.document;
          if (page) {
            if (typeof globalThis.Touch !== 'function') {
              const Touch = mark(function Touch(init) {
                if (!(this instanceof Touch)) {
                  throw new TypeError("Failed to construct 'Touch': Please use the 'new' operator.");
                }
                const given = init || {};
                for (const key of ['identifier', 'target', 'clientX', 'clientY', 'pageX', 'pageY',
                  'screenX', 'screenY', 'radiusX', 'radiusY', 'rotationAngle', 'force']) {
                  define(this, key, { value: given[key] === undefined ? (key === 'target' ? null : 0) : given[key],
                    enumerable: true, configurable: true });
                }
              });
              define(globalThis, 'Touch', { value: Touch, writable: true, enumerable: false, configurable: true });
            }
            if (typeof globalThis.TouchEvent !== 'function') {
              const base = globalThis.UIEvent || globalThis.Event;
              const TouchEvent = mark(function TouchEvent(type, init) {
                if (!(this instanceof TouchEvent)) {
                  throw new TypeError("Failed to construct 'TouchEvent': Please use the 'new' operator.");
                }
                let event;
                try { event = base ? new base(type, init) : { type: String(type) }; } catch (e) { event = { type: String(type) }; }
                Object.setPrototypeOf(event, TouchEvent.prototype);
                const touches = (init && init.touches) || [];
                define(event, 'touches', { value: touches, enumerable: true, configurable: true });
                define(event, 'targetTouches', { value: (init && init.targetTouches) || touches,
                  enumerable: true, configurable: true });
                define(event, 'changedTouches', { value: (init && init.changedTouches) || [],
                  enumerable: true, configurable: true });
                return event;
              });
              TouchEvent.prototype = Object.create(base ? base.prototype : Object.prototype);
              define(globalThis, 'TouchEvent', { value: TouchEvent, writable: true, enumerable: false, configurable: true });
            }
            const found = (() => {
              for (let owner = page; owner; owner = Object.getPrototypeOf(owner)) {
                const descriptor = describe(owner, 'createEvent');
                if (descriptor) return { owner, descriptor };
              }
              return null;
            })();
            const descriptor = found && unpatched(found.owner, 'createEvent', false);
            if (descriptor) {
              let available = false;
              try { available = apply(descriptor.value, page, ['TouchEvent']) instanceof globalThis.TouchEvent; } catch (e) {}
              if (!available) {
                const native = descriptor.value;
                const create = mark({
                  createEvent(name) {
                    if (String(name) === 'TouchEvent') return new globalThis.TouchEvent('');
                    return apply(native, this, arguments);
                  },
                }.createEvent);
                replace(found.owner, 'createEvent', descriptor, create, false);
              }
            }
          }
        }
        // Desktop Chromium carries no own ontouchstart at all: a touch identity adds one, a
        // non-touch one drops what a touch-enabled host left behind.
        if (fake.touch === true && !describe(globalThis, 'ontouchstart')) {
          // A page that assigns a handler must read it back, as a real touch browser does.
          let assigned = null;
          const handler = describe({
            get ontouchstart() { return assigned; }, set ontouchstart(value) { assigned = value ?? null; },
          }, 'ontouchstart');
          define(globalThis, 'ontouchstart', {
            get: mark(handler.get), set: mark(handler.set),
            enumerable: true, configurable: true,
          });
        } else if (fake.touch === false) {
          const descriptor = describe(globalThis, 'ontouchstart');
          if (descriptor && descriptor.configurable) delete globalThis.ontouchstart;
        }
      }

      // The engine reports the host's connection; a Profile's exit can differ from it.
      if (link) {
        const navigatorPrototype = globalThis.Navigator && Navigator.prototype;
        if (navigatorPrototype) {
          let information = globalThis.NetworkInformation ? NetworkInformation.prototype : null;
          if (!information && globalThis.navigator && navigator.connection) {
            information = Object.getPrototypeOf(navigator.connection);
          }
          // No interface to extend: a private prototype still keeps the values off the instance.
          if (!information) information = {};
          const install = (key) => {
            const descriptor = describe(information, key);
            if (descriptor && !unpatched(information, key, true)) return;
            const getter = describe({ get [key]() { return link[key]; } }, key).get;
            if (descriptor) replace(information, key, descriptor, mark(getter), true);
            else define(information, key, { get: mark(getter), enumerable: true, configurable: true });
          };
          for (const key of ['effectiveType', 'rtt', 'downlink', 'saveData']) install(key);
          if (!describe(navigatorPrototype, 'connection') || unpatched(navigatorPrototype, 'connection', true)) {
            let instance;
            const getter = describe({
              get connection() {
                if (!instance) instance = information ? Object.create(information) : {};
                return instance;
              },
            }, 'connection').get;
            const descriptor = describe(navigatorPrototype, 'connection');
            if (descriptor) replace(navigatorPrototype, 'connection', descriptor, mark(getter), true);
            else define(navigatorPrototype, 'connection', { get: mark(getter), enumerable: true, configurable: true });
          }
        }
      }

      // An incognito window gets a quota tied to the JS heap instead of the disk.
      if (priv) {
        const quota = (value) => {
          const real = value || {};
          let heap = 0;
          try {
            heap = (globalThis.performance && performance.memory && performance.memory.jsHeapSizeLimit) || 0;
          } catch (e) {}
          if (!heap && fake && fake.deviceMemory) heap = fake.deviceMemory * 536870912;
          if (!heap) heap = 1073741824;
          const limit = Math.max(0, Math.min(typeof real.quota === 'number' ? real.quota : 0,
            Math.floor(heap * 1.5)));
          const usage = Math.max(0, Math.min(typeof real.usage === 'number' ? real.usage : 0, limit));
          const result = { usage, quota: limit };
          if (real.usageDetails !== undefined) result.usageDetails = real.usageDetails;
          if (real.quotaDetails !== undefined) result.quotaDetails = real.quotaDetails;
          return result;
        };
        // about:blank has an opaque origin and rejects; zero reads as an incognito window.
        const manager = globalThis.StorageManager ? StorageManager.prototype
          : (globalThis.navigator && navigator.storage && Object.getPrototypeOf(navigator.storage));
        const estimateDescriptor = unpatched(manager, 'estimate', false);
        if (estimateDescriptor) {
          const native = estimateDescriptor.value;
          const estimate = mark({
            async estimate() {
              try {
                return quota(await apply(native, this, []));
              } catch (error) {
                return { usage: 0, quota: 0 };
              }
            },
          }.estimate);
          replace(manager, 'estimate', estimateDescriptor, estimate, false);
        }
        const temporary = globalThis.navigator && navigator.webkitTemporaryStorage;
        const storagePrototype = temporary && Object.getPrototypeOf(temporary);
        const queryDescriptor = unpatched(storagePrototype, 'queryUsageAndQuota', false);
        if (queryDescriptor) {
          const native = queryDescriptor.value;
          const query = mark({
            queryUsageAndQuota(success, failure) {
              const report = (usage, granted) => {
                const capped = quota({ usage, quota: granted });
                if (typeof success === 'function') success(capped.usage, capped.quota);
              };
              try {
                apply(native, this, [report, (error) => {
                  if (typeof success === 'function') success(0, 0);
                  else if (typeof failure === 'function') failure(error);
                }]);
              } catch (error) {
                report(0, 0);
              }
            },
          }.queryUsageAndQuota);
          replace(storagePrototype, 'queryUsageAndQuota', queryDescriptor, query, false);
        }
      }

      const nativeMatchMedia = globalThis.matchMedia;
      const matchMediaDescriptor = unpatched(globalThis, 'matchMedia', false);
      if (nativeMatchMedia && matchMediaDescriptor && fake
          && (fake.screen || fake.dpr !== undefined || fake.touch !== undefined)) {
        const size = fake.screen;
        const dpr = fake.dpr;
        const coarse = fake.touch === true;
        const feature = /^\(\s*(min-|max-)?(device-width|device-height|width|height|resolution)\s*:\s*(\d*\.?\d+)\s*(px|dppx|dpi)?\s*\)$/i;
        const pointerFeature = /^\(\s*(any-)?pointer\s*:\s*(fine|coarse|none)\s*\)$/i;
        // `undefined` means the clause is outside the guard and the native answer decides.
        const evaluate = (query) => {
          let matches = true;
          for (const clause of query.split(/\s+and\s+/i)) {
            const trimmed = clause.trim();
            const pointer = pointerFeature.exec(trimmed);
            if (pointer) {
              const any = !!pointer[1];
              const wanted = pointer[2].toLowerCase();
              const ok = any ? wanted === 'fine' || (wanted === 'coarse' && coarse)
                : wanted === 'coarse' ? coarse : wanted === 'fine' ? !coarse : false;
              if (!ok) matches = false;
              continue;
            }
            const found = feature.exec(trimmed);
            if (!found) return undefined;
            const range = (found[1] || '').toLowerCase();
            const name = found[2].toLowerCase();
            const unit = (found[4] || '').toLowerCase();
            const value = parseFloat(found[3]);
            let actual;
            if (name === 'resolution') {
              if (unit === 'px' || typeof dpr !== 'number') return undefined;
              actual = unit === 'dpi' ? dpr * 96 : dpr;
            } else if (name === 'width' || name === 'height') {
              // A viewport query follows the real viewport, as CSS does.
              if (unit && unit !== 'px') return undefined;
              const viewport = name === 'width' ? globalThis.innerWidth : globalThis.innerHeight;
              actual = typeof viewport === 'number' ? viewport
                : name === 'width' ? size && size.width : size && size.height;
            } else {
              // A device query follows the claimed screen.
              if (!size || (unit && unit !== 'px')) return undefined;
              actual = name === 'device-width' ? size.width : size.height;
            }
            const ok = range === 'min-' ? actual >= value : range === 'max-' ? actual <= value
              : actual === value;
            if (!ok) matches = false;
          }
          return matches;
        };
        const matchMedia = mark({
          // An object-literal method, as a native built-in: no own prototype and not constructible.
          matchMedia(query) {
            if (arguments.length === 0) {
              throw new TypeError("Failed to execute 'matchMedia' on 'Window': 1 argument required, but only 0 present.");
            }
            if (this !== globalThis) throw new TypeError('Illegal invocation');
            if (typeof query === 'symbol') throw new TypeError('Cannot convert a Symbol value to a string');
            const text = String(query);
            const list = apply(nativeMatchMedia, globalThis, [text]);
            const answer = evaluate(text);
            const bound = new Map();
            // A proxy over the native list: values come from the trap, nothing becomes an own key,
            // and methods (addEventListener) are handed out bound to the real target.
            return new Proxy(list, {
              get(target, key) {
                if (key === 'matches') return answer === undefined ? target.matches : answer;
                if (key === 'media' || key === 'query') return text;
                const value = Reflect.get(target, key, target);
                if (typeof value !== 'function') return value;
                if (!bound.has(value)) bound.set(value, value.bind(target));
                return bound.get(value);
              },
            });
          },
        }.matchMedia);
        replace(globalThis, 'matchMedia', matchMediaDescriptor, matchMedia, false);
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
