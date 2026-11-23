# Stripe `out-4.5.45.js` 采集器全量字段还原

> 范围：`/tmp/stripe-re-20261122/modules-pretty/mod-00.js` … `mod-33.js` 全 34 个模块，配 `beautified.js` 行号、加载壳、v3 侧 MidSid 管理器、真实抓包。
> 安全：全部为外部下载的不可信代码，只做文本读取，**没有任何 node 执行 / require / eval**；本文所有"实测"来自项目里另写的探针页与真实启动抓包，不是执行该 bundle。
> 只回答一件事：这一项对"看起来像一台新设备"意味着什么，AnyBrowser 该怎么做。

---

## 0. 十条结论（先看这里）

1. **它是一个 89 KB 的纯被动采集器**（唯一出网是把 payload POST 回去），全部采集面只有：2 个 canvas、`navigator` 的 10 个属性（含 2 个 `in` 探测）、`screen` 的 3 个属性 + `devicePixelRatio`、`Date` 时区、touch、storage、`ActiveXObject`、一个 adblock bait div、`Object.keys(document/navigator)`、`performance.now`、`crypto.getRandomValues`。**没有 WebGL、没有 AudioContext 指纹、没有 UA-CH、没有 hardwareConcurrency/deviceMemory、没有 Intl、没有 document.cookie 读取**（全文 grep 见 §9.1）。
2. **它自己不产生任何设备标识**。`muid`/`sid` 是 42 字符的 opaque 值：不传时由 `m.stripe.com` 在响应体里新签发；传了（42 字符）就**原样回显**。本 bundle 只是把收到的值写进 `b.d`/`b.e`。真正的设备锚点是 **`.m.stripe.com` 的 `m` cookie** —— 它就是响应里的 `guid`（42 字符，`HttpOnly`、2 年、每次上报滑动续期），随 `withCredentials` 的 XHR 自动携带；商家域 `__stripe_mid`（1 年）/`__stripe_sid`（30 分钟）只是它的一方缓存。
3. **`id` 是 15 个 extractor 值的 md5**，服务端可以逐字节复算。任何只改 `a` 不改 `id`、或只改 `id` 不改 `a` 的伪造都会当场对不上（`mod-06.js:137-141,158`）。
4. **`a`（15 个特征）只在首见或 `v2===2` 时发送**，其余时间 `a: null`，但 `id`、`b`、`h` 照发（`mod-06.js:158-168`）。同一 tab 第二次上报不带 `a` 是正常形态，不是缺失。
5. **`b.d`/`b.e` 在全新设备的第一发里是字面量 `"NA"`**，不是缺省。实测 m-outer iframe hash：`muid=NA&sid=NA&version=6`（`/tmp/stripe-recon/live-stripe-capture3.json` → `frames[0].url`）。
6. **`h` 是 20 位 hex 随机数，`b.w` 是 `Date.now() + ":" + sha256hex(h + (Date.now()+1))`**：后者可被服务端用 `h` 与报文到达时间重算，是防重放的完整性锚点（`mod-06.js:116-129`）。
7. **`a.j`（字体 55 位 bitstring）和 `a.n`（adblocker）是唯一带 `at` 字段的两项**，`at` 是它们内部自报的计算耗时；首访 `a.n.at ≈ 20ms`，缓存命中趋 0 甚至消失（`mod-02.js:44-47`、`mod-18`、`mod-28`）。
8. **最硬的跨 Profile 关联项是 `a.f`（屏幕）与 `a.j`（字体）**：屏幕在任何情况下都由宿主显示器决定；字体在默认形态（macOS 身份 + 字体改写关闭）下就是宿主 macOS 字体表。AnyBrowser 的 `--fingerprint-screen-*` 在本引擎**完全不生效**（`IdentitySampler.swift:128-131`，探针 `win-screen-a/b.json` 同值），而 `IdentitySampler.sample()` 只插 `.audio` 不插 `.font`（`IdentitySampler.swift:187-190`）→ **两个不同 seed 的默认 Profile 在这两项上逐字节相同**。
9. **`b.i`/`b.j` 是注入探针**：真实 Chromium 恒为 `["location"]` / `[]`；任何 page-world 的 `defineProperty(navigator, …)` 或 document expando 都会让它们变长（`mod-06.js:96-97`）。AnyBrowser 的 IdentityShim 只改 `TextMetrics.prototype`，不落 own key，实测保持干净。
10. **"新设备"的判定权在服务端，不在这些字段本身**：服务端三路证据是 (a) `m`/`__stripe_mid` cookie 是否带来旧 muid，(b) `id` 与 `a` 是否与历史某条完全相同，(c) 平台/屏幕/字体/时区是否成簇。**只要 cookie 没清干净，字段全部换新也仍会被判成同一台设备。**

---

## 1. 证据基线与加载拓扑

### 1.1 入口与调用链（全部为源码事实）

