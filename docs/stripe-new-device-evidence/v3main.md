# `js.stripe.com/v3` 主脚本采集面白盒分析（v3_plain.js）

- 分析对象：`/tmp/stripe-js-dl/v3_plain.js`（1,215,035 B，双向压缩单行；`last-modified: 2026-11-20`，`etag "523f6e3ca1172dc607d15db83cad402e"`）
- 美化副本（仅文本格式化，未执行）：`/tmp/stripe-v3work/v3_beauty.js`（49,154 行，`js-beautify 2.0.3`）
- 方法：纯文本 / 语法结构检索；未 `require`、未 `eval`、未在浏览器执行该文件。涉及帧内脚本（m-outer / inner）时另行 curl 取原始字节做文本比对，同样未执行。
- 证据格式：`v3_beauty.js:行`（可用同字符串在 `v3_plain.js` 内检索复核）。第三方 one-line 文件用字符偏移 `file@offset`。
- 关联已抓包：`/tmp/stripe-recon/live-stripe-capture.json`、`live5-on-828282.json`、`live5-off-828282.json`、`signup-capture.json`。
- 标注约定：**[事实]** = 有源码/抓包直证；**[推断]** = 由结构推理、无直证；**[待实测]**。
- 同批报告分工：本文只负责 **v3 主脚本**；`out-4.5.45.js` 的字段级采集在 `collector.md`，注入探针/计时在 `integrity.md`，3DS/ACS 在 `acs3ds.md`。下文凡涉及 out.js 处均标为「另一份报告」。

---

## 0. 一页结论

**v3 主脚本本身几乎不采集浏览器指纹。它是一个「采集编排器 + 上下文提供者」：把商家页的 URL / referrer / title / 域名 / mids 交付给隐藏的 `m.stripe.network` iframe（`out-4.5.45.js`），由那一层去做 15 项真实采集，再把 `guid/muid/sid` 回传给商家页并写成**商家域**cookie。**

因此本文件对「看起来像一台新设备」的贡献是**四条链路**，不是字段：

| # | 链路 | 新设备含义 |
|---|---|---|
| A | 1 秒后自动创建 `m-outer` → `m.stripe.network/inner.html` → `POST https://m.stripe.com/6` | 这是 Stripe 唯一真正拿指纹的入口；新 Profile 必须让它跑，且必须让它看到一套和旧 Profile 不同的 15 特征 |
| B | MidSid 把 `guid/muid/sid` 持久化成商家域 cookie `__stripe_mid`(1 年滑动) / `__stripe_sid`(30 分钟滑动)，并注入之后每一个控制器请求 | 新设备 = 无 cookie → `muid=NA` → 服务端发新身份；旧 cookie 在 = 旧设备。同一 seed 清 cookie 只是「同指纹、新 muid」 |
| C | `mids` 被塞进控制器 iframe 的 **URL hash**、Link 弹窗 URL、confirm / PM 创建体的 `client_metadata`、`radar_session_id` 关联 | muid/sid 是跨商户锚点；任何一处复用旧值都会把新 Profile 挂回旧设备 |
| D | 一批第三方指纹 SDK 帧（Human Security / hCaptcha / PayPal FraudNet / Klarna Rechnung / wanderlust）由 v3 触发 | 每个都会写各自的一方/三方标识；Profile 重置必须覆盖这些域，否则「引擎指纹换了、vendor 指纹还是旧的」 |

**v3 自身唯一的原始环境读取只有 6 项**：`navigator.userAgent`、`navigator.maxTouchPoints`、`navigator.languages[0]`（回退 `userLanguage`/`language`）、`navigator.brave`、`navigator.standalone`、`window.matchMedia`。**0 处 canvas / WebGL / Audio / plugins / cookieEnabled / doNotTrack / deviceMemory / hardwareConcurrency / userAgentData / storage**（全文 grep 计数为 0）。真正的高熵字段全在 iframe 里。

> 最容易被忽略的一句：`__stripe_mid` 是 `document.cookie` 可读、非 HttpOnly、`SameSite=Strict`、写在 `"."+location.hostname`、**42 字符硬校验**、默认 365 天滑动续期（`v3_beauty.js:24700-24706`、`25702-25704`、`25713-25720`）。同域任何第三方脚本都能读到它。

---

## 1. v3 自身的采集面（穷举）

### 1.1 触发时机与去处

| 项 | 源码读取 | 时机 | 去处 |
|---|---|---|---|
| UA | `window.navigator.userAgent`（`11244`、`11314`、`11581` 由 UA 派生一堆布尔） | **模块加载期求值**（顶层立即执行，`11238-11442`） | 进程内派生：`os`/`browserFamily`/`mobile`/`deviceType`/实验维度、`3ds2` 版本门、`q.stripe.com` 埋点 |
| `maxTouchPoints` | `window.navigator.maxTouchPoints`（`11313`） | 模块加载期 | 参与 iPad 判定 `m(e,t)`（`11265`）→ `mobile` |
| `navigator.brave` | `typeof window.navigator.brave === "object"`（`11421`） | 模块加载期 | 仅 `isBrave` 布尔，未上报 |
| `navigator.standalone` | `"standalone" in navigator && navigator.standalone`（`11423`） | 惰性 | iOS PWA 判定 |
| `navigator.languages[0]` | `(navigator.languages \|\| [])[0] \|\| userLanguage \|\| language`（`11581`，模块 55872） | 惰性 | ①`browserLocale` 进 payment-page-init（`31662`）；②`elements/sessions` 的 `locale` 兜底（`31330`）；③控制器请求默认参数 `navigator_language`（controller.js@1656483） |
| `matchMedia` | `(display-mode: standalone)`（`11430`）、`(prefers-reduced-motion)`（`14048`）、`(prefers-color-scheme: dark)`（`44373`） | 惰性 | PWA 判定 / 动效降级 / 主题 |

### 1.2 能力探测（不是指纹，但反映平台）

| 探测 | 源码 | 用途 |
|---|---|---|
| `"ontouchstart" in window` | `11265` | Mac UA + touch → 判成 iPad |
| `window.PaymentRequest` | `14730`、`46286`、`41332` | 是否挂 `allow="payment"`、PaymentRequest 帧、SPC 资格 |
| `window.PublicKeyCredential` + `isUserVerifyingPlatformAuthenticatorAvailable()` | `41306-41314` | 3DS2 challenge 的 WebAuthn/生物识别资格，超时 500ms |
| `new PaymentRequest([{supportedMethods:"secure-payment-confirmation"}],…)` | `41334-41360`、`41431-41460` | SPC `canMakePayment()` 探针；向 `<head>` 注入 `<meta http-equiv="origin-trial">`（`41440`） |
| `window.crossOriginIsolated` | `11593` | 「可用环境」判定 |
| `window.performance` / `PerformanceObserver` / `supportedEntryTypes` | `15934-15962` | 性能时间线（flag `_491776053`） |
| `Mh(x)` = `x in window && /\[native code\]/` | `35753-35758` | `dispatchEvent`/`Event` 是否原生 |
| `crypto.randomUUID` | `15478` | 所有 guid/stripeJsId/元素 id |
| **EIP-6963 钱包探测** | `36539-36568` | `addEventListener("eip6963:announceProvider")` + `dispatchEvent(new Event("eip6963:requestProvider"))`，把每个钱包的 `info.name` 作为 `wallet_name` 上报；第一个响应把 `_cryptoWalletDetected=true`（`36566-36568`），该布尔会被塞进 PAYMENT_ELEMENT 帧参数 `cryptoWalletDetected`（`36274`） |

