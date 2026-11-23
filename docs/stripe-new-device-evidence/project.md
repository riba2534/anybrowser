# AnyBrowser 现状与缺口审计（只读源码）

对象：`/Users/riba2534/airepo/anybrowser`（只读；未改仓库）。引擎：内置 Fingerprint Chromium `148.0.7778.215`。审计日期：2026-11-23。
外部 JS 只做文本读取，没有执行 Stripe bundle。引擎探针只执行本审计自写的 `data:`/本地 HTML，用 `/Applications/AnyBrowser.app` 自带 Chromium。

---

## 0. 结论摘要

1. **默认新建 Profile 在 Stripe 的 15 个特征里，真正会变的只有 `o` Canvas 与 `k` 无关的 GPU/内存/CPU 派生项。** `f` 屏幕、`j` 字体、`h` 触摸、WebGPU、语音列表全部是宿主 Mac 值，所有 Profile 完全一样；`l` UA 与 `d` platform 又统一固定在同一个引擎 148 版本。房子是“同一台 Mac 换了一张 canvas”。
2. **`f` 是最大缺口，而且是三层缺口叠加**：`screenWidth/Height/deviceScaleFactor` 有字段、有参数、有单测，但采样器根本不填（`IdentitySampler.swift:25-28,128-131,166-176`），就算手工填了引擎也不认（本审计实测）；`availWidth/Height/colorDepth` 连引擎开关都不存在，字段永远只进校验和 JSON。Stripe 的 `ScreenSizeExtractor` 恰好只读 `availWidth/availHeight/colorDepth/devicePixelRatio`。
3. **`j` 字体是第二缺口**：字体表字段只是愿望值，`.font` 默认关、字段随机化对非 macOS 永不重新打开，引擎的 font 开关只是按 seed 翻转宿主 macOS 的 55 位串。默认 macOS 身份同平台尚可，跨 Profile 完全相同；Windows 身份则是教科书级 macOS 签名。
4. **重置链路本身做得对**：种子/平台变化会清站点数据（含 `__stripe_mid`、`m.stripe.com` 的 httpOnly `m`、CHIPS 分区 cookie），有单测。**但 Cookie 导入/导出和备份恢复完全不识别 Stripe 设备 cookie**：导入一份旧 jar、恢复一份旧备份，会把旧 `__stripe_mid`/`m` 原样带回新身份；`adoptOrphan` 甚至用新身份直接接管旧资料目录且不标重置。
5. **b 上下文没有被污染，但有注入痕迹**：`Object.keys(navigator)` 仍为 `[]`、`Object.keys(document)` 仍为 `["location"]`，`chrome.runtime` 不暴露（实测）。痕迹在于两个默认加载的 MAIN-world 扩展会把 `TextMetrics.prototype` getter 和 `navigator.credentials` 方法换成非 native 源码；Stripe 这一版不查 `toString`，其他欺诈面会查。
6. 其它真实性问题：`deviceMemory` 只会是 8/16/32（规范上限 8）；`touch` 字段是死字段；所有 Profile 默认共用 `127.0.0.1:7890`；SelfCheck 不覆盖 a/b/e/h/i/j/n、字体向量、Object.keys、`deviceMemory>8`，屏幕只比 width/height。

**一句话**：这不是“实现坏了”，而是“实现到一半就停在了最有用的地方”。Canvas/GPU/内存/CPU 的种子派生是合格的；屏幕、字体、共享出口与 cookie 身份链是不合格的。按下面 P0→P2 补齐之前，Stripe 只能把新 Profile 当成“同一台 Mac 上新开的一个浏览器配置”，而不是一台新设备。

---

## 1. 判定图例

- **已正确实现**：行为符合 Stripe 读取语义，跨 Profile 也不共享（或共享是真实浏览器的正常行为）。
- **已接线但值不真实**：参数/字段确实生效，但产生的是宿主值或低熵合成值，跨 Profile 共享。
- **有开关未接线**：字段、参数、校验、甚至单测存在，但生产路径不填或引擎不认。
- **完全缺失**：没有字段、没有开关、没有行为。
- **有注入痕迹风险**：值本身可能对，但页面可通过 `toString`/自有属性/全局键等发现被改写。

---

## 2. Stripe 15 特征 × 现状覆盖矩阵

证据中的“探针”见 §6，全部为只读运行。