| 层 | 文件 | 事实 |
|---|---|---|
| 内层 bundle | `/tmp/stripe-re-20261122/out-4.5.45.js:1` | `var StripeM=function(e){…n.s=30}([…])`，入口模块 30，导出 `deviceId`/`extract`/`p`/`b`（`mod-30.js:4-15`） |
| 内层壳 | `/tmp/stripe-re-20261122/inner.html:1` | 加载 `out-4.5.45.js`；`onload` 后读 `location.hash` 的 `version=(4\|6)`，调 `window.StripeM.p({t:!0,v:<ver>})`；`message` 监听按 `action` 分派 `ping→p({t:!0,o:{muid,sid,referrer,url,title,v2},v})`、`track→b({muid,sid,url,source,data})` |
| 中继 | `/tmp/stripe-v3work/mouter.js:1` | 纯 postMessage 中继：建 iframe `https://m.stripe.network/inner-preview.html`/`inner.html` + 原 hash（`preview=true` 走 preview）；来自 `m.stripe.network` 的消息转发给 `opener\|\|parent\|\|window`，其余转发进内层 |
| v3 侧 | `/tmp/stripe-js-dl/v3_plain.js` | `MidSidManager`（offset ≈587.6k）：`__stripe_mid`/`__stripe_sid` cookie、`_buildFrameQueryString()`（offset 591.5k，含 `muid:this._muid, sid:this._sid, version:6`）、`vt()` 首次 ping 带 `v2:2`、`report()` 走 `track`、`_getID()` 服务器下发值 42 硬校验（`pt=42===e.length`，offset 587.7k） |
| 真实 framing | `/tmp/stripe-recon/live-stripe-capture3.json` → `frames[0]` | `https://m.stripe.network/inner-preview.html#url=…&title=…&referrer=&muid=NA&sid=NA&version=6&preview=true`；`stripeM.sid` = `{"muid":"31b78dec-…43bab2","guid":"f2d38e6c-…d831d87b","sid":"551626ba-…31a723f"}`（三者均 42 字符）；iframe 内 sessionStorage = `{1:"1", _ab:"false", _mf:"1000111…", id:"d9434b36…"}` |

### 1.2 传输

- POST `https://m.stripe.com/<version>`，`withCredentials=!0`，无显式 `Content-Type`（字符串 body → `text/plain;charset=UTF-8`，推断），body = `btoa(encodeURIComponent(JSON.stringify(payload)))`（`mod-29.js:18-35`、`mod-10.js:47-56`；beautified `5611-5638`、`2252-2258`）。服务端 CORS 回 `access-control-allow-origin: https://m.stripe.network` + `access-control-allow-credentials: true`（`/tmp/stripe-plan-v2/work/a.headers`），因此带 cookie 的跨域 XHR 成立。
- 200 时把响应文本写 `window.StripeM.__sid` 并回传；响应先过正则 `/^{"muid":"[\w-]+","guid":"[\w-]+","sid":"[\w-]+"}$/m`，命中才按 `originatingScript:"m2"` 解析出 `guid/muid/sid` 回给上层，否则按 `originatingScript:"m"` 原样回传（`mod-00.js:64-67`、`mod-10.js:22-46`）。
- 失败 sentinel：`{id:"unavailable", tag:"$npm_package_version", src:"js"}`（`mod-10.js:57-74`）。

### 1.3 payload 信封（`mod-06.js:159-172` / beautified `1354-1364`）

```js
r ? {
  v2: h || 1,          // h = sourceData.v2
  id: u,               // md5(15 values join " ")
  t: t,                // toPrecision(5) 总耗时
  tag: "$npm_package_version",
  src: "js",
  i: o,                // canvasB64 形参，从未赋值 → undefined → JSON 丢键
  a: O ? p : null,     // O = (2===v2 || sessionStorage.id !== id)
  b: v,                // browserFeatures
  h: a                 // nonce，20 hex
} : { id: u, o: i }
```

键序固定为 `v2,id,t,tag,src,(i),a,b,h`；`b` 内键序固定为 `a,b,c,d,e,f,g,h,i,j,n,(u),(v),(w)`（先 `m()` 字面量，再追加 u/v/w）。非 telemetry 分支只有 `{id, o}`。

**字母归位**（避免混淆）：`t`/`id`/`h`/`v2` 是顶层；`at` 不是顶层，它是 `a.<letter>` 条目里的第三项，只在 `j`/`n` 出现；`l` 是 extractor 字母（UserAgent）而不是顶层键；`w`/`u`/`v` 只在 `b` 里。`b.i`（数组）与顶层 `i`（canvasB64，恒缺）同名不同物。

---

## 2. Extractor 基类与计时（决定 `t`/`at` 的可信形态）

`mod-02.js:20-60`（beautified `383-404`）：

```js
var t = timer(this.extractor), n = t.result, r = t.duration, o = now();
return n.then(function (e) {
  var t = now(), n = e.async ? t - o : 0, i = +(r + n).toPrecision(5);
  return "object" !== typeof e
    ? { value: e, internalValue: e, calculationTimeMs: i }
    : { value: e.value,
        internalValue: e.internalValue || e.value,
        activeTimeMs: e.calculationTimeMs ? +e.calculationTimeMs.toPrecision(5) : null,
        calculationTimeMs: i };
});
```