### 1.3 时钟 / 计时

- `l()`：`Math.abs(performance.timeOrigin + performance.now() - Date.now()) < 3` 时采用 `performance.timeOrigin`，否则 `Date.now() - performance.now()`（`16459-16465`）。这是**时钟偏移交叉校验**：`Date` 被整体改过就会被识破。
- 该值以 `pageLoad` 进入上报（`17907`、`20222`、`23631`）、以 `stripeJsLoadTime` 进入控制器帧 hash（抓包可见 `stripeJsLoadTime=1795375282025.7002`）。
- 性能：`longtask` / `long-animation-frame` / `resource`（只保留 js.stripe.com 资源）经 `recordOuterPerformanceTimeline` 上报（`38327-38360`），`init_timings` 里带 `resource_timings`（`38340-38358`）。

### 1.4 几何

- 弹窗居中：`window.outerHeight/outerWidth/screenY/screenX/screen.availTop/innerHeight/innerWidth`（`6936-6963`、`46721-46728`）；`window.open` 的 features 字符串含 `top/left/height/width`（`46739-46750`）。Link 弹窗名 `Link-<random>`（`46749-46750`）。
- 元素布局：`getBoundingClientRect` / `clientHeight` / `clientWidth` / `getComputedStyle`（如 `25780-25800`、`26780-26800`），用于帧高度/前后遮挡，属页面几何不是设备指纹。

---

## 2. v3 **不**采集什么（逐项反证）

全文 `grep -c` 结果（`v3_beauty.js`）：

| API / 字段 | 命中 |
|---|---|
| `WebGL` / `webgl` / `getParameter` | **0** |
| `AudioContext` / `OfflineAudio` | **0** |
| `toDataURL` / `getImageData` / `createElement("canvas")` / `canvas` | **0**（唯一 `canvas` 命中是元素标签名单 `35396`） |
| `navigator.plugins` / `mimeTypes` / `pdfViewerEnabled` | **0** |
| `navigator.cookieEnabled` / `doNotTrack` | **0** |
| `navigator.deviceMemory` / `hardwareConcurrency` | **0** |
| `navigator.userAgentData` | **0** |
| `localStorage` / `sessionStorage` / `indexedDB` | **0** |
| `Intl.DateTimeFormat` / `timeZone` | **0**（时区只在控制器/消费帧内读） |
| `screen.width/height/colorDepth/devicePixelRatio` | **0**（只有 `availTop` 与 `screenX/Y` 用于弹窗定位） |
| `resolvedOptions` | **0** |

结论：**v3 对「设备」的判断全部来自 UA 字符串与少量能力布尔**；屏幕尺寸、时区、canvas、字体、插件一律不碰。谁在这份文件里找 canvas/audio 会白找——它们在 `m.stripe.network` 里的 `out-4.5.45.js`。

---

## 3. 指纹子资源 URL 模板与帧拓扑

### 3.1 URL 构造器

```js
// v3_beauty.js:15084-15087（模块 6398，导出 T）
var r = function(e){ return "".concat("https://js.stripe.com/v3/").concat(e || "") };
```

所有帧 URL = `https://js.stripe.com/v3/` + 固定清单里的文件名。清单在 `87130`（`14764-15078`），非实验 vs 实验两套后缀，例如：

- `case "METRICS_CONTROLLER": return "m-outer-0edadf75b42c6ef7240c043f3272f3f9.html";`（`14784-14785`）
- `case "STRIPE_3DS2_FINGERPRINT": return "three-ds-2-fingerprint-3f1ce9001ffe1c6c4db7d48d8be5a1a4.html";`（`14806-14807`）
- `case "STANDALONE_3DS_FINGERPRINTING": return "standalone-3ds-fingerprinting-a5a87396a85cb3b8343b2e13f9af6a2e.html";`（`14808-14809`）
- 控制器：`controller-f8a771a2….html` / `controller-with-preconnect-37337a…` / …（`14776-14783`）

另有 webpack chunk 表，同样是 `fingerprinted/js/` 前缀（`49047-49113`）：`elements-easel-frame`、`human-security-helper`、`sentry`、`trusted-types-checker` 等。

### 3.2 帧 URL 的 hash 参数（关键泄露面）

`_createIFrame`（`8070-8100`）把参数写进 **hash**，不是 query：

```js
a = window.location.href.toString(),
i = this._version ? { __shared_params__: { version, light_experiment_assignments?, trusted_outer_origin? } } : {},
s = (0,p.lK)({ ...i, ...n, referrer: a, controllerId: this._controllerId }),
c.src = "".concat((0,u.f)(m)).concat(s ? "#" : "").concat(s),   // :8097-8098
```

即**每个帧**都会拿到 `referrer=<商家页完整 URL>` 与 `controllerId`。实抓可证：

```
https://js.stripe.com/v3/controller-with-preconnect-37337a….html#
  __shared_params__[version]=v3&__shared_params__[light_experiment_assignments]={…}
  &apiKey=pk_live_…&stripeJsId=46712c60-…&stripeObjId=sobj-82a88a96-…
  &firstStripeInstanceCreatedLatency=12&controllerCount=1&isCheckout=false
  &parentProtocol=https%3A&parentIsTop=true&parentOrigin=https%3A%2F%2Fapp.link.com
  &stripeJsLoadTime=1795375282025.7002&manualBrowserDeprecationRollout=false
  &mids[guid]=NA&mids[muid]=NA&mids[sid]=NA
  &referrer=https%3A%2F%2Fapp.link.com%2Flogin&controllerId=__privateStripeController1681
```

（`/tmp/stripe-recon/live-stripe-capture.json` 的 `frames[0].url`）

控制器参数全表在 `37167-37185`：`apiKey / apiVersion / stripeAccount / stripeJsId / locale / betas / outerHttpCookieHosted / parentProtocol / parentIsTop / parentOrigin / stripeJsLoadTime / manualBrowserDeprecationRollout / mids`。

`mids` 由 `lK` 递归序列化成 `mids[guid]=…&mids[muid]=…&mids[sid]=…`（`13754-13766`）。

外置 logger 帧参数是另一组：`apiKey / stripeAccount / stripeJsId / referrer / controllerId / logPrefix`（`37986-38000`）。

### 3.3 指标帧（`METRICS_CONTROLLER`）链路

1. `lv._ec = ve ? null : ht({stripeJsId, version})`（`40209-40212`）——**只要加载 stripe.js 就会构造**，与有没有 `new Stripe()` 无关。
2. `_establishMessageChannel` 立刻注册 `window` message 监听并把 `_idsPromise` resolve（`25586-25590`）。
3. `he && setTimeout(_createControllerFrame, 1000)`（`25531-25533`）；`he` 默认 `true`，仅能被脚本 URL 上的 `_1776170249=false` 关掉（`24720`、`24746`）。
4. `_createControllerFrame` 用 `frameType: METRICS_CONTROLLER` 建隐藏帧（`25564-25580`），`appParams = _buildFrameQueryString()`。
5. `_buildFrameQueryString`（`25675-25692`）产出：