| # | 特征 | 判定 | 现状与证据 | 对“像一台新设备”意味着什么 | AnyBrowser 该做什么 |
|---|---|---|---|---|---|
| a | CookieSupport | 已正确实现 | 无任何代码改 `navigator.cookieEnabled`；默认 Profile 不设 Cookie 内容策略，恒 `true`（抓包 `/tmp/stripe-recon/font-off.json` `cookieEnabled:true`） | 所有 Profile 都是正常的 `true`，真实设备也如此 | 仅补 SelfCheck 断言 `true` |
| b | DoNotTrack | 已正确实现 | 引擎原生 `navigator.doNotTrack=null` → Stripe 记 `"false"`；无 DNT 开关（`Profile.swift:353-402` 无相关参数） | 正常；若以后加 DNT 开关必须同时改 HTTP 头 | 可留空；补 SelfCheck |
| c | Language | 已接线但值不真实 | `--lang` + `--accept-lang=<tag,base>`（`Profile.swift:370-373`；`--accept-lang` 另有 `-AppleLanguages`，`:398-400`）。语言来自 12 条固定目录（`IdentitySampler.swift:144-157`，`en-US` 权重 30），列表恒为 2 段（`:118-121`）。UI/API 新建时会按出口覆盖（`Workbench.swift:409-435`；`AutomationAPI.swift:637-660`），失败则保留随机值 | 同一出口下大量 Profile 得到同一 `en-US,en`；只比 `languages[0]` 的 Stripe 看不出来，但跨 Profile 低熵，且目录里没有小语种/多语真实分布 | 扩充目录与权重；出口查询失败时阻止保存或显式标记；语言列表加入真实常用 fallback；启动时再核对出口并告警 |
| d | Platform | 已正确实现 | `--fingerprint-platform`（`Profile.swift:355-357`），预设固定平台（`IdentityPresets.swift:20-33`） | 默认全 macOS，与宿主一致 | 保持；给非 macOS 补一致性的硬门禁 |
| e | Plugins | 已正确实现 | 引擎固定 5 条 PDF 插件，应用无干预；抓包 `font-off.json` 与 Chrome 158 完全一致 | 桌面 Chrome 的正常值 | 加插件表快照测试 |
| f | ScreenSize（`availWidth/availHeight/colorDepth/devicePixelRatio`） | **width/height/DPR：有开关未接线；avail/colorDepth：完全缺失** | 字段 `Profile.swift:98-103`；参数 `:377-385`；但采样器 `screenSpoofingSupported=false`（`IdentitySampler.swift:128-131`），`sample()` 的屏幕块被跳过（`:166-176`），单测明文写着“引擎忽略屏幕开关”（`IdentitySamplerTests.swift:25-28,59,86`）。`availWidth/Height`、`colorDepth` 只在校验/一致性里出现（`Profile.swift:444-464`、`FingerprintConsistency.swift:152-166`），`arguments()` 从不产出。**本审计实测**：`--fingerprint-screen-width=1920 --fingerprint-screen-height=1080 --fingerprint-device-scale-factor=1` 在 headless 仍报 `800,600,800,600,24,1`；窗口模式前轮实测仍报宿主 `2560×1440/avail 2560×1410/DPR 2`（`docs/stripe-fingerprint-mock-plan.md:369`）。二进制确实有开关字符串（offset `226227466` screen-width、`226227491` screen-height、`226227517` device-scale-factor） | **所有 Profile 的 `f` 完全相同**；默认 macOS 身份还能靠宿主自洽，Windows 身份则是 `Win32 + Mac Retina avail/DPR` 的硬矛盾。Stripe 的 `f` 只读 avail*/colorDepth/DPR，正好全中缺口 | 引擎补丁覆盖 `screen.width/height/availLeft/avail*`、`colorDepth/pixelDepth`、`devicePixelRatio`（`screen.cc`/`ScreenMetricsEmulator`）；Swift 侧屏幕预设先恢复填充（`screenSpoofingSupported=true`）并用 InstalledEngineTests 断言 `avail*/colorDepth/DPR` 而不只是 width/height；引擎修好前加 `screen-host-shared` 提示 |
| g | TimeZoneOffset | 已正确实现 | `--timezone=<IANA>`（`Profile.swift:374-376`）；有 Intl 集成测试（`InstalledEngineTests.swift` 时区断言）；语言/时区成对抽样（`Profile.swift:536-541`）；DST 前轮实测正确 | 正常；每个 Profile 可有独立时区 | 保持；补 `Date.getTimezoneOffset()` 与出口的运行时断言 |
| h | TouchSupport | 有开关未接线 | `touch` 字段存在（`Profile.swift:107`），`sample` 写死 `false`（`IdentitySampler.swift:184`），`randomize` 在平台切换时也写 `false`（`Profile.swift:513`），但 `arguments()` 从不读它；`maxTouchPoints` 也无处理。宿主 Mac 恒 `false/0`，与本脚本期望的桌面 Mac 自洽；v3 主脚本读 `navigator.maxTouchPoints` | Mac 身份正确但所有 Profile 一样；Windows 触屏身份永远造不出来 | 引擎加 `--fingerprint-touch`/`maxTouchPoints` 或至少把 `touch` 接进参数；SelfCheck 断言 `ontouchstart` 与 `maxTouchPoints` |
| i | AvailableStorage | 已正确实现 | 原生 storage；未做 JS 沙箱、未删属性 | 正常 enabled | 补第三方 iframe 分区场景的回归 |
| j | Fonts（55 位串） | **已接线但值不真实** | `.font` 是 `--disable-spoofing` 的反向开关（`Profile.swift:387-392`），默认集合只有 `[.canvas,.clientRects]`（`:94`）；`sample()` 只加 `.audio`，不加 `.font`（`IdentitySampler.swift:186-189`）；`randomize` 只在“平台本来就是 macOS 且原来开着 font”时保留 `.font`（`Profile.swift:542-547`），因此新建/整套重生成永远是关。`fontProfile`（`windows11` 等）只能展示（`FingerprintCard.swift:163-165`），引擎没有平台字体表；打开后也只是按 seed 翻转宿主位。前轮实测 Windows 身份 font 开/关都仍含 Monaco/Helvetica 且缺 Segoe/Calibri（`docs/stripe-fingerprint-mock-plan.md:369`）；一致性命中会提示（`FingerprintConsistency.swift:172-180`） | **默认 macOS 身份 = 宿主 macOS 55 位串，跨 Profile 100% 相同**；`id` 仍不同（canvas 参与），但服务端按字体串聚类会把它们归为同一台 Mac。Windows 身份则同报文 `d/l` 与 `j` 直接冲突 | 引擎做“平台参考向量”字体表（按 FontProfile 返回参考机 55 位串，seed 只在同平台合法向量间选）；非 macOS 身份自动开 `.font`；加 55 位向量验收测试；macOS 身份也应按 seed 在若干真实 macOS 向量间选，不能全员共享一条 |
| k | GraphicsConfiguration | 已正确实现 | 该版本恒 `""`；WebGL/GPU 由 seed 派生且默认开（`Profile.swift:387-389`），但本 bundle 不读；Linux 强制关 GPU 并提示（`Profile.swift:387-389`、`FingerprintConsistency.swift:109-112`） | 本脚本无影响；同页其它 SDK 会读 WebGL，seed 派生是正确方向 | 保持；Linux 的 WebGL 泄露作为已知限制；别为了 k 做任何注入 |
| l | UserAgent | 已接线但值不真实 | `--fingerprint-brand[-version]` 生效（`Profile.swift:361-366`），默认预设为 Chrome（`IdentityPresets.swift:20-33`）；引擎 148，Stable 已 159（`EngineFreshness` 会提示 ≥2 版本，`FingerprintConsistency.swift:87-91`）；抓包 UA 为 `Chrome/148.0.0.0`、UA-CH `Google Chrome 148`（`/tmp/stripe-recon/signup-capture.json`） | 值本身是自洽的 macOS Chrome，但所有 Profile 共享同一旧版本，且 TLS/JA3 也相同；这是“同一台机器”的强证据 | 升级引擎并跟进 Stable；升级时同步预设/品牌版本/测试；保持 `brand=.chrome` 的默认 |
| m | FlashVersion | 已正确实现 | 引擎无 Flash，mimeTypes 固定表不含 flash → `""`；未注入 `ActiveXObject` | 正常 | 保持；加快照 |
| n | HasAdBlocker | 已正确实现 | 原生 DOM bait + `sessionStorage._ab`；应用不隐藏该元素。PasskeyBox 只在 passkey 交互时插一个无 id 的 custom element（`content.js:275,329-336`），不影响 bait | 默认 `false`，正常 | 加 bait 元素回归测试，防止未来 UI/扩展误伤 |
| o | CanvasId | 已正确实现（稳定），但有启用面风险 | `.canvas` 默认开（`Profile.swift:94`），值由 engine seed 派生，前轮实测同 seed 跨启动一致、不同 seed 不同；无 JS 注入 | 新 Profile 的 canvas md5 唯一，是当前**唯一真正区分设备**的强特征；但用户手动关闭 canvas 后所有 Profile 会共享宿主 canvas | 保持默认开启；关闭时给一致性告警；InstalledEngineTests 增加跨 origin/iframe/重启的 md5 稳定性与跨 seed 不同断言 |