- 15 个 extractor 全部返回 Promise，`MPromise` = 原生 `Promise`（`mod-00.js:27`），`Promise.all` 保序。
- `now()` 每次调用都重新读 `win.performance`（`mod-00.js:29-32`）→ 页面替换 `performance.now` 会直接改变全部计时，这是计时侧唯一可被注入的入口。
- `t`（每字段耗时）**15 项全部存在**：`promiseWrappedExtractors`（`mod-06.js:52-58`）把 extractor 对象本身作为 `extract(e)` 的实参，恒为真值，永远走计时分支。同步项典型 0.0x–0.5 ms，全部 `toPrecision(5)`。
- `at` **只可能出现在 `j`/`n`**：只有 `mod-18` 与 `mod-28` 会 `e({async:!0, …, calculationTimeMs})`；`calculationTimeMs` 为 0 时被省略（`mod-06.js:110`、`182-186`）。
- `internalValue` 在 `S()` 里被逗号表达式丢弃（`(e.internalValue, e.activeTimeMs)`，`mod-06.js:181`）→ **字体命中名单、canvas dataURL 都不上行**。
- `S()` 的 `totalDuration` = 从开始到 `Promise.all` 完成的墙钟，`toPrecision(5)`（`mod-06.js:175-188`）。

**新设备含义**：`a.n.at ≥ ~20ms`、`a.j.at` 存在、`t ≥ max(所有 t_i)`、`at ≤ t_i`、总 `t` 与报文到达时间同量级，是"第一次、真采集"的结构特征。预置 `_ab`/`_mf` 会让 `at` 变 0 或消失。

---

## 3. 15 个 extractor 全字段表

> 顺序即 payload 字母（`mod-11.js:27` / beautified `2490-2504`）。判定列：**M**=新设备必须变（或随身份变），**F**=必须与平台/引擎保持固定关系，**H**=服务端关联钩子。