```js
{ url: t, title: document.title, referrer: document.referrer,
  muid: this._muid, sid: this._sid, version: 6, preview: (0,E.qZ)(t),
  metaReferrerPolicy?: <meta[name=referrer] 的值> }
```

  其中 `t` 由 `_extractUrl` 决定（`25662-25674`）：`origin*` 系列 → 只给 `location.origin`；`unsafe-url` → 去掉 `#`；其它 → 完整 href。
6. 帧实体是 `https://js.stripe.com/v3/m-outer-….html#<上面这串>`。**`m-outer` 是 524 B 的中继脚本**（`/tmp/stripe-v3work/mouter.js`，全文）：

```js
var e="https://m.stripe.network",
    n=window.location.hash,
    t=/preview=true/.test(n)?"inner-preview.html":"inner.html",
    o=document.createElement("iframe");
o.src="".concat(e,"/").concat(t).concat(n);
var i=function(n){
  if(n.origin===e){ var t=window.opener||window.parent||window; if(!t)return; t.postMessage(n.data,"*") }
  else o.contentWindow.postMessage(n.data,e)
};
window.addEventListener("message",i,!1), document.body.appendChild(o)
```

  两个要点：**hash 原样透传**；m.stripe.network 回来的消息用 **`targetOrigin="*"`** 转发给上层——所以商家页任何 `message` 监听器都能读到 `muid/guid/sid`。
7. `inner.html` 与 `inner-preview.html` **字节完全相同**（各 930 B，`md5 441070f07f0e89a26ecd81c9afcab8ed`）。`inner.html` 内联脚本：`StripeM.p({t:!0, v: hash 中 version=6|4, 缺省 "4"})`（即完整 15 字段上报到 `https://m.stripe.com/6`），并处理两种消息：

```js
case "ping":  StripeM.p({t:!0, o:{muid,sid,referrer,url,title,v2}, v: version||"4"})
case "track": StripeM.b({muid,sid,url,source,data}, version||"4")   // 只上报现成 data，不再抽特征
```

（`/tmp/stripe-v3work/inner.html`；`ping=false` 可让自启 ping 失效）

8. 抓包实测（`live5-on-828282.json`）：`POST https://m.stripe.com/6`，body = `base64(encodeURIComponent(JSON))`，含 `v2:1, id:<md5>, a:{a..o}, b:{url哈希, domain, …}`，`muid/sid` 在 `b.d/b.e` 为 `"NA"`。
9. 回传：`_handleMessage` → `_getID("merchant"|"session")` → 写 cookie。

### 3.4 其余由 v3 触发/承载的隐藏帧

| 帧 | 触发者 | 参数 | 扮演的角色 |
|---|---|---|---|
| `hcaptcha-invisible-59c98afb….html` | `Sf.rx()`（`6147-6154`），captcha 初始化 | `debugMode`、`parentOrigin` | hCaptcha 被动验证；`sendFraudSignals` 送键盘/指针/触摸事件与坐标（`6466-6516`，移速节流 500 ms，`6494`） |
| `human-security-e990b83c….html` | chunk 674 `loadHumanSecurity()` | `debugMode`、`parentOrigin` | Human Security/PerimeterX；取 `_px3/_pxvid/_pxcts` 塞进 `radar_session`（`37615-37660`） |
| `paypal-fraudnet-sdk-2e5237….html` | `confirmPayPalPayment` 前置（`32811-32833`） | `flowId`、`sessionId`(UUID 去横线)、`sandbox` | PayPal FraudNet 设备指纹；返回值进 `payment_method_options.paypal.risk_correlation_id`（`32834-32841`） |
| `rechnung-device-fingerprint-sdk-d28015….html` | `confirmRechnungPayment` 前置（`32846-32855`） | `merchantId`、`sessionId`、`sandbox` | Klarna 设备指纹；返回值进 `…rechnung.risk_correlation_id`，且 token 前缀固定 `ud1X0qwDppce_`（`43559`） |
| `wanderlust-frame-c88cf589….html` | 控制器消息 `stripe-init-wanderlust`（`37063-37094`） | — | 在帧内算一个 sealed 结果，再广播给**所有**帧 `sendWanderlustSealedResult`（`37087-37093`）；这是跨帧共享的设备绑定凭据 |
| `three-ds-2-fingerprint-3f1ce9….html` | 3DS2（`41192-41196`） | `intentId`、`locale`、`hosted` | 3DS2 设备指纹帧；`perform3DS2Fingerprint({gateway, transactionId, methodUrl, …})`（`41260-41290`） |
| `standalone-3ds-fingerprinting-a5a873….html` | `stripe.performThreeDSecureFingerprinting`（`38082-38090`） | `{url}` | 独立 3DS 指纹 |
| `payment-request-inner-browser-….html` | `new Stripe`/PR（`46445-46450`） | `authentication`、`mids`、`origin` | Apple Pay / Payment Request，`canMakePayment` 取决于本机钱包 |
| `PAYMENT_API_INNER` | payment-page init（`31662-31670`） | `controllerId`、`paymentPageInitParams`(JSON)、`apiType` | 承载 `browserLocale` 等支付页初始化 |

所有 FrameClient 类型的隐藏帧都 `referrerpolicy="no-referrer"`、`aria-hidden`、`tabIndex=-1`，自动挂到 `document.body` 或 `#stripe-hidden-frames-container`（`8525-8548`、`24796-24824`）。

---

## 4. MidSidManager 详解（`_t`，`25497-25730`）

### 4.1 构造

```js
this._guid = "NA";
a = t.checkoutIds?.muid; i = t.checkoutIds?.sid;
a && a !== "NA" ? (this._muid = a, doNotPersist) : (this._muid = this._getID("merchant"), …)
i && i !== "NA" ? (this._sid  = i, doNotPersist) : (this._sid  = this._getID("session"),  …)
…
he && ( setTimeout(_createControllerFrame, 1000), _startIntervalCheck(), setTimeout(_testLatency, 2000+500*Math.random()) )
```

`lt="merchant"`、`ut="session"`、`dt="NA"`（`25498-25500`）。

### 4.2 取值规则 `mt` 与 42 字符闸门

```js
pt = e => 42 === e.length                                   // :25501-25503
mt = (existing, incoming, enabled) =>
       enabled ? (!existing || !pt(existing) && pt(incoming) ? incoming : existing)
               : cryptoRandomUUID()                         // :25504-25506
```

- `enabled=false`（`he=false`）→ **每次都用新随机 UUID，不读不写 cookie**。
- 否则：已有 42 字符值 → **保留旧值**（身份粘住）；无值/坏值且新值 42 字符 → 采用新值并写 cookie。
- 初始 `_getID("merchant")` 无 cookie 时返回 `"NA"`，`pt("NA")=false` → 不写；所以 `muid=NA` 只存在于首帧，等 m2 回包后才落 cookie。抓包证实：`m-outer` 首帧 hash `muid=NA&sid=NA`，页面最终 cookie 为 `__stripe_mid=<uuid+6hex>`（42 字符）。

### 4.3 cookie 写入（`ce`，`24696-24707`）