---

## 3. b 上下文与注入痕迹

| 项 | 判定 | 证据 | 影响 / 建议 |
|---|---|---|---|
| `b.f/g/h`（Audio 特性、ArrayBuffer、Array.from） | 已正确实现 | 引擎代际常量；前轮抓包 `false/true/true`（`/tmp/stripe-recon/font-off.json`） | 不要注入任何 polyfill |
| `b.i Object.keys(document)` | 已正确实现，无污染 | 前轮与本次实测均为 `["location"]`；两个默认扩展都不加 document expando；PasskeyBox 的 `passkey-box-ui` 无 id/name（`content.js:275,329-336`） | 以后若做 DOM 提示层，禁止 `id`/`name`；加 keys 基线快照 |
| `b.j Object.keys(navigator)` | 已正确实现，无污染 | 前轮与本次实测均为 `[]`；IdentityShim 改的是 `TextMetrics.prototype`（`IdentityShim.swift:142-153`），PasskeyBox 改的是 `CredentialsContainer.prototype`（`inject.js:252-275`），都不是 navigator 自有属性 | 任何“补字段”都别用 `Object.defineProperty(navigator, …, {enumerable:true})`；应走引擎 C++ |
| `b.n` 加载计时、`b.w` 时间戳 | 已正确实现 | 页面 JS 自行生成；`b.w` 依赖系统时钟 | 运维保证时钟同步；勿加 JS 包装层制造延迟 |
| `navigator.userAgentData` | 已正确实现 | 引擎/Args 驱动，抓包 brands 正常 | 保持 |
| `window` 上的 AnyBrowser 标记 | 新源码已正确，**已部署版本有残留** | 源码 `IdentityShim.swift:60-76` 无 marker；`/Applications` 里实际装的是 0.5.0 + shim `1.0.0`，会设 `Symbol.for('anybrowser.identityGuard')` 并保留 `config.js` 全局 `__ANYBROWSER_INTL__`；新源码会删除 `config.js`（`IdentityShim.swift:42-45`） | 发版时确认新 shim（1.1.0）替换旧目录；加“window 自有 string/symbol 属性无 anybrowser 标记”测试（现有 `IsolationProbeTests.swift:99-100` 覆盖） |
| `chrome` 对象 / `chrome.runtime` | 已正确实现 | 本次实测：MAIN-world content script 下 `typeof chrome` 为 object，`Object.keys` 仍为 stock `loadTimes,csi,app`，`chrome.runtime` 为 `no`（未声明 `externally_connectable`）；PasskeyBox manifest 只 `storage,tabs` | 保持；别加 `externally_connectable` |
| **IdentityShim 的 getter 源码** | **有注入痕迹风险** | `IdentityShim.swift:142-153` 用对象字面量 computed getter 再 `defineProperty` 到 `TextMetrics.prototype`。本审计实测 V8：原生 getter `Function.prototype.toString()` 为 `function get width() { [native code] }`，而该写法为 `get [key]() { … }`。`IsolationProbeTests.swift:107-118` 只断言 `measureText` 的 toString，未断言 getter 的 toString | Stripe 4.5.45 不查，`v3_plain.js`/`controller.js`/`shared.js` 也 0 次 `TextMetrics`；但通用 lie detector 会。给 hooked getter 安装 `toString` 返回 `function get width() { [native code] }`（注意别在 getter 自身留可枚举自有属性，native 的 own names 只有 `length,name`），或最终改成引擎修 measureText 并去掉扩展 |
| **PasskeyBox 的 WebAuthn 改写** | **有注入痕迹风险** | `inject.js:252-253` 换 `CredentialsContainer.prototype.create/get`；`:257-275` 把 `isUserVerifyingPlatformAuthenticatorAvailable` 恒 `true`、`isConditionalMediationAvailable` 恒 `true`、扩展 capabilities。本审计实测 `toString` 为 `create(options) { return intercept(…) }`，native 为 `function create() { [native code] }`，`enumerable` 保持 `true` | 本 bundle 不读 WebAuthn，`v3` 只读 `maxTouchPoints`；但 3DS2/hCaptcha/Link 会。给替换方法补 native 形 `toString`；麦克风/平台认证器能力按宿主真实值返回而不是恒 true；允许按 Profile 关闭 PasskeyBox（已有 `launch.loadPasskeyBox`，但默认开） |
| PasskeyBox 扩展 ID | 低风险 | manifest 内置公钥 `key` → 所有 AnyBrowser 安装/所有 Profile 共用同一扩展 ID；页面不能直接看 `chrome.runtime`，但已知 ID 可探测扩展资源 | 认知即可，不必改 |