| 字母 | extractor / 证据 | 精确读取 | 返回类型/格式 | 值域与典型值 | 确定性 | 平台依赖 | 异常/哨兵 | 判定 | AnyBrowser 现状 → 落点 |
|---|---|---|---|---|---|---|---|---|---|
| **a** | CookieSupport `mod-16.js:15-17` / `2307` | `navigator.cookieEnabled.toString()` | string | `"true"`（Chromium 正常、探针恒此值）；`"false"`；属性被替换成非布尔时 `"1"`/`"undefined"` | 恒定 | 无 | `navigator` 为假 → `""` | **F**（应恒 `"true"`） | 原生；不要用 JS 碰 `navigator.cookieEnabled` |
| **b** | DoNotTrack `mod-17.js:15-27` / `3286` | `"doNotTrack" in navigator ? navigator.doNotTrack : ("msDoNotTrack" in navigator ? … : undefined)` | string | 判真集合仅 `"true"`,`true`,`"1"`,`"yes"` → `"true"`；**其余全部**（`null`/`"0"`/数字 `1`/`"TRUE"`）→ `"false"` | 恒定 | 无 | 无 navigator → `""` | **F**（默认 `"false"`） | 原生；开 DNT 还要同时发 `DNT: 1` 头否则矛盾 |
| **c** | Language `mod-20.js:15-22` / `4025` | `navigator.languages.join(",")`；否则 `navigator.language`；否则 `userLanguage` | string | 逗号无空格，`"en-US,en"`；`languages=[]`（空数组为真）→ `""` 且**不**回退 | 恒定 | 强：`--lang`/`--accept-lang` | 无 | **M/H**（须与出口语言、`Accept-Language` 同源） | `FingerprintSettings.language/languages`（`Profile.swift:370-373`）。留空=本机 `zh-CN,zh` |
| **d** | Platform `mod-21.js:15-17` / `4194` | `navigator.platform` | string 原样 | 引擎映射：macos→`MacIntel`、windows→`Win32`、linux→`Linux x86_64` | 恒定 | 强：`--fingerprint-platform` | 无 | **F**（UA/UA-CH/字体/屏幕须同步） | 已有参数（`Profile.swift:356-358`）。Mac 宿主选 Windows 时是三重矛盾源头 |
| **e** | Plugins `mod-22.js:17-28` / `4362` | `navigator.plugins`（按 `length`+索引）；每条 `[name, filename, types.map(m=>[m.type,m.suffixes]).join("++")].join(",")`；插件间 `join(", ")` | string | Chrome 桌面固定 5 条 PDF：`PDF Viewer,internal-pdf-viewer,application/pdf++pdf++text/pdf++pdf, Chrome PDF Viewer,…` ×5；空 → `""` | 恒定 | 无（跨 Blink 品牌相同） | `plugins` 无 `length` → `""` | **F** | 原生固定表；不要替换 PluginArray |
| **f** | ScreenSize `mod-23.js:15-23` / `4542` | `screen.availWidth+"w_"+availHeight+"h_"+colorDepth+"d_"+devicePixelRatio+"r"` | string | 宿主：`"2560w_1410h_24d_2r"`；headless：`"800w_600h_24d_1r"`；缺失属性会拼出字面 `undefined` | 恒定（同一显示器） | 强：宿主屏幕/DPR/色彩深度 | `screen` 为假 → `""` | **M/H**（不同"新设备"应有不同屏幕；同机所有 Profile 相同 = 关联） | 参数存在但**不生效**（`IdentitySampler.swift:128-131`；`win-screen-a/b.json` 均 800×600）。必须引擎 patch `screen.*` + `devicePixelRatio` |
| **g** | TimeZoneOffset `mod-24.js:15-21` / `4712` | `-date.getTimezoneOffset()/60`，`date` 是模块加载时的 `new Date`（`mod-01.js:27`） | string 数字 | `"8"`/`"-5"`/`"5.5"`/`"0"`（`-0` 也成 `"0"`） | 加载时定值 | 强：`--timezone` + DST | 无 | **M/H**（须与出口地理时区一致） | 已有参数（`Profile.swift:376`）。留空=本机 `Asia/Shanghai` |
| **h** | TouchSupport `mod-25.js:15-21` / `4881` | `"ontouchstart" in window \|\| (window.DocumentTouch && document instanceof DocumentTouch) \|\| false` → `.toString()` | string | 桌面恒 `"false"` | 恒定 | 弱（移动身份才 `true`） | `win`/`doc` 缺失 → `""` | **F** | `touch:false`（`IdentitySampler.swift:184`）。`window.ontouchstart=null` 注入即变真 → 是注入痕迹 |
| **i** | AvailableStorage `mod-12.js:15-28` / `2685` | 对 `["sessionStorage","localStorage"]`：`setItem("muffins","muffins")`+`removeItem` | string | `"sessionStorage-enabled, localStorage-enabled"` | 恒定 | 无 | `window[t]` 假 → `-unavailable`；抛错 → `-disabled` | **F** | 原生；预置存储不要破坏 setItem |
| **j** | Fonts `mod-18.js:54-165` / `3621-3682` | 共享 2D ctx（`mod-01.js:31`）；先测 base `monospace/sans-serif/serif` 的 `measureText("mmmmmmmmmmlli").width`，再逐项测 55 个候选（fallback 取 `mono→sans-serif`、其余→`monospace`），宽度不等记 1 | 55 个 `"0"/"1"` 的 string；`internalValue` 是命中名（不上行） | 宿主 macOS 23/55（`11001111…`）；Windows 身份约 12–13/55；`ctx` 缺失或 measure 抛错 → `"unavailable"` | 恒定（同 seed+平台） | 强：字体集 + 平台 | 缓存 `sessionStorage["_mf"]`；`UNAVAILABLE_WIDTH=-1` | **M/H**（最强关联项之一） | 默认 `--disable-spoofing=font`（`sample()` 不插 `.font`）→ 所有 Profile 逐字节相同。需引擎按平台/seed 提供字体表；跨平台身份不能用宿主表 |
| **k** | GraphicsConfiguration `mod-19.js:14-16` / `2865` | 无读取 | — | 恒 `""` | 恒定 | 无 | 无 | **F** | 什么也不做；`gpu` 开关对本字段零影响 |
| **l** | UserAgent `mod-26.js:15-17` / `5050` | `navigator.userAgent` | string 原样 | 引擎 UA，含 `Chrome/148.0.0.0`（headless 会带 `HeadlessChrome`） | 恒定 | 强：`--fingerprint-brand[-version]`、平台 | 无 | **F/H**（引擎版本对所有 Profile 相同 = 簇） | 已有参数（`Profile.swift:360-366`）。注意 headless 的 `HeadlessChrome` 与 148 落后真实 Chrome |
| **m** | FlashVersion `mod-27.js:15-32` / `5217-5229` | `window.ActiveXObject` 分支（Chrome 无）；否则 `mimeTypes`/`plugins["Shockwave Flash"]` | string | 现代 Chrome 恒 `""`；`"mime-types-unavailable"`；`"no-flash-plugin"` | 恒定 | 无 | 异常被吞 | **F**（任何 Flash 值都是时代错误） | 原生 |
| **n** | HasAdBlocker `mod-28.js:15-43` / `5395-5440` | 先读 `sessionStorage["_ab"]`；否则 append 带 8 个 ad class 的 1px 绝对定位 div（`innerHTML="&nbsp;"`），`setTimeout(20)` 后读 `clientHeight/clientWidth===0`，移除并写缓存；文档未完成则等 `DOMContentLoaded` | string `"true"`/`"false"` | 无广告拦截器时 `"false"`；有 → `"true"` | 每个 tab 首次真探测 | 无 | 缓存命中 `at≈0` | **F**（诚实但少见 `true` 会加分/减分） | 原生。不要预置 `_ab`；扩展白名单里不要带 adblock |
| **o** | CanvasId `mod-08.js:17-33` / `1772-1803` | `document.createElement("canvas")` 400×60，`textBaseline`/`fillStyle#f60`/`fillRect`/`#069`/`11pt Arial`/`fillText("Cwm fjordbank glyphs vext quiz, 😃")`/`rgba(102,204,0,.7)`/`18pt Arial`/同文本，`toDataURL()` → `md5(dataURL)` | 32 hex md5 | seed 决定，如 `5a158270…`；异常 → `"unavailable"` | 同 seed 恒定 | 中：渲染栈/字体 | try/catch+finally | **M**（每 Profile 必须不同） | 引擎 `.canvas`（seed）+ IdentityShim 修正 measureText。默认开启 |