```js
m = `${encodeURIComponent(name)}=${value};expires=${now+expiresIn||31536e6};path=${path||"/"};SameSite=${sameSite||"Lax"}`
  + (domain ? `;domain=${domain}` : "")
  + (protocol === "https:" ? ";secure" : "")
document.cookie = m
```

- `muid`：`name="__stripe_mid"`, `domain="."+location.hostname`, `SameSite="Strict"`, 默认 365 天（`25700-25709`）
- `sid` ：`name="__stripe_sid"`, 同上但 `expiresIn=18e5`（30 分钟）（`25711-25722`）
- 读取用 `le()`（`24709-24719`，`document.cookie.split("; ")`），只读这两个名字 + `stripe.link.persistent_token` 的存在性检查（`40177-40180`）。
- **非 HttpOnly**、`SameSite=Strict`、https 下加 `Secure`；`domain=.hostname` 在 `localhost` / 纯 IP 主机上可能被浏览器忽略（[推断]，需自测）。

### 4.4 名不副实的两处

1. **不是「mid 管理器」而是「m2 接收器」**：真正的来源是 `m2` 消息（`25511-25523`）：

```js
if ((0,E.qZ)(r) && typeof n === "string") { a = JSON.parse(n);
  if ("m2" === a.originatingScript) { s = a.payload;
    this._guid = s.guid; this._muid = this._getID("merchant", s.muid); this._sid = this._getID("session", s.sid);
    this._onIdsUpdate?.(this.ids()) } }
```

   只校验 `origin ∈ 可信 stripe 域`（`qZ`）与 `originatingScript==="m2"`；**不校验 `event.source`、不校验 type/长度**。

2. **5 秒轮询是 URL 变化检测器**，不是心跳（`25592-25612`）：`setInterval(…,5000)`，只有 `location.href` 变了才 `ping`（带 `url/title/referrer/version:6`）。另有首用一次的 `vt()`：`v2:2` ping + `source:"mouse-timings-10-v2"` + `data:_latencies`（`25739-25762`），由任意 `stripe-api-call` 触发（`36681-36683`）。

`_testLatency`（`25641-25652`）：首次 API 后 2–2.5 s 起监听 `document.mousemove`，取前 10 个间隔（ms）上报一次即解绑。这 10 个数是**行为指纹**，与输入设备/DPI/负载相关。

---

## 5. 它信任帧返回的哪些字段

### 5.1 入口与校验强度

| 通道 | 注册处 | origin 校验 | 结构校验 | 信任的字段 |
|---|---|---|---|---|
| metrics 的 `m2` 回包 | `window`，`25586-25590` | `qZ(origin)`：`*.stripe.com`/`*.stripe.me`/`*.stripe.dev`/`*.link.com`/`onelink.com`（`16661-16740`） | 仅 `JSON.parse` + `originatingScript==="m2"` | `guid`、`muid`、`sid`（**直接当身份用**） |
| 控制器消息 | `window`，`36526-36533` | `J6("https://js.stripe.com", origin)` 同源精确匹配 | `Fi()` 要求 `__stripeJsV3===true`（`15117-15124`） | 见 5.2 |
| 帧动作响应 | 同上 | 同上 | `nonce` 对应 | `payload.faRes`（作为 `action.*` 的返回值） |
| 控制器动作响应 | 同上 | 同上 | `nonce` | `response`（进入商家可见的 Promise） |
| link 状态 | `25940-25970` | — | — | `outerPayload.state` |
| 用户凭据更新 | `46300-46310` | — | — | `publishableKey`、`stripeAccount` |
| 初始状态响应 | `46660-46690` | — | — | 整个 `res`，并记 `originFromMessageEvent` |

### 5.2 控制器实际消费的 action / 事件名（`36572-36720`）

`stripe-controller-origin-probe`、`stripe-frame-event`、`stripe-frame-action-response|error`、`stripe-outer-controller-action-request`、`stripe-frame-error`、`stripe-early-frame-error`、`stripe-integration-error`、`stripe-controller-load`(`controllerMetrics`)、`stripe-controller-action-response|error`、`stripe-controller-message-flush-ack`、`stripe-api-call`、`financial-connections-auth-flow-event`、`stripe-universal-link-modal-*`、`stripe-user-credentials-update`、`stripe-init-wanderlust`、`stripe-send-fraud-signals-to-captcha`、`easel-controller-message`、`stripe-controller-shim-ready`、`stripe-init-link`、`stripe-wrapped-accessory-message` 等。

### 5.3 结论

- **`guid/muid/sid` 是「一帧说了算」的软信任**：任何能拿到某个 `*.stripe.com` 子域（或 `*.link.com`）执行机会的东西都能改商家页的 mid；v3 只在写 cookie 时用 42 字符做了个弱过滤。
- 其余字段只走 js.stripe.com 严格同源 + `__stripeJsV3` 标记，伪造门槛高。
- `controllerMetrics` 是不透明对象，仅原样塞进 `init_timings` 上报（`38340-38358`）。

---

## 6. 新设备身份在这里怎么被消费

### 6.1 完整时序（写侧）

```
加载 stripe.js（无 new Stripe 也生效）
  └─ 40209: _ec = ht({stripeJsId: randomUUID, version})
       ├─ 25586: 注册 m2 监听（window）
       ├─ 1000 ms 后建 m-outer 帧，hash 带 url/title/referrer/muid=NA/sid=NA/version=6/preview
       │    └─ m-outer 建 m.stripe.network/inner.html（hash 透传）
       │         └─ inner 加载 out-4.5.45.js → POST https://m.stripe.com/6（15 特征 + 本页 url 哈希）
       │              └─ 200 {guid,muid,sid}（各 uuid+6hex，42 字符）
       │                   └─ postMessage 逐层回传（m-outer 用 "*"）
       │                        └─ _handleMessage → 写 __stripe_mid / __stripe_sid（商家域）
       └─ 5 s 轮询：href 变化 → ping（重新全量采集）；首个 API 调用 → ping + mouse timings
```

### 6.2 读侧（身份被带去哪）

| 目标 | 形态 | 证据 |
|---|---|---|
| 控制器帧 hash | `mids[guid|muid|sid]` 明文 | `37181`、抓包 `frames[0]` |
| 每次控制器 API 请求 | `ApiClient.setMids()` 注入 | controller.js@1642092 → `_apiClient.setMids(n)` |
| PaymentIntent 确认体 | `client_metadata:{guid,muid,sid}` | controller.js@1352945、@1353225（`Rw=["guid","muid","sid"]`@839450，白名单 `xj`@1381750，`${muid}#${guid}#${sid}` 缓存键@1381802） |
| PM 创建体 | 同上 + `referrer`(origin) + `time_on_page` + `pasted_fields` | controller.js@552354/552543/552700、@853857、@871210、@888180、@911325、@1473376、@1667821 |
| `radar_session` | `attachHCaptchaTokenToRadarSession({session,token,ekey,px3,pxvid,pxcts})` | `37594-37660` |
| Link 弹窗 URL hash | `mids` | controller.js@819251（`YI({…, mids: r.getMids() …})`） |
| Link httpOnly cookie | `stripe.link.persistent_token`，经 `checkout-cookies.stripe.com|checkout-cookies.link.com|merchant-ui-api.stripe.com/link` 的 `get-cookie|set-cookie|delete-cookie` | `24863`、`24945-24995`、`25218-25300`、`40177-40180` |
| 商家页全局 | `stripe._mids()` 可直取 `{guid,muid,sid}` | `40187-40191` |

