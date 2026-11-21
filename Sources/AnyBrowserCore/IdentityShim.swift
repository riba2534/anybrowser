import Darwin
import Foundation

/// A per-Profile MV3 content script that repairs two engine-148 behaviours until the
/// engine itself is patched:
///
/// * `CanvasRenderingContext2D.measureText` is multiplied by a near-zero seed factor,
///   so widths come back as 0.0008 or negative numbers. The script measures the real
///   width with a hidden span and rescales every native metric by `real / native`, which
///   keeps relative metrics and restores a plausible absolute width.
/// * Chromium's `--lang` changes navigator/HTTP language but leaves ICU on the Mac's
///   system locale. The script gives `Intl` and `toLocale*` the Profile's language.
///
/// Both checks are runtime-guarded: a fixed engine or a system locale that already
/// matches is left untouched.
enum IdentityShim {
    static func directory(in storage: URL, for id: UUID) -> URL {
        ProfileExtensions.root(in: storage, for: id).appendingPathComponent("IdentityShim", isDirectory: true)
    }

    /// Engine 148 has the broken `TextMetrics::Shuffle` factor; 150+ may fix it. The
    /// content script still checks at runtime, so a backported fix is harmless.
    static func isNeeded(for engineVersion: String) -> Bool {
        guard let major = engineVersion.split(separator: ".").first.flatMap({ Int($0) }) else {
            return false
        }
        return major < 150
    }

    static func prepare(for profile: BrowserProfile, in storage: URL) throws {
        try ProfileExtensions.prepareRoot(in: storage, for: profile.id)
        let target = directory(in: storage, for: profile.id)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)