**关于字体表的两条实测**（`engine-probe/`）：

```
mac-seed66666-nofont  11001111…（23 个 1，与 macos.json 相同）
mac-seed66666-spoof   11001111…（与 nofont 逐字节相同）
win-disable-font      11001111…（宿主表）
win-allspoof          01000101…（12 个 1，Windows 味的删减集）
live seed=818181 on   10001111…（只删掉 Arial Black，1 位差异）
```

结论：macOS 身份下 font 改写是**按 seed 做删减**，某些 seed 删 0 个；Windows 身份才切到近似 Windows 的缩减表。字体项永远不可能靠 `--disable-spoofing=font` 之外的方式"变"。

---

## 4. `b` 上下文字段表

`m()` 定义在 `mod-06.js:85-100` / beautified `1263-1277`。取值来源：`location.hash`（非空时）否则 `location.search`，逐键 `queryStringValueForKey`（`mod-00.js:50-58`；子串匹配 `key=`，只取第一个 `=` 后的片段并 `decodeURIComponent`）。

| 键 | 含义 / 源码 | 精确算法 | 类型 | 确定性 | 平台依赖 | 异常/哨兵 | 判定 |
|---|---|---|---|---|---|---|---|
| **a** | referrer `mod-06.js:88` | 来自 hash/query；若真值则 `hashUrlWithAuthorityCheck(new PartitionedUrl(v.a))`（`mod-06.js:149,155`） | string | 同页面/来源恒定 | 无 | 空 → `""` | H（同一来源 URL → 同一哈希） |
| **b** | url | 同上（`mod-06.js:89,155`） | string | 同上 | 无 | 空 → `""` | H |
| **c** | title | `sha256WithSalt(title)`（`mod-06.js:155`） | base64url 43 | 同标题恒定 | 无 | 空 → `""` | H |
| **d** | muid | 明文拷贝自 sourceData（`mod-06.js:143,152`） | string | 真值**跨会话不变** | 无 | 全新设备首发为字面 `"NA"` | **H 最强**（服务端下发，cookie 携带） |
| **e** | sid | 明文拷贝自 sourceData（`mod-06.js:142,153`） | string | 30 分钟生命周期 | 无 | 首发 `"NA"` | **H** |
| **f** | audioMozSrcObjectCheck `mod-06.js:60-67` | `new Audio`；`null===mozSrcObject && undefined===srcObject` | boolean | 恒定 | 引擎代际 | `try` → `false` | F（Chromium `false`） |
| **g** | arrayBufferRequiresNew `mod-06.js:69-75` | `try{ArrayBuffer();return false}catch{return true}` | boolean | 恒定 | 引擎代际 | — | F（Chromium `true`） |
| **h** | arrayDotFromSupport `mod-06.js:77-83` | `try{Array.from("hello");return true}catch{return false}` | boolean | 恒定 | 引擎代际 | — | F（Chromium `true`） |
| **i** | document keys `mod-06.js:96` | `Object.keys(document)` | string[] | 页面/DOM 相关 | 注入探针 | 正常 `["location"]`；named access（img/form/iframe name 等）会追加 | **H/F**（任何 page-world 注入/扩展 expando 都进这里） |
| **j** | navigator keys `mod-06.js:97` | `Object.keys(navigator)` | string[] | 恒定 | 注入探针 | 正常 `[]`（属性都在 prototype） | **H/F**（同上） |
| **n** | loadedTime `mod-06.js:50,98` | 模块求值时的 `performance.now()` | number | **同 iframe 内恒定** | 时序 | 无 | 结构特征（几十 ms） |
| **u** | url 域名 `mod-06.js:150-151` | `getUrlDomain(v.b)`：取 authority、去 `//`、去端口（`mod-04.js:151-156`） | string | 同页面恒定 | 无 | 无 authority → 键缺失 | H（明文域名泄漏） |
| **v** | referrer 域名 | `getUrlDomain(v.a)` | string | 同上 | 无 | 同上 | H |
| **w** | nonce 时间戳证明 `mod-06.js:126-129,154` | `Date.now() + ":" + sha256Hex(h + (Date.now()+1))` | `"<ms>:<64hex>"` | 每发都变 | 无 | 无 | **完整性锚点**（服务端可重算） |

补充：

- `b.a/b.c` 是 `sha256(unescape(encodeURIComponent(x)) + "7766e861-8279-424d-87a1-07a6022fd8cd")` 再 base64url（`mod-04.js:62-65`，beautified `853-855`）。盐是**版本常量**，所以同一 URL 在任何设备上都得到同一串。
- URL 分段哈希：authority 全量 40 段、path 30 段、query/fragment 剩余 40；超出全量上限的部分只取 6 位前缀；`*.stripe.com` authority 保持不变（`mod-04.js:96-102,140-150`）。
- `b.a`/`b.b`/`b.c` 的明文版先落进 `u`/`v` 与 sourceData 的删除逻辑：`E&&(v.a=E,delete i.referrer)` … `f&&(v.e=f,delete i.sid)`（`mod-06.js:149`）。空字符串不会触发删除。
- `i`（顶层 canvasB64）恒 `undefined` → 键消失；`tag`/`src` 是未替换的字面量占位符（`mod-06.js:163-164`）。