### 6.3 各层的「新设备」持久物清单

| 层 | 名字 | 域 | 生存期 | 备注 |
|---|---|---|---|---|
| v3 写 | `__stripe_mid` | `.<商家 host>` | 365 d 滑动 | 非 HttpOnly，42 字符 |
| v3 写 | `__stripe_sid` | 同上 | 30 min | 非 HttpOnly |
| 帧写 | `m`（httpOnly） | `.m.stripe.com` | ~2 y | 真正的服务端锚点（见 `docs/stripe-refresh-on-launch.md §1.2`） |
| 帧写 | sessionStorage `1`/`_ab`/`_mf`/`id` | `m.stripe.network` | 每 tab | 抓包 `pre.ss` |
| 帧写 | `_px3`/`_pxvid`/`_pxcts` | `js.stripe.com`（human-security 帧） | 会话~长期（vendor 决定） | 由 hs.js 帧写入 |
| 第三方 | PayPal FraudNet / Klarna 自有 cookie | 各自 iframe 域 | vendor 决定 | 仅相应 PM 触发 |
| 页面级 | `stripeJsId`、`guid`、`_latencies`、`_cryptoWalletDetected` | 内存 | 页面 | — |

**关键判断**：`muid` 是「设备」，`sid` 是「会话」。清 `__stripe_mid` 而留 `m` 等于「新缓存、旧设备」；清 cookie 但 seed 不变等于「新 muid、同名设备指纹」。两者都不是「新设备」，只是两种不同的不一致。

### 6.4 confirm 之前 v3 会做的准备步骤（PaymentIntent / SetupIntent）

按 `stripe.confirmPayment` 实际执行顺序（`39068-39100`）：

1. 校验参数与状态冲突：`elements.submit()`/`elements.update()` 未完成时先 `report("elements_submit_conflict.confirm_payment")` 再继续（`39069`）；元素不属于本 Stripe 实例直接抛 `IntegrationError`（`39068`）。
2. `Wl.TL(params, controller, "confirm_payment_intent")` 解析"正在确认的元素"（`39079`）——这一步走 `stripe-frame-action` 到元素帧，会带上收集到的卡数据。
3. 若元素是 wallet，先 `action.createApplePaySessionIfNecessary({groupId})`（`39080-39082`）。
4. `mu(...)` 组装 `intentMutationRequest`：`intentSecret` + 四种互斥标签（`paymentMethod-from-data` / `paymentMethod` / `confirmationToken` / `none`）+ `handleActions` + **`mids`**；`none` 分支自动补 `use_stripe_sdk:true` 与 `mandate_data.customer_acceptance.online.infer_from_client:true`（`32440-32547`）。
5. 计时开始 `c.startApiCall()`（`39098`），然后 `action.confirmPaymentIntent(d)`（`39099`）→ 控制器帧 → `POST /v1/payment_intents/{id}/confirm`（controller.js@180221）。
6. 控制器侧把 `client_metadata:{guid,muid,sid,payment_user_agent,referrer,time_on_page,pasted_fields,networks,radar_options}` 拼进 body（controller.js@1352945、@1353225、@552354、@552543）；若站点配了 captcha，先 `outerAction.getCaptchaToken` 取 hCaptcha token 进 `radar_options.hcaptcha_token`，Human Security 开启时还会把 `px3/pxvid/pxcts` 合并进同一 `radar_options`（controller.js@930814、@930848、@927495）。
7. 返回 `requires_action` 且 `next_action.type==="use_stripe_sdk"` 时，才按 `captcha_vendor_name` 建 Human Security / Arkose lightbox 帧（`40576-40635`）；3DS2 则走 §3.4 的指纹帧后再挑战。

前端可做的只有第 3/4/5 步的**触发**，其余在帧内；所以「新设备」的关键不是这些步骤的代码，而是它们携带的 mids 与 `time_on_page`（从 `stripeJsLoadTimestamp` 起算，controller.js@552543）。

### 6.5 Link 专线

| 事实 | 证据 |
|---|---|
| 要求商家后端把 `stripe.link.persistent_token` 设成 **httpOnly** cookie；v3 在 live key 下若发现同名 cookie 是 JS 可读的就抛 `IntegrationError` | `40177-40180` |
| `stripe.link.persistent_token` 的值通过 `checkout-cookies.stripe.com/api/get-cookie|set-cookie|delete-cookie`（备用 `checkout-cookies.link.com/api/`、`merchant-ui-api.stripe.com/link/`）读写，请求带 `referrer_host`，read 带 2.5 s 超时、mutation 上限 8 | `24863`、`24855-24995`、`25217-25320` |
| 跨窗口 httpOnly 桥：`__stripeOuterHttpCookie` 标志 + 严格的字段白名单校验 `Ke()`（`kind: hello|ready|unavailable|request|response`、`operation: get|set|delete`） | `25019-25060` |
| 只有 `window.top===window` 且 origin 可信时才由外层页面托管该 cookie 桥 | `36534-36537` |
| `linkConsumerData` 从 `stripe.elements({__linkConsumerData})` 一路传给元素帧/API（`28531`、`29055`、`29355`） | 见左 |
| Link 弹窗打开 `https://checkout.link.com/`，hash 参数含 `publishableKey`、`stripeJsId`、`checkoutSessionId`、**`openedAt: Date.now()`**、支持的 PM/国家、`clientAttributionMetadata`，窗口名 `Link-<rand>`、几何来自 `outerWidth/outerHeight/screenX/screenY/availTop` | `46796-46812`、`46721-46750` |
| Link 弹窗 URL 再拼 `mids`（controller.js@819251） | 见左 |
| 控制器→outer 的 `link-state-change` 消息驱动 UI 状态（`25964`、`26783`） | 见左 |

对 AnyBrowser：Link 是**唯一把设备身份放到 httpOnly cookie 的地方**，且该 cookie 在商家域上——普通 cookie 清理（JS 侧）清不到它，必须用 CDP 按名全域删。另外 `openedAt` 与窗口几何会把「本机时钟」和「屏幕/窗口」直接带进 `checkout.link.com` 的 URL，属于同一套一致性约束。

---

## 7. 商家页能观察到什么（含可被竞品库读取的面）