---

## 4. 身份链审计

| 链路点 | 判定 | 证据 | 对“新设备”的含义 / 建议 |
|---|---|---|---|
| 新 Profile 种子 | 已正确实现 | `takenSeeds` 含回收站与不可读行（`ProfileStore.swift:262-266`）、DB `seed UNIQUE`（`:720-724`）、`makeDraft` 用 `newSeed(excluding:)`（`:268-273`）、`newSeed` 排除引擎不可能硬件（`Profile.swift:641-664`） | 每台“新设备”有独立 canvas/audio/clientRects/GPU(2 选 1)/内存(3 选 1)/CPU。这是目前的主要区分度来源 |
| 整套重新生成 | 已正确实现 | 换 seed、按出口取语言/时区、保存后标 pending reset 并删数据；停止态立即删、运行态重启时删（`LaunchCoordinator+Identity.swift:14-58`；`Workbench.swift:328-347,380-405`） | 是当前唯一“正确换设备”的入口；保持 |
| 手工改 seed 后启动 | 已正确实现 | 启动前询问“清/留站点数据”（`Workbench.swift:474-490`；`LaunchCoordinator.swift:212-223`）；`fingerprintChanged` 只看 seed/platform（`:162-165`），语言/品牌/屏幕改动不打扰 | 语义正确；但“留数据”会把旧 `__stripe_mid` 留在新 canvas 上，UI 只给一次通用提示 |
| 站点数据清除算法 | 已正确实现 | 停止态删整个 cookie DB、Local/Session Storage、IndexedDB（保留扩展）、Service Worker、Shared Storage、Trust Tokens、MediaDeviceSalts、cache（`BrowserRuntime+Data.swift:320-363`）；运行态按名全域删 `__stripe_mid/__stripe_sid` + 按域删 `m.stripe.com` 等 + 分区 cookie + 整 HTTP cache（`:67-97,297-311`）；有真实引擎测试（`RuntimeEngineTests.swift:124-146`、`CoordinatorEngineTests.swift:36-60`） | 算法覆盖了 Stripe 的 `m`（httpOnly，2 年锚点）和商家域 `__stripe_mid`，不是只清可见 cookie。保持，不要退化成只清 stripe 域 |
| **Cookie 导入/导出** | **完全缺失（身份感知）** | `exportCookies` 导出全部 cookie（`CookieTransfer.swift:100-106`），`importCookies` 全量回灌、同名同域覆盖（`:108-162`），两者都没有 `__stripe_mid/__stripe_sid/m` 的名字表或提示；UI（`Workbench+Cookies.swift:6-38`）与自动化（`AutomationAPI.swift:973-1000`）都没有选项 | 把旧 Profile 的一份 jar 导进“新设备”，Stripe 立刻按 `__stripe_mid`/`m` 认回老设备；canvas 却换了 → 漂移而不是新设备。应：导入时识别身份 cookie、给“保留/清除并当新设备”单选；或在文件摘要里列出 mi 值前缀与域 |
| **完整备份恢复** | 已接线但身份风险 | 备份保留 profile 的 fingerprint；`restore` 默认 `identity: .renew`（新 UUID），只有 seed 被占用时才换 seed（`ProfileBackup.swift:332,485-506`），然后整目录数据 + `Cookies.json` 原样放回（`:356-397,423-441`），**从不设置 `pendingIdentityReset`** | 同机恢复且 seed 未冲突 = 原设备，合理；seed 冲突时 = 新 canvas/GPU + 旧 `__stripe_mid/m`，且首启无 lastLaunchFingerprint，连提示都没有。应在 plan 里比较新旧 seed，若变化则 `setPendingIdentityReset(true)` 或在 UI 让用户选 |
| **`adoptOrphan`（接管孤儿资料目录）** | **完全缺失** | 新 UUID、`makeDraft()` 的全新身份 + 旧数据目录（`ProfileStore.swift:512-518`），不标重置、不记 launch fingerprint | 旧目录里的 mid/m 直接进入“新设备”；应默认标 pending reset（或恢复原 seed 若能从目录推断），并在 UI 说明 |
| Clone | 已接线但分离度弱 | 新 seed 仅“同硬件”（同一 GPU/内存/CPU 区间，`ProfileLibrary.swift:151-159`），proxy、locale、屏幕、字体、窗口全保持 | 复制出来的“新设备”除了 canvas/audio 与 `id` 外几乎全同，且是同一出口。若 clone 要当新设备，至少换出口或随机化 locale/屏幕预设 |
| 默认代理 / 出口 IP | 完全缺失（按 Profile 分流） | 默认值 `127.0.0.1:7890`（`Profile.swift:159,179`），`makeDraft` 不换（`ProfileStore.swift:268-273`），批量在没有显式 proxies 时逐个回落到默认值（`AutomationAPI.swift:750-753`） | 一批新 Profile 默认同一 IP，Stripe 先按 IP 聚合，再看到共享的字体/屏幕 → 强关联。应在批量新建默认从代理库分配不重复出口，或至少把“与 N 个 Profile 同出口”升级成警告 |
| WebRTC | 已正确实现（有代理时） | 有代理才传 `--webrtc-ip-handling-policy=disable_non_proxied_udp`（`Profile.swift:315-324`） | 空代理 Profile 的 STUN 会走真实网络；保持/加 leak 测试 |
| 宿主共享特征 | 完全缺失（区分） | 屏幕/DPR/colorDepth（见 §2 f）、字体（§2 j）、WebGPU 与语音（`FingerprintConsistency.swift:144-150`；`FingerprintCard.swift:83-88` 自认）、引擎/TLS 栈 | 同一台 Mac 上所有 Profile 在 Stripe 的 `f/j` 上完全一样。这是“新设备”的主要否决项，应作为 P0/P1 |
| 窗口几何 | 低风险 | 无 per-Profile 窗口尺寸来源；`LaunchOptions.window` 默认 nil（`LaunchOptions.swift:24,34-37`），`--window-size` 只在显式设置时传（`:140-147`）；窗口排版在启动后按宿主屏切（`WindowArrangement.swift`） | 本脚本不读 outer/inner；其它面会。可随屏幕预设一并给窗口尺寸 |
| `deviceMemory` 真实性 | 完全缺失（可控性） | 只由 seed 决定 `[8,16,32][seed%3]`（`EngineHardwareTable.swift:27-28,53-55,137`），字段只记录、不传（`Profile.swift:104-106,462`；`ProfileDraft.swift:77-79` 只跟随更新）；规范上限是 8，16/32 不可能 | 其它 Stripe 面/hCaptcha 会读 `navigator.deviceMemory`；应先限制到 8 或引擎加开关；同时 `Sec-CH-Device-Memory` 会跟着出错 |
| 语区熵 | 已接线但值不真实 | 12 条目录、`en-US` 合计权重 60/100（`IdentitySampler.swift:144-157`）；权重高的纽约/洛杉矶/芝加哥反复出现 | 大量 US Profile 共享同一语言时区组合；与共享屏幕/字体叠加后降低可分性。扩表并把出口作为唯一来源（失败则重试，不静默随机） |
| `__stripe_mid` 的可见性 | 完全缺失 | 除清理逻辑（`BrowserRuntime+Data.swift:311`）和测试外，没有任何 UI/API 展示当前 mid、`m`、属主域 | 无法人工验收“这台设备是否真的换了”。应在 Profile 详情给一个只读“Stripe 设备标识”区，或至少在清理摘要里报告删除了哪些值 |
| 回收站/还原 | 已正确实现 | seed 与数据随 Profile 保留，还原即原设备 | 与“新设备”不冲突；若用户期望新设备，用重生成 |