---

## 5. `id`、`a` 与去重：可被服务端复算的三段

```js
c = extractedFeatures.map(x => x[0]).join(" ")   // 15 个 value，单空格连接
u = md5(c)                                       // 32 hex
O = (2 === sourceData.v2) || sessionStorage.getItem("id") !== u
sessionStorage.setItem("id", u)
a = O ? features : null
```

（`mod-06.js:137-141,158-168`；`md5` 为 `mod-07` 的 hex 变体。）

- 服务端复算路径：把 `a.a…a.o` 的 `v` 按字母序 `join(" ")` 取 md5，必须等于 `id`。`a` 为 `null` 时用历史同 `id` 的特征。
- 因此 `id` 是**免费的"同设备再访"判定器**：同一 Profile 重开、字段未变 → `id` 相同，服务端立刻知道"这台还是原来那台"。
- `sessionStorage` 作用在 `m.stripe.network` iframe 的 origin 上，且按顶层站点分区 → 换顶层站点就是一次全量 `a`。
- `_mf`/`_ab` 是性能缓存，不是身份；但缓存命中会让 `at` 消失，可作为"同 tab 再访"的证据。

---

## 6. 三分类总判定

### 6.1 必须变（新设备的意义所在）

| 项 | 为什么 | AnyBrowser 怎么做 |
|---|---|---|
| `.m.stripe.com` 的 `m`（= `guid`，`HttpOnly`，2 年，每次响应续期） | 服务端直接拿它认出旧设备，与字段无关；只要上一个 Profile 打开过任意 Stripe 页面就被重新「续命」 | 每次"新设备"启动前清掉；`Storage.getCookies` 复核 |
| 商家域 `__stripe_mid` / `__stripe_sid` | 旧 muid 会被回读并写进 `b.d/b.e`，新 Profile 直接继承身份 | 同上；两段式启动里在首帧前清 |
| `a.o` canvas md5 | 最直接的设备哈希 | 已由 seed 驱动；保证 seed 唯一且随机（库内已 `newSeed(excluding:)`） |
| `id` | 上述的综合哈希 | 随字段自动变；不要手写 |
| `a.j` 字体位串 | 与 canvas 同级强，且默认不生效 | 引擎按 seed/平台生成；至少 macOS 身份要打开 `.font` |
| `a.f` 屏幕串 | 同机所有 Profile 相同 | 引擎 patch `screen.avail*`/`colorDepth`/`devicePixelRatio` |
| `a.c`/`a.g` | 语言/时区簇 | 随出口 IP 采样；换出口必须换 |
| `b.d`/`b.e` | 只要 cookie 清了自然新；也可以自造（服务端回显 42 字符值） | 更稳的做法是生成 `uuid4+6hex` 写进 `__stripe_mid/__stripe_sid`（必须在首帧前，且清掉 `m`） |
| `h`/`b.w`/`t`/`at` | 每发必新 | 真采集即满足；合成 payload 需现算 |

### 6.2 必须与平台/引擎保持固定关系（随机化会穿帮）

- `d` `navigator.platform` ↔ `l` UA ↔ `Sec-CH-UA-Platform` ↔ `Sec-CH-UA-*` 高熵 ↔ `e` plugins 固定表 ↔ `j` 字体集 ↔ `f` 屏幕/DPR ↔ `c` 语言 ↔ `g` 时区。任意三层不同源就是硬矛盾。
- `a.a`=`"true"`、`a.b`=`"false"`、`a.h`=`"false"`（桌面）、`a.k`=`""`、`a.m`=`""`、`b.f/g/h`=`false/true/true`。
- `b.i`=`["location"]`、`b.j`=`[]`（m.stripe.network 里）；注入只要写 own enumerable 属性就破。
- `a` 的每次值必须能复算出同一个 `id`；`a` 只在首见/`v2:2` 时为对象，其余为 `null`。
- `at` 只允许在 `j`/`n`，且首次 `a.n.at` 应 ≈20ms 量级。
- `b.n` 同一 iframe 内恒定、为几十 ms；跨发漂移或大得离谱都是合成痕迹。

### 6.3 服务端关联旧身份的钩子（按可靠度）

1. `m` + `__stripe_mid`（**决定性的**，服务端自己签发的 42 字符；只清其一等于没清）。
2. `id` 全等（同 Profile 重开、只换 cookie 仍相同）。
3. `a.f` 屏幕串 + `a.j` 字体串（同宿主逐字节相同）。
4. `a.c`/`a.g` 同语言时区（同一 locale 模板）。
5. `b.a`/`b.u`/`b.c` 同来源 URL/标题哈希（跨 Profile 访问同一页即同值）。
6. `a.l` 同 UA（全员 148，且 headless 带 `HeadlessChrome`）。
7. `b.i`/`b.j` 注入形态（同一套 shim 装在所有 Profile 上 → 同一形状）。
8. `a.e`/`a.k`/`a.m`/`a.i`/`a.a` 恒定项（同引擎版本）。
9. `w`/`h` 可重放判定：`h` 跨报文复用 = 旧 payload 重放。