| 观察点 | 具体内容 | 证据 |
|---|---|---|
| cookie | `document.cookie` 含 `__stripe_mid` / `__stripe_sid`（非 HttpOnly） | `24700-24707`；抓包 `page.cookie` |
| 隐藏 iframe | `iframe[name^="__privateStripe"]`，src 的 **hash 明文**含 `url/title/referrer/muid/sid/version/preview/parentOrigin/parentIsTop/mids` | `7923-7926`、`8092-8100`、抓包 `frames` |
| `window.frames` | 可按名字直取 `__privateStripeController1681` / `__privateStripeMetricsController…` | `7923-7926`（`Hn` 前缀+3 随机位+自增，`15487-15490`） |
| postMessage | m-outer 转发用 `targetOrigin="*"`，任何 `message` 监听器都能拿到 `{originatingScript:"m2", payload:{guid,muid,sid}}` | mouter.js 全文 |
| 私有 API | `stripe._mids()`、`stripe._ec`（MidSid 实例）、`stripe._apiKey`、`stripe._version`、`stripe._stripeObjId`、`stripe._controller._stripeJsId` | `40187-40199`、`38640`、`37143` |
| DOM 注入 | `<meta name="__privateStripeMeta<3位><n>" http-equiv="origin-trial" content="…">` | `41440` |
| 网络 | `m.stripe.com/6`、`q.stripe.com?…`、所有控制帧请求（商家可看 URL/时序，body 需 devtools） | 抓包 |
| 全局标记 | `window.__SJS_PERF_STATE__`（flag 开时）、`window.Stripe.version===3`、`window.Stripe.StripeV3` | `15906-15908`、`40209-40214`、`40245` |
| 请求头 | `Sec-CH-UA-Platform: "macOS"`、`Sec-CH-UA: "Chromium";v="148","Google Chrome";v="148","Not/A)Brand";v="99"`、`Sec-CH-UA-Mobile: ?0`、`Referer: https://m.stripe.network/` | 抓包 `postData` 同级 `headers` |
| 上游上报体 | UA 全串、`MacIntel`、`en-US,en`、`800w_600h_24d_1r`、`-8`、字体 55 位串、canvas md5、URL 哈希、`time_on_page`、`pasted_fields` | 抓包 + `findings/payload.md` |

**注意**：`q.stripe.com` 的 `Image` 埋点只用于「不支持的浏览器」判定（`37691-37697`、`38686-38696`），查询串里带**明文 apiKey**、`hashedKey`、`isAffectedBrowser`、`mechanism/action/state`。**v3 不上报 `r.stripe.com/b`**（全文 0 命中；`r.stripe.com/b` 只出现在 Link/Checkout 这类托管页自己的 analytics.js，`signup-capture.json` 的 `analytics[]` 可证）。v3 的 `report()` 走的是「控制器帧 → `track` 消息 → `m.stripe.com/{version}`」（见 §3.3 第 7 步）。

---

## 8. AnyBrowser 方案

排序：P0 = 不做就一定暴露；P1 = 显著降低一致性；P2 = 打磨。

### P0-1 屏幕与窗口必须自洽（当前最大的硬矛盾）

**现状**：抓包显示 `screen=800×600 @1x`，而 `innerWidth×innerHeight=1400×779`——窗口比屏幕还大。`IdentitySampler` 把 `screenSpoofingSupported=false`（`Sources/AnyBrowserCore/IdentitySampler.swift:131`），所以完全不设这些字段；`Profile.swift:353-402` 虽然已经会传 `--fingerprint-screen-width/height`、`--fingerprint-device-scale-factor`，但采样器从不填值。姊妹报告已有独立探针结论：**这三个开关在本引擎窗口模式下不改变 `screen.*`**（`/tmp/stripe-plan-v2/collector.md §0.8`，探针 `win-screen-a/b.json` 同值）。

**含义**：Stripe 的 `f` 字段（`ScreenSizeExtractor`，`mod-23`）在本机抓包的两档里都是同一串 `800w_600h_24d_1r`（同 seed）；既然采样器从不写屏幕字段，**同一 seed/同一宿主下所有 Profile 的屏幕串相同**，Profile 之间在屏幕维度零区分；且 `innerWidth > screen.width` 是肉眼可见矛盾；`window.outerWidth/outerHeight`（`46722`）也会参与弹窗定位。

**要做什么**（按代价从低到高，1 必须先做）：
1. **先把窗口装进屏幕**：`--window-size` 改为按引擎实际报告的 `screen` 推导，`width ≤ screen.width`、`height ≤ screen.height - 80`，`x/y` 落在 `0…screen.width-window.width`、`0…screen.height-window.height`。当前 `LaunchOptions.window` 默认 nil（`LaunchOptions.swift:24`），Chromium 自选默认尺寸，必然和 800×600 打架。这样即使屏幕开关无效，至少不自相矛盾。
2. 想让 Profile 之间**在屏幕维度分开**，需要引擎之外的手段：启动后 CDP `Emulation.setDeviceMetricsOverride`（可给 `width/height/deviceScaleFactor`，且 `screenWidth/screenHeight` 参数会改 `screen.*`）——但要接受它与 `--fingerprint-*` 的叠加语义，先小样本验证 `screen`/`outerWidth`/`innerWidth` 三者的联动。
3. 更彻底的是给引擎补 `Screen` patch（`--fingerprint-screen-width/height` 真正接线）。在补丁落地前，采样器不要打开 `screenSpoofingSupported`。
4. `deviceScaleFactor` 与平台绑定：macOS 无外接屏时通常 2；Windows/Linux 1 或 1.25/1.5。禁止 macOS + 1x + 800×600 这种三连。
5. `availWidth/availHeight/colorDepth` 没有引擎开关（二进制 strings 只到 `fingerprint-screen-width|height|device-scale-factor`），`FingerprintConsistency` 应把它们标成「跟随宿主」而不是静默。

**验收**：`live-on` 抓包里 `f` ≠ `800w_600h…`，且 `page.screen[0..3]` 与 `page.iw/ih` 满足 `iw ≤ screen[0]`、`ih ≤ screen[1]`。

### P0-2 时区 / 语言 / 地理三元一致

**事实**：`Intl.DateTimeFormat().resolvedOptions().timeZone`（controller.js@550497）→ `browser_timezone` 进每一条控制器请求；`getTimezoneOffset()/60` → out.js 的 `g`；`navigator.languages[0]` → `navigator_language` + `browser_locale`（controller.js@1656483、@1366035）；`Accept-Language` 头独立存在。

**要做**：
- `--timezone`、`--lang`、`--accept-lang`、`-AppleLanguages` 必须由**同一个 locale profile** 生成（现在 `IdentitySampler.localeProfiles` 已经这么做，保持）。
- 三者必须与出口 IP 国家一致；`FingerprintConsistency` 目前已有「语言与出口」类检查，补充「时区 ↔ 出口」「时区 ↔ languages[0] 的区域」。
- 注意 `en-US` 必须配 `America/*`，不能配 `Asia/Shanghai`。

**验收**：`new Date().getTimezoneOffset()/60 === -8` 与 `Intl…timeZone === "America/Los_Angeles"`、`navigator.language === "en-US"`、`Accept-Language` 首项 `en-US` 同时成立。

### P0-3 touch 是死字段，且判定后果不对称

`IdentitySampler.swift:184` 设 `fingerprint.touch = false`，但 `Profile.swift arguments()` 从不使用 `touch`；引擎也没有 touch 开关（二进制 strings 无 `fingerprint-touch`）。v3 的 iPad 判定是 `macintosh && (maxTouchPoints>0 || "ontouchstart" in window)`（`11265`），命中后 `w.yS=true` → 每个控制器请求带 `mobile:true`、`deviceType="mobile"`，而 UA 仍是 Macintosh。