        let files = [
            "manifest.json": Data(manifest.utf8),
            "config.js": Data(config(for: profile).utf8),
            "content.js": Data(script.utf8),
        ]
        for (name, data) in files {
            try PrivateFile.update(data, at: target.appendingPathComponent(name),
                                   failure: "无法写入身份一致性扩展。")
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: target.path) where files[name] == nil {
            try FileManager.default.removeItem(at: target.appendingPathComponent(name))
        }
    }

    private static func config(for profile: BrowserProfile) -> String {
        let language = profile.fingerprint.language.isEmpty
            ? (profile.fingerprint.languages?.first ?? "")
            : profile.fingerprint.language
        let object: [String: String] = language.isEmpty ? [:] : ["language": language]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return "globalThis.__ANYBROWSER_INTL__ = \(String(decoding: data, as: UTF8.self));\n"
    }

    static let manifest = """
    {
      "manifest_version": 3,
      "name": "AnyBrowser Identity Guard",
      "version": "1.0.0",
      "description": "Keeps Canvas text metrics and Intl defaults consistent with this Profile.",
      "minimum_chrome_version": "111",
      "host_permissions": ["<all_urls>"],
      "content_scripts": [{
        "matches": ["<all_urls>"],
        "all_frames": true,
        "match_about_blank": true,
        "run_at": "document_start",
        "world": "MAIN",
        "js": ["config.js", "content.js"]
      }]
    }

    """

    static let script = #"""
    (() => {
      const marker = Symbol.for('anybrowser.identityGuard');
      if (globalThis[marker]) return;
      globalThis[marker] = true;

      const config = globalThis.__ANYBROWSER_INTL__ || null;
      const language = config && typeof config.language === 'string' ? config.language : '';

      const nativeToString = (fn, name) => {
        try {
          Object.defineProperty(fn, 'toString', {
            value: () => 'function ' + name + '() { [native code] }',
            configurable: true,
          });
        } catch (e) {}
      };

      const canvas = globalThis.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
      if (canvas && typeof canvas.measureText === 'function') {
        let broken = false;
        try {
          const probe = document.createElement('canvas').getContext('2d');
          probe.font = '18pt Arial';
          const width = probe.measureText('Cwm fjordbank glyphs vext quiz').width;
          broken = !isFinite(width) || width <= 1;
        } catch (e) {}
        if (broken) {
          const nativeMeasure = canvas.measureText;
          const cache = new Map();
          const domWidth = (ctx, text) => {
            const key = ctx.font + '\u0000' + text;
            if (cache.has(key)) return cache.get(key);
            const root = document.documentElement || document.body;
            if (!root) return null;
            const span = document.createElement('span');
            span.style.cssText = 'all:initial;position:absolute;left:-99999px;top:0;visibility:hidden;white-space:pre;';
            span.style.font = ctx.font;
            span.textContent = text;
            root.appendChild(span);
            const width = span.getBoundingClientRect().width;
            span.remove();
            cache.set(key, width);
            if (cache.size > 4096) cache.delete(cache.keys().next().value);
            return width;
          };
          const keys = ['width', 'actualBoundingBoxLeft', 'actualBoundingBoxRight',
            'fontBoundingBoxAscent', 'fontBoundingBoxDescent', 'actualBoundingBoxAscent',
            'actualBoundingBoxDescent', 'emHeightAscent', 'emHeightDescent',
            'hangingBaseline', 'alphabeticBaseline', 'ideographicBaseline'];
          const wrap = (nativeFn) => function measureText(text) {
            const metrics = nativeFn.call(this, text);
            if (!text || !metrics || !isFinite(metrics.width) || metrics.width === 0) return metrics;
            let real;
            try { real = domWidth(this, text); } catch (e) { return metrics; }
            if (!real || !isFinite(real) || real <= 0) return metrics;
            const scale = real / metrics.width;
            if (!isFinite(scale) || scale === 0) return metrics;
            const proto = typeof TextMetrics === 'function' ? TextMetrics.prototype : Object.prototype;
            const out = Object.create(proto);
            for (const key of keys) {
              let value;
              try { value = metrics[key]; } catch (e) { continue; }
              if (typeof value === 'number' && isFinite(value)) {
                Object.defineProperty(out, key, { value: value * scale, enumerable: false, configurable: true });
              }
            }
            if (!Object.prototype.hasOwnProperty.call(out, 'width')) {
              Object.defineProperty(out, 'width', { value: real, enumerable: false, configurable: true });
            }
            return out;
          };
          canvas.measureText = wrap(nativeMeasure);
          nativeToString(canvas.measureText, 'measureText');
          const offscreen = globalThis.OffscreenCanvasRenderingContext2D && OffscreenCanvasRenderingContext2D.prototype;
          if (offscreen && typeof offscreen.measureText === 'function') {
            offscreen.measureText = wrap(offscreen.measureText);
            nativeToString(offscreen.measureText, 'measureText');
          }
        }
      }

      if (language) {
        let nativeLocale = '';
        try { nativeLocale = new Intl.DateTimeFormat().resolvedOptions().locale; } catch (e) {}
        const same = nativeLocale === language || nativeLocale.startsWith(language + '-') || language.startsWith(nativeLocale + '-');
        if (!same) {
          const wrapIntl = (name) => {
            const Native = Intl[name];
            if (typeof Native !== 'function') return;
            const Wrapped = function (locales, options) {
              if (locales === undefined || locales === null || (Array.isArray(locales) && locales.length === 0)) locales = language;
              return new Native(locales, options);
            };
            Wrapped.prototype = Native.prototype;
            for (const key of Object.getOwnPropertyNames(Native)) {
              if (key === 'prototype' || key === 'length' || key === 'name') continue;
              try { Object.defineProperty(Wrapped, key, Object.getOwnPropertyDescriptor(Native, key)); } catch (e) {}
            }
            Object.defineProperty(Wrapped, 'name', { value: name, configurable: true });
            Object.defineProperty(Wrapped, 'length', { value: Native.length, configurable: true });
            nativeToString(Wrapped, name);
            try { Object.defineProperty(Intl, name, { value: Wrapped, configurable: true, writable: true }); } catch (e) {}
          };
          for (const name of ['DateTimeFormat', 'NumberFormat', 'Collator', 'PluralRules', 'RelativeTimeFormat', 'ListFormat', 'DisplayNames', 'Segmenter']) {
            wrapIntl(name);
          }
          const wrapMethod = (proto, name) => {
            const native = proto[name];
            if (typeof native !== 'function') return;
            const Wrapped = function (locales, options) {
              if (locales === undefined) locales = language;
              return native.call(this, locales, options);
            };
            proto[name] = Wrapped;
            nativeToString(Wrapped, name);
          };
          for (const name of ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString']) wrapMethod(Date.prototype, name);
          wrapMethod(Number.prototype, 'toLocaleString');
          if (globalThis.BigInt && BigInt.prototype) wrapMethod(BigInt.prototype, 'toLocaleString');
        }
      }
    })();
    """#
}