---

## 5. 现状实现细节核对（按文件）

### 5.1 `Profile.swift`

- `FingerprintSettings` 字段：`seed/platform/platformVersion/brand/brandVersion/cpuCount/language/timeZone/adjustments` 是实际参数面（`:85-113,353-402`）；`languages/screenWidth/screenHeight/availWidth/availHeight/colorDepth/deviceScaleFactor/deviceMemory/touch/fontProfile` 是扩展面（`:96-108`）。
- `arguments()` 产出：platform、platformVersion、brand、brandVersion、cpuCount、`--lang`、`--accept-lang`、`--timezone`、screenWidth、screenHeight、deviceScaleFactor、`--disable-spoofing`、`-AppleLanguages`（`:353-402`）。
- **不产出**：availWidth/availHeight、colorDepth、deviceMemory、touch（`grep` 全文仅校验/派生命中：`:444-464,509-513,578,596-603`）。
- `--disable-spoofing` 是反向表，列出“没开”的项；Linux 强制关 gpu（`:387-392`）。默认集合 `[.canvas,.clientRects]`（`:94`）。
- 代理参数与 WebRTC 策略（`:315-324`）；默认 proxy `127.0.0.1:7890`（`:159,179`）。
- `randomize`：语言/时区成对（`:536-541`）；字体只在“当前是 macOS 且原本开着”时保留（`:542-547`）；硬件最后收口、`keepsCPU` 时保证 GPU/CPU 组合存在（`:558-578`）。
- `validate`：屏幕 480–7680、可用 320–7680、色深 24/30、DPR 1–3、deviceMemory 1–8/16/32（`:439-464`）。校验存在不等于生效。
- `newSeed(excluding:)` 排除 `seed%6` 的不可能硬件组合（`:641-664`）。