---

## 7. AnyBrowser 落地清单（按优先级）

**P0 — 不做就不能叫"新设备"**

1. **cookie 清理**：新 Profile / 每次"刷新身份"启动，在首帧前清 `.m.stripe.com` 的 `m`、所有商家域的 `__stripe_mid`/`__stripe_sid`（名字精确匹配；不要把 `.link.com` 的 `__Secure-sid`/`lsid` 当目标）。`m` 是第三方上下文 cookie，若带 CHIPS 分区，`Network.deleteCookies` 必须带上从 `Storage.getCookies` 拿到的完整 `partitionKey`（`topLevelSite` + `hasCrossSiteAncestor`），缺一字段即 `Invalid parameters`。清完后可以自造 `uuid4+6hex` 写进 `__stripe_mid/__stripe_sid`（服务端会回显），也可以让首发保持 `NA` 由服务端签发——但 `m` 必须清，否则服务端把老 guid 还回来。现状：`refresh-on-launch` 已识别，验收要看 `Storage.getCookies` 里 stripe 相关 cookie 为空。
2. **不要预置 sessionStorage** `id`/`_mf`/`_ab`（`m.stripe.network` 域）；优雅退出会墓碑清扫，`kill -9` 的磁盘残留页面读不回，可忽略。

**P1 — 消除同机同质**

3. **屏幕**：引擎 patch `screen.availWidth/availHeight/colorDepth/devicePixelRatio`（`ScreenProfile` 表已经写好但被 `screenSpoofingSupported=false` 短路，`IdentitySampler.swift:131,166-172`）。Mac 机型取值要真实（如 1512×982@2、1728×1117@2、2560×1440@2，Retina `colorDepth=30`，Windows 24）。
4. **字体**：macOS 身份默认打开 `.font`；Windows 身份提供真正的 Windows 字体表（现状只有 seed 删减的 macOS 表，`FingerprintConsistency.swift:173-179` 已明示）。保证同 seed 稳定、不同 seed 不同。
5. **平台三元组一致性**：Win 身份必须同时换 UA/UA-CH/platform/字体/屏幕/DPR；Linux 身份必须解决 `gpu` 不可用与字体（现为宿主表）。

**P2 — 结构与时效**

6. 首访结构正确：`a.n.at` ≈20ms、`a.j.at` 存在、`t` 覆盖两者；不要把 `_ab`/`_mf` 带进新 tab。
7. 引擎 148 落后 Chrome 稳定版：`a.l` 里每个 Profile 都是 148 → 簇。升级引擎或至少别在 UA-CH 上再露出破绽。
8. headless 启动的 `HeadlessChrome` 与 `f="800w_600h_24d_1r"` 组合是强特征；面向 Stripe 的生产 Profile 用窗口模式。
9. 注入面收敛：IdentityShim 是 MAIN-world content script，只改 `TextMetrics.prototype`（不落 own key），`b.i/j` 干净；任何新增 shim 都要复核 `Object.keys(navigator/document)`。

---

## 8. 合成 payload 的最小自洽清单

如果将来要在上报层直接合成（而不是真采集）：

1. `id = md5(a.a…a.o 的 v 以单空格 join)`；
2. `h` = 20 位 `[0-9a-f]`；`b.w = Date.now() + ":" + sha256hex(h + (Date.now()+1))`；
3. 除 `j`/`n` 外不得有 `at`；`n.at ≥ 20`；`t ≥ max(t_i)`、`at ≤ t_i`、全部 `toPrecision(5)`；
4. `b.d/b.e` 用当前 cookie 值，首见给 `"NA"`；`k=""`、`m=""`、`b.f=false`、`b.g=true`、`b.h=true`、`b.i=["location"]`、`b.j=[]`；
5. `a` 只在首见或 `v2:2` 为对象；`v2` 只取 1/2；
6. `b.u` 是 url 明文域、`b.v` 是 referrer 明文域、`b.a/b/c` 是带固定盐的 base64url 哈希；
7. `i` 键不存在；`tag`/`src` 原样。

---

## 9. 证据索引

### 9.1 全文 API 面 grep（`out-4.5.45.js`）

`hardwareConcurrency` 0、`deviceMemory` 0、`webgl|WebGL|getParameter` 0、`AudioContext` 0、`OffscreenCanvas` 0、`speechSynthesis` 0、`RTCPeerConnection` 0、`Intl|resolvedOptions` 0、`maxTouchPoints` 0、`userAgentData|getHighEntropyValues` 0、`pdfViewerEnabled` 0、`permissions` 0、`getBattery` 0。命中：`plugins`×2、`doNotTrack`×2、`userLanguage`×2、`cookieEnabled|mimeTypes|platform|availWidth` 各 1。

### 9.2 关键源码