macOS 真机本来就 `maxTouchPoints=0` 且无 `ontouchstart`（抓包 `a.h="false"` 与 `a.d="MacIntel"` 一致），所以 **macOS 档今天不自曝**。风险在：
- `platform=windows` 档：Windows 触屏本会同时有 `maxTouchPoints>0` 和 `ontouchstart`，此时 v3 前台仍按 UA 判 `Win32`（非 macintosh），不受 iPad 分支影响；但 `a.h`（TouchSupport）会变 `"true"`，与窗口尺寸/设备类型联动，必须与「笔记本 vs 台式」的设定一致。
- 任何将来开启触摸仿真的改动会把 macOS 档推进 iPad 分支。

**要做**：在 `FingerprintConsistency` 加约束：`platform==macos ⇒ maxTouchPoints==0 && !("ontouchstart" in window)`；windows/linux 允许 true，但必须与 `a.h` 和 `deviceType` 同源。若要精细控制，补 `--touch-events=disabled|auto`（Blink 开关，只影响事件可用性；`maxTouchPoints` 仍需实测）。

### P0-4 身份载体与 seed 必须成对演进

**事实**：`__stripe_mid` 365 天滑动、写入商家域、42 字符闸门；`m`（`.m.stripe.com`，httpOnly，2 年）才是服务端锚点（`docs/stripe-refresh-on-launch.md §1.2`）。

**要做**（按现有 `stripeRefresh` 档位矩阵落）：
- 默认 `stable-device`：保 `__stripe_mid`/`m`，只让 `__stripe_sid` 自然过期。
- 「新建 Profile / 换 seed」时自动升级为 `full-reset`，并且**按 cookie 名全域清**（`__stripe_mid`/`__stripe_sid`/`m`/`machine_identifier`/`private_machine_identifier`）+ 清 `.m.stripe.com`/`.stripe.com`/`.checkout.stripe.com` 全域名 + 各 vendor 域（`js.stripe.com` 的 `_px*`）。
- 禁止「清 cookie 不换 seed」和「换 seed 不清 cookie」两种错配；在 `FingerprintConsistency` 里把二者绑成一条规则。
- `localStorage` 无（v3 为 0），`m.stripe.network` sessionStorage 随 tab 消亡，无需单独处理；要动就整 origin 清。

### P1-1 时钟

`Date.now()` 被测得与 `performance.timeOrigin+now()` 相差 >3 ms 时会改用后者（`16459-16465`）；`stripeJsLoadTime` 是裸 posix 毫秒送进帧 hash。若将来给 Profile 固定时钟，必须同时保证两者差值 <3 ms，否则立刻露馅。目前 `--timezone` 不影响时钟，保持即可，但**不要**引入「spoof 时间」而不补 `performance.timeOrigin`。

### P1-2 扩展集与 EIP-6963

v3 在 `new Stripe()` 时 dispatch `eip6963:requestProvider`（`36558`），把 `wallet_name` 逐个上报；命中即 `cryptoWalletDetected=true` 并写进 PAYMENT_ELEMENT 帧参数。

**要做**：
- Profile 的 `sharedExtensions` 决定钱包名单；**同组 Profile 用同一扩展集**是「同一台机器装同一批扩展」的合理形态，但若所有 Profile 全量装载同一套，等于多一个恒定维度。
- 至少在 `FingerprintConsistency` 里提示「扩展集相同 → EIP-6963 名单相同」，并给出「无钱包 / 单钱包 / 多钱包」三档。
- Passkey Box 会改 `PublicKeyCredential` 行为（3DS WebAuthn 资格 `41313`），同档处理。

### P1-3 禁用采集的取舍

脚本 URL 上可挂 flag（`24739-24748`）：`_1776170249=false` 让 MidSid 不建帧、不读不写 cookie（`he=false`）；`_362609697=true` 让 `_ec` 直接为 null（`40209`）。

- 只要默认加载方式，**不要关**：关了就没有 `__stripe_mid`，Radar 失去设备锚点，反而不像真实 Chrome。
- 仅在「一次性、用完即弃」的活动页（无需 Radar 复访）上可考虑 `_362609697=true`，且同一入口保持一致，不要混用。

### P1-4 canvas / 字体 / 音频是真正的高熵面（虽在 iframe）

`id = md5(15 个 value)`（`mod-06`），抓包可读到同一 seed 下 on/off 两次的 `id` 完全相同（`016a48e7e5056afc8a99fc73674f8ba5`）。说明 `--disable-spoofing` 只切类别，不切 seed；**seed 是唯一变量**。

**要做**：
- 每个 Profile 唯一 seed（已有）。
- 默认 `adjustments` 打开 `.canvas` 与 `.audio`（已有，`IdentitySampler.swift:188`）。
- 把 `.font` 也打开——否则 macOS 字体表被 Windows/Linux 身份直接读出（`FingerprintConsistency.swift:173-179` 已有告警，但默认不修）。
- 验收：两个不同 seed 的 Profile 在 `live-on` 里 `a.o`（canvas md5）与 `a.j`（字体串）都不同。

### P2-1 嵌入形态

如果 AnyBrowser 用外层容器 iframe 包住商家页，`parentIsTop`（`37176`）、`parentOrigin`、`parentProtocol` 都会变，且 v3 会打 `It looks like you are using Payment Element in an iframe`（`29029`）。保持顶层加载最简单。

### P2-2 观察面自身不要制造噪声

商家页可读 `stripe._mids()`、`document.cookie`、帧 hash。若 AnyBrowser 注入脚本去读这些，注意时机：`_mids()` 在首个 `m2` 回包前是 `{guid:"NA",muid:"NA",sid:"NA"}`。校验脚本应等 `__stripe_mid` 出现或轮询 `_mids().muid !== "NA"`。

### P2-3 `preview` 分支

`preview=true` 只在 top URL 属于 stripe/link 域时出现（`25686`，`qZ`）。商家页永远 `false`；若 AnyBrowser 内置 Stripe 托管页测试，记得 `inner-preview.html` 与 `inner.html` 内容相同，只是文件不同。

---

## 9. 运行时验证清单（全部可 CDP/抓包完成，不改引擎）

1. **首帧 hash**：新 Profile 打开任意带 stripe.js 的页，`target=_blank` 抓所有 `iframe[name^=__privateStripe]` 的 `src`；断言 metrics 帧 hash 里 `muid=NA&sid=NA&version=6`，且 `referrer` 等于页面 URL。
2. **6 秒后**：断言出现 `__stripe_mid`（42 字符）与 `__stripe_sid`，`domain=.host`，`SameSite=Strict`，`httpOnly=false`。
3. **`m.stripe.com/6`**：断言 body 解码后 `b.d/b.e` 非 `NA`，且 `a.f` 与 `screen.width/height` 一致、`iw ≤ screen.width`。
4. **UA 一致性**：`Sec-CH-UA-Platform`、UA 里的 OS token、`navigator.platform`、`a.d`、`a.l` 必须同源；`a.f`（屏幕）另与 `screen.*` 对齐。
5. **mobile**：controller 帧 hash 无 `mobile=true`；`navigator.maxTouchPoints===0`；`"ontouchstart" in window===false`。
6. **`browser_timezone`**：任一控制器请求（或 `elements/sessions`）里该值 = `Intl…timeZone` = 反解 `a.g` 的时区 = 出口国家。
7. **EIP-6963**：`window.addEventListener("eip6963:announceProvider")` 后 `dispatchEvent(new Event("eip6963:requestProvider"))`，记录名单；断言与 Profile 扩展集一致。
8. **时钟**：`Math.abs(performance.timeOrigin+performance.now()-Date.now())` 连续采样 <3 ms。
9. **`_mids()` 时序**：`stripe._mids().muid` 由 `NA` 变为 42 字符；之后 confirm 体里 `client_metadata.muid` 与之相等。
10. **Profile 对照**：同 seed 两 Profile 的 `id` 应相同（验证「同设备」）；不同 seed 应不同（验证「新设备」）。