### 5.2 `IdentitySampler.swift`

- 文档仍写“screen, language, time zone, font set is chosen here”（`:3-7`），但 screen 块 `if screenSpoofingSupported` 永远不执行（`:128-131,166-176`）。
- 默认预设只有 macOS 三条（`:126`），因此 UI 新建默认永远是 macOS——这掩盖了 Windows 身份的屏幕/字体矛盾，也让“新设备”全部顶着同一套 macOS 表面。
- `sample` 只加 `.audio`（`:188`），`touch=false`（`:184`），`fontProfile` 只是赋值（`:185`），然后 `adaptToPlatform`。
- 语言目录与权重（`:144-157`），`LocaleHint` 会清洗 exit 语言（`:30-67`）。

### 5.3 `FingerprintConsistency.swift`

已覆盖：品牌版本与内核、平台版本范围、Linux WebGL、Windows 无 GPU、无平台有 GPU、GPU/内存/CPU 组合、屏幕 avail>width、色深平台期望、字体表平台错配、字体无平台表、共享出口、时区/语言 vs 出口（`:61-204`）。
**未覆盖**：屏幕/DPR/colorDepth 与平台期望（因为字段常为 nil）、`deviceMemory>8`、touch 与平台、字体串跨 Profile 相同、屏幕跨 Profile 相同、Object.keys 基线、cookie 身份残留。全部是 hint，不阻止启动。

### 5.4 `FingerprintCard.swift` / 编辑器

- 只有 platform/version/brand/version/seed/CPU/language/timeZone 七类输入（`:110-134`），**没有屏幕、DPR、色深、设备内存、触摸输入**。
- 摘要里屏幕 `?? "跟随本机"`（`:154-159`）、字体 `宿主/待引擎`（`:163-165`）、内存取 table 值（`:166`）。
- 静态文案承认屏幕/色深/字体/语音/WebGPU 没有内核开关（`:83-88`），但又说有屏幕参数的 `arguments()`（`Profile.swift:377-385`）——文案停在“没有开关”，实际是“有开关、不生效、不采样”，容易让人以为已经覆盖。
- “整套重新生成”警示会清全站数据（`:100-107`），种子/语言/CPU/字体表都会换——字体表实际无引擎效果。