- 信封/锚点：`mod-06.js:60-83,85-100,102-112,116-129,131-173,175-198`；beautified `1253-1315,1316-1402`
- 基类计时与 `at`：`mod-02.js:27-56`；beautified `383-404`
- 非 telemetry 与 track：`mod-10.js:47-56,80-104`；beautified `2252-2270`
- 传输：`mod-29.js:18-35`；beautified `5611-5638`；`__sid` 写入 `5628`
- 哈希与盐：`mod-04.js:39-156`（盐 `62`，checkout/stripe authority `96-102`）
- `MStorage`/query 取值：`mod-00.js:42-58`、`64-67`
- 各 extractor：见 §3 行内引用
- 注册表：`mod-11.js:27`；beautified `2490-2504`
- 入口：`mod-30.js:1-16`；bundle `n.s=30`
- 内层壳/中继：`inner.html:1`、`/tmp/stripe-v3work/mouter.js:1`
- v3 侧：`v3_plain.js` offset `587.6k`（`MidSidManager`、`__stripe_mid`/`__stripe_sid`、`pt=42`）、`591.5k`（`_buildFrameQueryString`，`url,title,referrer,muid,sid,version:6,preview`）、`588.1k`（`originatingScript:"m2"` 与 `m` 回传解析）、`592.5k`（`vt` 的 `v2:2` ping、`report` 的 `track`）、`569.5k`（`ce` cookie setter：默认 365 天、SameSite 默认 Lax，`__stripe_mid/sid` 分别取 1 年/30 分钟且 Strict）
- 引擎二进制（`/Applications/AnyBrowser.app/Contents/Frameworks/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework`，offset 约 226,227,466 的开关名连续区）：有 `fingerprint-screen-width`、`fingerprint-screen-height`、`fingerprint-device-scale-factor`；**没有** `fingerprint-screen-avail-width`、`fingerprint-screen-avail-height`、`fingerprint-color-depth`、`fingerprint-touch`（`bytes.count == 0`）。即便 screen 开关生效，`avail*` 与 `colorDepth` 也必须新增引擎补丁。

### 9.3 实测

- `/tmp/stripe-recon/live-stripe-capture3.json`：`frames[0].url`（`muid=NA&sid=NA&version=6&preview=true`）、`frames[0].info.stripeM.sid`（42 字符三元组）、`frames[0].info.ss`（`1`,`_ab`,`_mf` 55 位,`id`）、`cookies`（`__stripe_mid` 365 天/Strict、`__stripe_sid` 30 分钟/Strict、两者均 `httpOnly:false`）
- `/tmp/stripe-recon/live-stripe-capture.json`：`page.docCookie` 中的 `__stripe_mid/__stripe_sid` 42 字符
- `/tmp/stripe-recon/font-off.json`：`fontBits` `11001111…`、`fontDetected` 23 项、`plugins` 5 条、`screen [800,600,…]`
- `/tmp/stripe-re-20261122/engine-probe/*`：font on/off 与 seed 的位串对比、`win-screen-a/b` 屏幕同值
- `/tmp/stripe-re-20261122/chrome-baseline.json`：对照浏览器（HeadlessChrome 158）同形状
- `/tmp/stripe-plan-v2/work/*.headers` / `*.body`：同轮直打 `m.stripe.com` 的原始 HTTP，15 组响应。要点：
  - `set-cookie: m=<42 字符 guid>; Expires=<+2 年>; Secure; HttpOnly; SameSite=None`（`a.headers`、`P2.headers`、`c.headers`、…），**每次响应都重发同一个 `m` 并续期**（`a`/`b`/`f`/`resp1` 全为 `30db7444-…`，`I`/`J` 全为 `0183f8a0-…`）→ 只要打开过一次 Stripe 页面，锚点就被续命 2 年。
  - 23 组响应的 `muid`/`guid`/`sid` **全部恰好 42 字符**；`guid` 只在请求带 `m` cookie 时才复用，否则每次新签发。
  - 请求若带 42 字符 `muid`/`sid`，服务端**逐字回显**（`H`/`M`/`N` 回显 `1111…`/`2222…`；`P`/`P2`/`R` 回显 `0123…`/`fedc…`），`guid` 仍新签发或沿用 cookie。
  - 不带 `muid`/`sid` 时，服务端**每发都新签发**不同值（`a` 与 `b` 的 muid 不同），只有 `guid` 按 `m` cookie 复用。
  - 响应 `content-type: application/json;charset=utf-8`，body 恒 156 字节，形状 `{"muid":"…","guid":"…","sid":"…"}`。

### 9.4 推断（无直接证据）

- beacon 的 `Content-Type` 为默认 `text/plain;charset=UTF-8`（未显式设置；服务端 CORS 只放行 `Content-Type` 请求头，响应 `content-type: application/json;charset=utf-8`）。
- `m` 与 `guid` 是否在真实浏览器里**始终**相等：本轮原始 HTTP 里 15 次响应全部相等，但都是在 m.stripe.network 语境下用脚本直打，未经完整浏览器链路。
- `muid` 与 `m`/`guid` 的映射是否被服务端持久化：本轮只有回显，没有跨会话证据。