---

## 10. 未解 / 需要实测的点

1. `--fingerprint-screen-width/height`、`--fingerprint-device-scale-factor` 在 148 上是否真的改写 `screen.*`：现有两面证据（`IdentitySampler.swift:129-132` 注释 + 姊妹报告探针 `win-screen-a/b.json`）都指向「不生效」，仍需一次带 `screen.*` 断言的复测来钉死结论。**这是 P0-1 的前置**。
2. `screen.availWidth/availHeight/colorDepth` 是否随上面的开关联动；无开关时是否恒为宿主值。
3. `--touch-events=disabled` 是否同时归零 `maxTouchPoints` 与 `ontouchstart`。
4. `.m.stripe.com` 的 `m` cookie 在 148 + 默认三方 cookie 策略下的实际写入/携带行为（本机抓包 `setCookie` 为 `null`，可能被策略拦）。
5. `cookie.w`/`b.b`/`b.c` 三个哈希的盐与分区规则（属 out.js，另一份报告）。
6. 「自造 42 字符 muid 预置」服务端是否认领——未验证（已知结论）。
7. `localhost` / 纯 IP 主机下 `domain=.localhost` / `.127.0.0.1` 的 cookie 落盘结果。

---

## 11. 证据索引

**v3_beauty.js（= `/tmp/stripe-js-dl/v3_plain.js` 的同串可检索格式化副本）**

| 主题 | 行 |
|---|---|
| URL 构造器 | 15084-15087 |
| 帧类型枚举 | 14636-14718 |
| 帧文件名 switch（含 m-outer / 3DS2 / controller） | 14764-15078 |
| webpack chunk 名 | 49047-49113 |
| `_createIFrame` hash 拼装 | 8070-8100 |
| 控制器 appParams（含 parentIsTop/parentOrigin/mids/referrer） | 37167-37185 |
| 外置 logger 参数 | 37986-38000 |
| MidSid 构造 / 标志位 / m2 处理 / cookie / ping / 延时 | 25497-25762 |
| 脚本 flag 解析（`he/ve/ge/ye`） | 24459-24468、24720-24748 |
| `_extractUrl` / `_extractMetaReferrerPolicy` / `_buildFrameQueryString` | 25653-25692 |
| cookie 读 `le` / 写 `ce` | 24696-24719 |
| 42 字符 `pt` / `mt` | 25501-25506 |
| `mids` 序列化 `lK` | 13754-13766 |
| `_mids` / `_midsPromise` / `lv._ec` | 40187-40214 |
| `stripe-api-call` → `vt()` | 36681-36683 |
| EIP-6963 探测 | 36539-36568、37207-37212、36274 |
| 时钟偏移校验 | 16459-16465 |
| 性能观察器 / init_timings | 15934-15962、38327-38360 |
| q.stripe.com Image 埋点 | 37691-37697、38686-38696 |
| UA / touch / brave / standalone / languages | 11238-11442、11581 |
| 弹窗几何 | 6936-6963、46721-46750 |
| SPC / WebAuthn 资格 + origin-trial meta | 41306-41360、41431-41465 |
| 3DS2 指纹帧 | 41188-41295 |
| PayPal FraudNet / Klarna 帧 | 32244-32285、43536-43575 |
| Human Security / hCaptcha 帧 + 事件流 | 6020-6060、6096-6110、6505-6516 |
| wanderlust 帧与广播 | 35209-35230、37063-37095 |

**抓包（只读 JSON）**

| 主题 | 位置 |
|---|---|
| metrics 帧真实 hash（`muid=NA&sid=NA&version=6&preview=true`） | `live-stripe-capture.json` `frames[1].url` |
| inner 帧与 `stripeM.sid`（42 字符三值） | 同上 `frames[2].info.sid` |
| 控制器帧 hash 全参数 | 同上 `frames[0].url` |
| 6 值 payload（`v2:1`,`a.a..o`,`b.*`） | `live5-on-828282.json` `requests[?].postData`（base64+URL 编码） |
| 页面 cookie（`__stripe_mid=<uuid+6hex>`、`__stripe_sid`） | 同上 `page.cookie` / `cookies[]` |
| 请求头（`sec-ch-ua*`、`Referer: https://m.stripe.network/`） | 同上 `requests[?].headers` |
| `r.stripe.com/b`（Link 页，非 v3） | `signup-capture.json` `analytics[]` |

**帧内脚本（curl 原样，未执行）**

| 文件 | 内容 |
|---|---|
| `/tmp/stripe-v3work/mouter.html` / `mouter.js` | 524 B 中继：`preview` 选择 inner 页、hash 透传、`"*"` 转发 |
| `/tmp/stripe-v3work/inner.html` / `inner-preview.html` | 930 B，字节相同；自启 `StripeM.p({t:!0,v:<version>})`；处理 `ping`/`track` |

**控制器侧（`/tmp/stripe-ctrl-dl/controller.js`，one-line，用偏移）**

| 主题 | 偏移 |
|---|---|
| `Intl…timeZone` → `browser_timezone` | 550497、1274182、1301141、1337131 |
| `navigator_language` 进默认参数 | 1656483 |
| `unverifiedReferrer` 计算（`document.referrer` 优先，失败读 frame hash） | 162884-163122 |
| `getPaymentMetadata` = `{payment_user_agent, referrer, time_on_page}` | 552354、552543 |
| `pasted_fields` 进 PM 体 | 1352945、1667821 |
| `getMids` / `setMids` | 1369308；`midsChange` 注入 1642092 |
| `guid/muid/sid` 白名单 + `muid#guid#sid` 缓存键 | 839450、1381750、1381802 |
| Link 弹窗 URL 带 mids | 819251 |

**仓库现状**

| 主题 | 位置 |
|---|---|
| 屏幕/DPR 参数已能传但采样器不填 | `Sources/AnyBrowserCore/Profile.swift:353-402`、`IdentitySampler.swift:129-132` |
| `touch` 是死字段 | `Profile.swift:139`、`IdentitySampler.swift:184` |
| 字体平台不匹配告警 | `FingerprintConsistency.swift:167-179` |
| `stripeRefresh` 档位与 cookie 清理算法 | `docs/stripe-refresh-on-launch.md §1.3、§3.1` |
| 引擎可用开关全集（无 touch/avail/colorDepth） | 二进制 strings：`fingerprint-screen-width`、`fingerprint-screen-height`、`fingerprint-device-scale-factor`、`fingerprint-platform*`、`fingerprint-brand*`、`fingerprint-hardware-concurrency`、`fingerprint-location`、`disable-spoofing`、`fingerprinting-canvas-image-data-noise`、`fingerprinting-canvas-measuretext-noise`、`fingerprinting-client-rects-noise` |