### 5.5 `IdentityShim.swift`

- 对 148/150 一律加载（`isNeeded=true`，`:23-25`），每次启动重写扩展（`:27-46`），manifest `all_frames/match_about_blank/match_origin_as_fallback/MAIN/document_start`（`:57-76`）。
- 脚本只在检测到 measureText 明显坏掉时启用（`:104-110`），只改 `TextMetrics.prototype` 的 getter（`:142-153`），`measureText` 保持 native。
- 无 marker、无全局；第二注入自动退出（`isNative` 检查）。
- 痕迹：hooked getter 的 `name/length/own/prototype` 都伪装成 native 形状（单测 `IdentityShimTests.swift:149-153`、`IsolationProbeTests.swift:110-115`），但 `Function.prototype.toString()` 是 `get [key]() { … }`（本次实测），没有伪装。

### 5.6 `PasskeyBox`（App 资源）

- 默认每个 Profile 加载（`ProfileExtensions.swift:45-48`；`launch.loadPasskeyBox` 默认 true，`LaunchOptions.swift:35`）。
- MAIN world `inject.js` 在安全上下文里重写 `CredentialsContainer.prototype.create/get` 和三个 `PublicKeyCredential` 静态方法（`inject.js:185,252-275`），能力位恒 true（`:167-171`）。无 marker、无 DOM。
- `content.js` 只在 passkey 流程中插 `passkey-box-ui` 自定义元素（`:275,329-336`），无 id/name。

### 5.7 数据清除与 Cookie

- `clearSiteData` 名字表与域名表（`BrowserRuntime+Data.swift:20-28,297-311`）；运行态删 cookie 带 partitionKey（`:71-82`）；磁盘态整文件/整目录删除（`:320-363`）。
- 测试覆盖 Stripe 身份 cookie（`RuntimeEngineTests.swift:130-142`、`CoordinatorEngineTests.swift:49-56`）。
- `CookieTransfer` 纯搬家，无身份语义（`:100-162,397-407`）；导出格式含 `expires/hostOnly/session` 等（`:352-395`）。
- 备份把 `Cookies.json` 与 Data 一起恢复（`ProfileBackup.swift:383-390`），Cookie 导入在恢复中重新 set（`:423-441`）。

### 5.8 SelfCheck

- 查：markers、platform/version、brand/version/edge、CPU、deviceMemory、WebGL、硬件组合、languages、locale、Date 时区名、timezone、exit timezone/language、screen(width/height)、measureText、两次 canvas 一致（`:199-361`）。
- 不查：cookieEnabled、doNotTrack、plugins/mimeTypes、storage、touch/maxTouchPoints、字体 55 位串、`Object.keys(document/navigator)`、`b.f/g/h`、`deviceMemory>8`、屏幕的 avail/DPR/colorDepth。
- 屏幕在未配置时是 `.info`，配置后只比 width/height（`:345-353`）——将来引擎只修 width/height 时自检会“全绿”，而 Stripe 读的 avail/DPR 仍错。

### 5.9 引擎开关事实

- 二进制存在：`disable-spoofing`(226227449)、`fingerprint-screen-width`(226227466)、`fingerprint-screen-height`(226227491)、`fingerprint-device-scale-factor`(226227517)、`fingerprint-hardware-concurrency`(226227549)；不存在 `fingerprint-color-depth`、`fingerprint-device-memory`、`fingerprint-touch`、`fingerprint-avail-width/height`。
- 本次实测：
  - 传 screen-width/height + DPR 1 或 2，headless 仍 `800,600,800,600,24,1`；
  - `--force-device-scale-factor=2 --window-size=1200,800` 时结果为 `screen 400×300, avail 400×300, colorDepth 24, DPR 2, inner 1200×679` —— **标准 force 开关能改 DPR，引擎的 fingerprint 开关不能**，但它会让 CSS 像素尺寸随缩放变化，仍不能指定任意屏幕；
  - `Object.keys(navigator)=[]`、`Object.keys(document)=["location"]`、`maxTouchPoints=0`、`ontouchstart` 不存在；
  - 原生 `TextMetrics.prototype.width` 的 getter toString 为 `function get width() { [native code] }`，对象字面量 computed getter 为 `get [key]() { … }`；
  - 加载 PasskeyBox 后 `CredentialsContainer.prototype.create.toString()` 为非 native，`Object.keys(navigator)` 仍 `[]`；加载 MAIN-world 探针扩展时 `chrome.runtime` 仍不可见。

---

## 6. 证据强度与未验证项

- **源码/单测**：全部路径都给出 `文件:行`，是一手证据。
- **引擎实测**：本审计在 `/tmp/ab-audit-probe/` 下用 `--headless=new --dump-dom` 跑自写页面；结果见 §5.9。窗口模式下“屏幕开关无效”引用前轮实测（`docs/stripe-fingerprint-mock-plan.md:369`），本轮未重跑窗口模式。
- **抓包**：`/tmp/stripe-recon/font-off.json`、`/tmp/stripe-recon/signup-capture.json` 引用了已有的真实报文，未重新抓包。
- **推断**：
  - 引擎为何暴露 screen 开关却不生效（可能 patch 只接了 `--fingerprint` 路径或只在特定 feature 下启用）——未查 C++ 源码；
  - `deviceMemory` 在 windowed secure context 的真实值——前轮 32/16，本轮 headless/data: 为 null（非 secure context），按前轮处理；
  - 新 shim 在真引擎内 getter toString 的最终形态由 V8 语义推断并用同构造写法实测，未在真 app 里跑新 shim；
  - Stripe 服务端是否用字体串/屏幕聚类——`findings/osint.md` 的推断，未验证。
- 已部署的 App 是 0.5.0、shim 1.0.0，比当前源码旧（源码 1.1.0，无 marker、无 config.js）。本审计以源码为准；部署漂移本身也要在发版时核对。

---

## 7. 优先级建议

### P0（不做则“新设备”不成立）

1. **引擎补屏幕与色深**：`screen.width/height/availLeft/availWidth/availHeight/colorDepth/pixelDepth/devicePixelRatio` 全部走 Profile 值；参数命名建议 `--fingerprint-screen-avail-width/height`、`--fingerprint-color-depth`。验收必须覆盖 Stripe 真正读的四个量。
2. **Swift 恢复屏幕采样**：`IdentitySampler.screenSpoofingSupported=true`，屏幕/DPR 与平台绑定（现有 `screenProfiles` 表：macOS 1728×1117@2/1512×982@2…，Windows 1920×1080@1/24…；见 `IdentitySampler.swift:240-263`），随机化屏幕字段并入 `FingerprintField`，编辑器补输入与摘要。
3. **Cookie 身份感知**：导入/备份恢复默认把 `__stripe_mid/__stripe_sid/m` 视作“设备身份”，给“保留设备/当新设备”二选一并默认按场景决定；导出摘要标注身份 cookie；`adoptOrphan` 与“恢复时换了 seed”标 `pendingIdentityReset`。
4. **字体平台表**：引擎按 `FontProfile` 返回平台参考 55 位向量；非 macOS 身份自动开 `.font`；macOS 身份也按 seed 在多条真实 macOS 向量间选，消除跨 Profile 共享。

### P1

5. **出口分流**：批量新建默认消费代理库的不重复出口；同出口 Profile 的提示升级为保存/启动前警告；空代理的 WebRTC 策略与出口告警。
6. **SelfCheck 扩面**：a/b/e/h/i/j/n、字体 55 位串、`Object.keys` 基线、`maxTouchPoints`、`deviceMemory>8`、屏幕全字段（avail/DPR/colorDepth）。若字段未配置，屏幕应判定“宿主共享”而不是简单 info。
7. **注入痕迹清理**：IdentityShim hooked getter 装 native 形 `toString`（并保持 own names 仅 `length,name`）；PasskeyBox 的 `create/get/…` 同样处理，能力位按宿主真值；新 Profile 默认是否加载 PasskeyBox 做成显式选择。
8. **deviceMemory 归一到 ≤8**，或引擎加显式开关并同步 `Sec-CH-Device-Memory`。

### P2

9. 统一“设备新鲜度”概念：把 seed/platform 之外的屏幕、字体、出口也算进 `fingerprintChanged` 的提示（是否清数据仍由用户定），并提供一键“新设备”组合动作（新 seed + 新屏幕 + 新出口 + 清身份 cookie）。
10. 引擎升级到 150/Stable 并跟进预设、品牌版本、硬件表；补充 TLS/UA-CH/插件/字体向量快照。
11. 清理文档与 UI 旧说法（`IdentitySampler.swift:3-7`、`FingerprintCard.swift:83-88`），把“有开关但不生效”与“无开关”分开标注。

---

## 8. 附：可直接对照的判定表

| 维度 | 已正确实现 | 已接线但值不真实 | 有开关未接线 | 完全缺失 | 注入痕迹风险 |
|---|---|---|---|---|---|
| 15 特征 | a,b,d,e,i,k,m,n,o | c,j,l | f(width/height/DPR),h | f(avail/colorDepth) | — |
| b 上下文 | b.f/g/h,b.i,b.j,b.n,b.w | — | — | — | IdentityShim getter、PasskeyBox credentials、旧版 shim marker |
| 身份链 | 新 seed 唯一性、重生成、清除算法、手工改 seed 提示、WebRTC(有代理) | clone | — | cookie 导入/导出身份感知、备份恢复 seed 冲突、adoptOrphan、默认出口分流、宿主屏幕/字体/WebGPU/语音区分、mid 可见性 | — |