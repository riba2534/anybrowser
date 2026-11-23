# Stripe 身份链：muid / guid / sid 的生成、持久化与重置面

分析对象：Stripe 反欺诈采集器的完整身份链路，从 `m.stripe.network` inner 页 → `m.stripe.com/6` POST → `{muid,guid,sid}` 响应 → `m2` postMessage → js.stripe.com `m-outer` 中继 → v3 `MidSidManager`（本版本的类名已被压缩，实际是 `_t`）。

所有外部代码只做静态阅读，未 `node` 执行。网络证据来自本机 curl 与真实引擎内的 CDP 探针（2026-11-22，UTC 19:22–19:40）。

## 0. 结论摘要

1. **guid / muid / sid 全部由服务端 `m.stripe.com` 生成**。客户端只在两处“自造”：`he` 关闭时用 `crypto.randomUUID()` 造 36 字符占位，和 `checkoutIds` 存在时直接用 Checkout 下发值。`guid` 没有任何客户端 cookie，只存在内存 `_guid`。
2. **guid 的服务端锚点是 `m.stripe.com` 的 HttpOnly cookie `m`（2 年，SameSite=None，Secure，host-only，值 == guid）**；muid 的客户端锚点是**商家域上的一方 cookie `__stripe_mid`（365 天，SameSite=Strict，JS 可写，非 HttpOnly）**，sid 是同一域的 `__stripe_sid`（30 分钟）。
3. `b.d` / `b.e` 是客户端把当前 muid/sid 回填给服务端的字段。服务端**按字段逐个校验**：合法 42 字符（小写 uuid36 + 6 位小写 hex）原样回显；36 字符 UUID 会被补 6 位后缀；其它一律换新。
4. **本引擎（fingerprint Chromium 148）默认阻断第三方 cookie**：`m` 的 Set-Cookie 被直接丢弃，`Network.getAllCookies` 里没有它。于是**每次页面加载 guid 都会变**，只有一方 `__stripe_mid` 提供跨加载的 muid 连续性。这一点用真实引擎 + 真实 js.stripe.com 复现了两轮。
5. 客户端**没有任何“跳过 POST”的路径**。`ping=false` 是 inner.html 的开关，但 v3 从不发送它；能省的只有 payload 里的特征数组 `a`（同标签页 sessionStorage `id` 命中时）。`he=false`（脚本 URL 参数 `_1776170249=false`）才是完全不起 frame、不发 POST 的模式。
6. 要真正得到一套新 ID：清所有域的 `__stripe_mid`/`__stripe_sid` + 清 `m.stripe.com` 的 `m`（本引擎下不存在，但换引擎/开启 3PC 后必须清）+ 清 `m.stripe.network` 的 sessionStorage（`id`/`_ab`/`_mf`）；并且必须换指纹 seed，让 `id`（特征 md5）也不同。
7. 只清 `__stripe_mid` 不清 `m` = 新 muid 挂在旧 guid 下；只清 `m` 不清 `__stripe_mid` = 旧 muid 挂在新 guid 下。两者都能被服务端关联。
8. Stripe 侧的关联面：`m`→guid、muid 回填、API 请求里的 `mids`（含 `guid#muid#sid` 的 RadarSession 与 Checkout URL fragment）、`payment_user_agent`、referrer、以及每次 POST 里的特征 md5 `id`；再叠加 IP/TLS/Link/hCaptcha。

---

## 1. 逐跳链路（含精确证据）

### Hop 0：谁把 muid/sid 交给 frame

`https://js.stripe.com/v3/m-outer-<hash>.html#url=…&title=…&referrer=…&muid=…&sid=…&version=6&preview=…&__shared_params__[version]=v3`

- 拼装：`/tmp/stripe-plan-v2/work/v3.pretty.js:25674-25691`（`_buildFrameQueryString`，字段顺序 `url,title,referrer,muid,sid,version:6,preview`），frame 类的 hash 追加 `referrer`、`controllerId`，见同文件 `:8080-8096`。
- 实测（引擎内 CDP，第二轮加载）：
  `…m-outer-0edadf75b42c6ef7240c043f3272f3f9.html#url=http%3A%2F%2F127.0.0.1%3A8801%2Ftop%2Fstripe2.html&title=&referrer=&muid=78c03501-2008-45d8-89aa-7da33d2bbb9a19812f&sid=8dfaa67e-0d06-4274-801b-d5ba027aa5c3a4bce6&version=6&preview=false&__shared_params__[version]=v3`
  第一轮是 `muid=NA&sid=NA`。→ 旧值通过 URL 明文交给 js.stripe.com 与 m.stripe.network 两个源。
- muid/sid 的来源：构造函数里 `_getID("merchant")` / `_getID("session")`，`:25527-25529`；`_getID` 读 cookie，`:25692-25731`。
- `__checkout.mids` 存在时走 `checkoutIds`，`:25527-25529` 与 `:38717-38721`（`ht({checkoutIds:A.mids,…})`），并置 `_doNotPersistMuid/Sid`，不再碰 cookie。

### Hop 1：m-outer 纯中继（524 B，实抓）

`/tmp/stripe-plan-v2/work/m-outer.js`（单行，524 B，byte offset）：

- `32`：`var e="https://m.stripe.network"`
- `60`：`n=window.location.hash`
- `84`：`/preview=true/` 决定 `inner-preview.html` 还是 `inner.html`
- `128`：创建 `<iframe src="https://m.stripe.network/inner.html"+n>`（**原样复制 hash**，不增删参数）
- `239-311`：`message` 监听——`if(n.origin===e){ … t.postMessage(n.data,"*") } else { o.contentWindow.postMessage(n.data,e) }`

方向：来自 m.stripe.network 的消息**向上**转发给 `opener||parent`（js.stripe.com 页面 → 商家页）；其它来源的消息**向下**灌进 inner iframe。**没有 event.source 校验**，也没有 origin 白名单（只比对字符串常量 m.stripe.network）。

### Hop 2：inner.html 自动 ping

`/tmp/stripe-re-20261122/inner.html`（930 B，单行）：

- `248`：`/ping=false/.test(e)` 是唯一的 POST 跳过开关。
- `284`：`/version=(4|6)/` 从 hash 取版本，否则 `"4"`。
- `318-334`：脚本 onload 后无条件 `window.StripeM.p({t:!0,v:e})`。
- `490-604`：入站消息处理，`case"ping"` → `StripeM.p({t:!0,o:{muid,sid,referrer,url,title,v2},v:t.version||"4"})`；`case"track"` → `StripeM.b({muid,sid,url,source,data},…)`。

**v3 全文件 0 次 `ping=false`**（grep v3_plain.js / shared.js / controller.js 均为 0）。结论：每次加载 inner.html 必发一次 POST。

### Hop 3：入口导出

`/tmp/stripe-out-4.5.45/beautified.js:5781-5809`：`deviceId=r.a`（模块 6 的 `S`）、`extract=r.b`（空实现）、`p=_.b`（模块 10 的 `E`）、`b=_.a`（模块 10 的 `h`）。
`E` = `getDevice(...).catch(beaconErrorHandler)`（`:2282-2305`）；`h` = 直接 `safeBeacon`（`:2307-2323`）。

### Hop 4：payload 里如何携带 muid/sid

`beautified.js:1329-1348`（`buildPayload`）：

```
f=i.sid; s=i.muid; … s&&(v.d=s,delete i.muid); f&&(v.e=f,delete i.sid);
```

即 muid → `b.d`，sid → `b.e`，随后从 `o` 里删掉（非遥测分支 `o` 就不带它们）。`"NA"` 是真值，也会被写入。特征值串 `md5` → `id`（`:1327`）。

### Hop 5：POST

`beautified.js:5611-5638`（模块 29）：`POST https://m.stripe.com/"+version`，`withCredentials=!0`（:5617-5619），`send(body)`，body = `btoa(encodeURIComponent(JSON.stringify(payload)))`（:2251-2258）。成功条件仅 `status===200`，并写 `window.StripeM.__sid = responseText`（:5626-5629）。

### Hop 6：响应 → m2

`beautified.js:2213-2242`：`opener||parent||win`；`isValidIframePostMessage` 用 `/^{"muid":"[\w-]+","guid":"[\w-]+","sid":"[\w-]+"}$/m`（`beautified.js:171-179`）校验响应；通过则 `postMessage({originatingScript:"m2",payload:{guid,muid,sid}},"*")`，解析失败降级为 `originatingScript:"m"`。无 origin 校验、targetOrigin 恒 `"*"`。

### Hop 7：m-outer 上抛 → 商家页

见 Hop 1 的 `239-311`。event.origin 此时是 `https://js.stripe.com`（m-outer 所在源）。

### Hop 8：v3 `_t` 的消息处理与落盘

`v3.pretty.js:25510-25526`：

```js
_handleMessage = (done) => (t) => { if (qZ(t.origin) && typeof t.data=="string") try {
  var a=JSON.parse(t.data), i=a.originatingScript, s=a.payload;
  if("m2"===i){ o._guid=s.guid; o._muid=o._getID("merchant",s.muid); o._sid=o._getID("session",s.sid); o._onIdsUpdate?.(o.ids()); done() } } catch{} }
```

- origin 校验 `qZ`：允许 `*.stripe.com|stripe.me|stripe.dev` 与 js.stripe.com/link.com 等（`:16678-16686`，`:16661-16665`）。`m.stripe.network` 属于 `.stripe.com` 后缀，放行；**不校验 event.source**。
- `guid` 只写内存 `_guid`，**不落任何 cookie/存储**。
- `_getID` 的回写：`v3.pretty.js:24691-24707`（`ce`）→ `document.cookie = "<name>=<value>;expires=<…>;path=/;SameSite=Strict"`（https 时加 `;secure`，带 `;domain=.<hostname>`，`expiresIn` 缺省 31536e6 ms = 365 天）。

### Hop 9：mids 外送

`ids()` 返回 `{guid,muid,sid}`（`:25536-25543`）。消息通道建立后转成 controller 的 `midsChange`（`:38329-38332`、`:38438-38440`），controller 的 ApiClient 保存 `setMids`（`/tmp/stripe-ctrl-dl/controller.js` byte 1369261）并附到请求：

- RadarSession 默认 data = `{...mids, referrer, payment_user_agent}`（controller.js byte 1363758 起 `radarSessions.create` 的 `defaultParams`）。
- 显式形态：`muid#guid#sid` 或 `explicit:<JSON>`（controller.js byte 1382270）。
- `create_payment_method` / `create_confirmation_token` 等路径带 `mids`（controller.js byte 1569207、1576234 等）。
- Checkout 会话 URL fragment 里序列化 `{apiKey, stripeAccount, mids, …}`（controller.js byte 819244、`YI`）。

---

## 2. 生成 / 持久化矩阵

| 值 | 谁生成 | 客户端持久化 | 域 / 宿主 | 属性（证据） | 生命周期 |
|---|---|---|---|---|---|
| `guid` | 仅服务端（响应体 `guid`，与 Set-Cookie `m` 同值） | **无**，仅内存 `_guid`，初值 `"NA"`（`:25500`、`:25529`、`:25522`） | — | — | 页面级；每次 POST 可被覆盖 |
| `muid` | 服务端；客户端可“提议”合法值被回显；`he=false` 时 `crypto.randomUUID()` 兜底 | cookie `__stripe_mid` | `.<document.location.hostname>`（商家域，一方） | `path=/`、`SameSite=Strict`、https 下 `Secure`、**无 HttpOnly**、**无 Partitioned**、`expires=+365d`（`:24701-24706`、`:25700-25708`） | 365 天，每次响应滑动续期 |
| `sid` | 同上 | cookie `__stripe_sid` | 同上 | 同上 + `expiresIn:18e5`（=1 800 000 ms = **30 分钟**）（`:25715-25723`） | 30 分钟滑动 |
| `m` | 服务端 Set-Cookie | HttpOnly cookie | `m.stripe.com`，**host-only**（无 Domain） | 实测头：`set-cookie: m=<guid>;Expires=<+2y>;Secure;HttpOnly; SameSite=None`；**无 Partitioned** | 2 年，每次 POST 重设 |
| `__sid`（内存） | — | `window.StripeM.__sid` 存整个响应文本 | m.stripe.network 帧内存 | — | 页面级 |

实测证据（curl，2026-11-22）：

- 首次请求响应体 `{"muid":"64481946-…832a7","guid":"30db7444-…a82699","sid":"2a7089d1-…40952a"}`，Set-Cookie `m=30db7444-…a82699`，`m` 与 `guid` 逐字节相等（`/tmp/stripe-plan-v2/work/resp1.headers`、`a.headers`、`P2.headers` 复核）。
- 服务端把 `m` 当唯一 guid 输入：带 `Cookie: m=<G>` 时响应 guid 恒为 `<G>`；不带时每次新 guid（`b.headers`、`J.headers`）。
- `Cookie: __stripe_mid=…; __stripe_sid=…` 对服务端**完全无效**，仍发新值（`e.headers`/`e.body`）；服务端只认 `b.d/b.e` 与 `m`。
- 服务端校验是**逐字段、按格式**：42 字符合法值原样回显（`N`、`P`、`R`、`S`）；36 字符 UUID 补 6 位小写 hex（`H`、`K`、`M`，同值补出同样后缀）；30/50 字符、“a”*42、大写 hex（`Q`）一律换新。→ **客户端只查 42 长度（`pt`，`:25501-25503`），服务端还查形状**：`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[0-9a-f]{6}$`（推断正则，依据 6 组实测）。
- 服务端固定回 `access-control-allow-origin: https://m.stripe.network`，与请求 Origin 无关，无 Origin 也照常处理。

## 3. Web 存储键

只有 m.stripe.network 源下的 sessionStorage（`MStorage` 默认 `"sessionStorage"`，`beautified.js:141-152`）：

| 键 | 写入点 | 值 |
|---|---|---|
| `id` | `beautified.js:1352-1353` | 15 个特征值 join 后的 md5；仅用于判断是否再发 `a` |
| `_ab` | adblock extractor，模块 28 常量 | 0/1 结果缓存 |
| `_mf` | fonts extractor，模块 18 常量 | 字体位图缓存 |
| `muffins` | AvailableStorageExtractor 写后即删（`modules-pretty/mod-12.js:21-22`） | 探针，不残留 |

v3 的 metrics 路径**零** localStorage/sessionStorage/IndexedDB。`beautified.js` 全文件 0 个 cookie 名。

## 4. CHIPS / 第三方 cookie：代码说一套，引擎做另一套

- `m` 不带 `Partitioned`，因此**不是 CHIPS cookie**：3PC 放开时它是全站共享的普通第三方 cookie；3PC 封锁时它根本不存在；“仅 CHIPS”模式下也不会存活（服务端没加 `Partitioned`）。请求本身发生在两层第三方帧里（商家页 → js.stripe.com 的 m-outer → m.stripe.network 的 inner），3PC 判定以顶层站点为准。
- `__stripe_mid/__stripe_sid` 由 `document.cookie` 写，位于页面自身源 → 一方 cookie，天然不受 CHIPS 影响；`document.cookie` 也无法加 Partitioned。
- 引擎实测（bundled Chromium 148，同一二进制；`m` 不落盘在 headless 与窗口两种模式各复现一次，跨站读写探针在 headless 下完成）：

  | 探针 | 结果 |
  |---|---|
  | 第三方 iframe（localhost 嵌 127.0.0.1 或反之）写/读 `document.cookie` | `write-ok read=""` → **3PC 阻断** |
  | 同站 iframe 对照 | `read="probe=one"` |
  | 真实 v3 页面 + `Network.getAllCookies` | jar 里只有 2 个 127.0.0.1 的一方 cookie，**没有 m.stripe.com 的 `m`** |
  | 同一 Profile 连开两次真实 v3 页面 | muid/sid 因一方 cookie 保留；**guid 每次换新** |
  | 第三方 iframe 内 `sessionStorage`/`localStorage` | 可写可读；跨顶层站点（127.0.0.1 → localhost）**仍能读到** → 第三方存储未分区 |
  | `--disable-features=TrackingProtection3pcd[,ThirdPartyCookieDeprecation,ForceThirdPartyCookieBlockingEnabled]`、预置 `cookie_controls_mode=0` | 均未改变阻断结果 |

  引擎里有 `TrackingProtection3pcd` / `ThirdPartyStoragePartitioning` / `Cookie.PartitionedCookieCount` 等符号（binary strings），但当前构建/默认参数下稳定表现为：**3PC 全阻断、第三方存储不分区**。

**对“新设备”的含义**：在 AnyBrowser 里 `m` 这个最强锚点目前根本不存在，guid 每条 POST 都新发；跨加载只剩一方 `__stripe_mid`。这会让同一 Profile 表现为“拦截第三方 cookie 的浏览器”（Safari/Brave 风格），不算异常，但**失去了服务端对 guid 的连续性认知**，也让“清 m”这一步在本引擎里暂时无效。若要向真实 Chrome 靠拢，应把开启 3PC 作为引擎项立项（离线预置 pref 无效，需要引擎补丁/编译开关）。

## 5. 客户端在什么条件下复用旧值 / 跳过 POST

精确规则（`mt`，`v3.pretty.js:25504-25506`）：

```
mt(existing, fallback, he) = he ? ((!existing || (!pt(existing) && pt(fallback))) ? fallback : existing) : crypto.randomUUID()
```

- `he=true`（默认）：existing 合法（42 字符）→ 用 existing；existing 缺失/非法且 fallback 合法 → 用 fallback（服务端返回值）；两者都非法 → 返回 existing。
- `he=false`（脚本 URL `_1776170249=false`，`:570348`）：恒返回新 36 字符 UUID，**写不进 cookie**（`pt` 不过），也不建 frame、不发 POST。
- `_doNotPersistMuid/Sid`（Checkout 下发 mids）：直接返回给定值，不读不写 cookie（`:25698`、`:25713`）。
- **没有“跳过 POST”**：frame 每次加载 inner.html 必 POST；`ping=false` 只有 inner.html 支持、v3 从不生成。
- 唯一的省略是特征数组：`O = 2 === v2 || sessionStorage.get("id") !== md5(features)`，为 false 时 `a:null`（`:1352-1361`）。只影响载荷体积，不影响 POST。

frame 的创建节奏：Stripe.js 求值即建 `_ec`（class 静态属性，一个页面一份，`:40209-40212`），1 秒后建 frame（`:25531-25533`），`createRadarSession` 前会 `ensureFrameLoaded`（`:38896`）；URL 变化每 5 秒补 ping（`:25592-25612`），Element 的首次 submit/change 再补一条 ping+track（`:25739-25767`，调用点 `:26902/:26922`）。每个 POST 都会得到新 guid（本引擎下）。

## 6. 要得到“一套新 ID”，必须清什么

按影响排序（任何一条漏掉都会留下关联）：

1. **所有域**的 `__stripe_mid`、`__stripe_sid`（名字全域匹配，含 `.app.link.com` 之类商家/子公司域）。不清 → muid 复用。
2. **`m.stripe.com` 全量 cookie**（首要是 host-only、HttpOnly 的 `m`）。不清且 3PC 可用 → guid 复用；本引擎下不存在，但换引擎/开 3PC 后必须清。JS 读不到 HttpOnly，必须走 CDP/磁盘。
3. `checkout.stripe.com`、`js.stripe.com`、`link.com`/`onelink.com` 域族 cookie（Checkout 服务端另有 `__stripe_mid`/`__stripe_sid` 等副本；Link 有 `lsid`、`__Secure-sid`、`stripe.link.persistent_token`）。
4. `m.stripe.network` 源的 sessionStorage（`id`/`_ab`/`_mf`）与 localStorage（`muffins` 不残留，但 Checkout 可能写别键）——用 `Storage.clearDataForOrigin(storageTypes:"all")` 整源清。
5. **指纹 seed**：`id = md5(feature values)` 是另一套设备哈希，seed 不变的话“新 ID”仍是同一台设备（只换了号）。
6. 出口 IP / 时区 / 语言若同时轮换，才算“全新设备”；仅换 ID 但 IP、TLS、fonts、canvas 全同，是“换了号的同一台机”。

清完后：muid/sid/guid 三项全新；`id` 随 seed 变；服务端只剩 IP/TLS/时序等弱关联。

只清一半的后果：
- 清 mid、留 m → 新 muid 挂旧 guid，服务端一眼“同一设备换了号”。
- 清 m、留 mid → 旧 muid 挂新 guid，同样连得上。
- 只清 sid → 只是正常 30 分钟过期。

## 7. Stripe 侧靠什么把新 ID 与旧 ID 关联

按信号强度：

1. `m` cookie → guid（HttpOnly，2 年）。guid 是服务端设备记录的主键；新 muid 只是挂到同一 guid 上。
2. muid 回填：`b.d` 让客户端“自报”旧 muid，服务端原样采纳（`N/P/R/S` 实测）。导入 cookie jar 就等于复用 muid。
3. `mids`：`guid + muid + sid` 三元组随 RadarSession（`muid#guid#sid`）、`create_payment_method`、`create_confirmation_token`、Checkout URL fragment 上行。即使 cookie 中途被清，guid 已在请求里。
4. `payment_user_agent`、`referrer` 与 mids 同包（controller.js byte 1363758 的 `defaultParams`）。
5. 每次 POST 的 `id`（15 特征 md5）、`b.a/b.b/b.c`（加盐 URL/title 哈希）、`b.u/b.v`（明文域名）。
6. 浏览器外的：出口 IP、TLS/JA3/JA4、H2 帧序、时钟、hCaptcha cookie、Link 登录态。
7. 服务端记录：同 guid 下的历史 muid、同 muid 下的历史 sid、同 `id` 下的历史 guid——任一项命中即关联。

## 8. AnyBrowser 该怎么做

### 8.1 现状核对（代码）

- `Sources/AnyBrowserCore/BrowserRuntime+Data.swift:297-310` 的 `siteOrigins` 已含 `m.stripe.com`、`m.stripe.network`、`js.stripe.com`、`checkout.stripe.com`、Link/hCaptcha 全族；`:311` 的 `stripeDeviceCookies` 按名字全域匹配 `__stripe_mid/__stripe_sid`；`:111-118` 的 `cookie(_:matches:names:)` 会用“域后缀 / 父域”规则命中 `m.stripe.com` 的 `m`；`:76-78` 删除时带 `partitionKey`。**清表面已覆盖，方向正确。**
- `m.stripe.network` 的 sessionStorage 由 `Storage.clearDataForOrigin(storageTypes:"all")` 整源清（`:88-92`）。正确。
- `LaunchCoordinator+Identity.swift:59` 在停浏览器后调用 `clearSiteData`，`:38-64` 用 pending 标记保证重启/下次启动补做。正确。

### 8.2 必须补的三件事

1. **唯一性验收**（当前没有）：新增 SelfCheck/自动化用例——用本地 fixture 页加载真实 `https://js.stripe.com/v3/`，保留实例 `const s = Stripe('pk_test_…')`，等 6–8 秒，读 `document.cookie` 里的 `__stripe_mid/__stripe_sid`，并用 `s._mids()` 取 `{guid,muid,sid}`（`_ec` 是构造函数的静态属性，`window.Stripe._ec` 取不到；`_mids()` 可以）；重置后再跑，断言三项都不同、且 mid/sid 符合 42 字符格式。这能把“清了但其实没清”和“服务端把旧值还回来”都测出来。
2. **禁止默认导入 Stripe cookie**：Profile 导入/`CookieTransfer` 若带上 `__stripe_mid` 或 `m`，新 Profile 就是旧设备。导入时给 Stripe 身份一个显式选项：保留（同设备迁移）或丢弃（新设备）。`CookieTransfer.swift:318` 已拒收不合法 SameSite=None；再补一条按名字的黑名单即可。
3. **固定“新设备 = 新 seed + 清身份 + 换出口”的三件套**：`IdentitySampler` 已随机 seed；把“清身份面”挂到 `saveNewIdentity`（已有），并保证 full-reset 档位同时换代理出口。只换 seed 不清 cookie、或只清 cookie 不换 seed，都是半套新设备。

### 8.3 不建议做的事

- **不要伪造 `m2` 消息**给页面：`_handleMessage` 只查 origin（`*.stripe.com`），不查 source；任何 js.stripe.com/`*.stripe.com` 帧都能灌 guid/muid/sid。但伪造后 `_getID` 会立刻写 cookie，下一轮 POST 又用伪造值去找服务端，若格式或配对不合法会被悄悄换掉，收益低。
- **不要拦 `m.stripe.network` / `m.stripe.com`**：inner 一定 POST，失败会走 `beaconErrorHandler` 再 POST 一次（`beautified.js:2260-2272`、`:2294`），拦了只是多一条错误遥测，sid/muid 断链。
- **不要预置非规范格式**：客户端只查 42 长度，42 字符的非 uuid+6hex 值能写进 cookie，但服务端会换发，出现“本地 cookie 是 A、服务端记录是 B”的两套值（下一轮 m2 会把 B 写回来）。预置必须用 `^[0-9a-f]{8}-…-[0-9a-f]{12}[0-9a-f]{6}$`（全小写）。
- **不要单独清 m**：本引擎下 m 不存在，单独清它是空操作；单独清 mid 才是“看起来换了号但设备没换”。

### 8.4 若要“每次新建 Profile = 一台全新设备”

顺序（新 Profile 天然满足 1–2，老 Profile 走重置）：

1. 新 user-data-dir（无任何 cookie/storage）。
2. 新 seed（`id` 必变）+ 与 seed 自洽的 platform/brand/cpu/fonts/canvas/audio/gpu（见 `IdentitySampler`/`FingerprintConsistency`）。
3. 新的出口 IP 与时区/语言对齐（`IdentitySampler.LocaleHint(exit:)`）。
4. 首次访问 Stripe 前不导入任何 cookie；需要迁移时只迁非 Stripe 登录态。
5. 验收：`__stripe_mid` 42 位、guid 与上一 Profile 不同、`id` 不同。

### 8.5 引擎项（决定上限）

- 当前 3PC 全阻断 → `m` 不存在、guid 每 POST 换新。选项：
  (a) **保持现状**：更接近 Safari/Brave，但服务端只靠 muid 串；  
  (b) **引擎开启 3PC**（并验证 `m` Set-Cookie 落盘）：与桌面 Chrome 默认一致，guid 连续，才谈得上“像真设备”；需确认编译/特性开关，因为 `--disable-features=…` 与 `cookie_controls_mode=0` 在实测中都没生效。  
- 两者都自洽，但不能一半一半（例如只让 `m` 落盘却不带 `Cookie` 上行）。
- 第三方存储未分区这件事本身与 3PC 阻断的常见组合不一致，建议作为引擎观察项（真实 Chrome 3PC-block 场景通常启用 `ThirdPartyStoragePartitioning`）。

## 9. 证据索引

| 结论 | 证据 |
|---|---|
| inner 无条件 ping、ping=false 开关、版本选择 | `/tmp/stripe-re-20261122/inner.html` @248/284/318–334 |
| m-outer 逐字复制 hash、双向中继、无 source 校验 | `/tmp/stripe-plan-v2/work/m-outer.js` @60/128/239–311 |
| 入口导出 deviceId/p/b | `/tmp/stripe-out-4.5.45/beautified.js:5781-5809` |
| muid→b.d、sid→b.e、md5→id | `beautified.js:1329-1348` |
| POST 目标、withCredentials、__sid、无重试 | `beautified.js:5611-5638` |
| m2 结构与正则 | `beautified.js:2213-2242`、`:171-179` |
| v3 收 m2、写 _guid、逐字段 _getID | `/tmp/stripe-plan-v2/work/v3.pretty.js:25510-25531` |
| cookie 写属性（Strict/365d/30min/无 HttpOnly） | `v3.pretty.js:24691-24707`、`:25700-25723` |
| 42 长度校验、mt 复用规则 | `v3.pretty.js:25500-25506` |
| origin 白名单 | `v3.pretty.js:16661-16686` |
| frame URL 生成与 m-outer 路径 | `v3.pretty.js:25674-25691`、`:14784`、`:8096`、`:15087-15089` |
| 脚本 URL 参数 `he`(=`_1776170249`)/`ve`(=`_362609697`) | `v3.pretty.js:24724-24746`；raw v3 @570348/570365 |
| `_ec` 由 class 构造函数静态持有、每页一个，且不经 `window.Stripe` 暴露 | `v3.pretty.js:40209-40212`、`:40187-40195`、`:38539-38541`；CDP 实测 `typeof window.Stripe._ec` 为 `undefined` 而 `s._mids()` 可用 |
| midsChange 全量下发、radar `muid#guid#sid` | `v3.pretty.js:38329-38332`、`:38438-38440`；controller.js @1363758/1382270/1369261 |
| `m` = guid、HttpOnly、SameSite=None、2y、无 Partitioned | `/tmp/stripe-plan-v2/work/resp1.headers`、`a.headers`、`b.headers`、`P2.headers` |
| 服务端逐字段接受/换发 | `N/P/R/S`（接受）vs `G/L30/L42/L50/Q`（换发）；`H/K/M`（36→42 补齐） |
| 引擎 3PC 阻断、m 不落盘、guid 每载换新 | `/tmp/stripe-plan-v2/probe/*`（cdp 脚本与 title 输出），`cdp2.py` 的 `ALLCOOKIES []` |
| 第三方存储不分区 | `cdp6.py` 输出 `A(127.0.0.1) ss=S ls=L` / `B(localhost) ss=S ls=L` |
| 应用侧清表面 | `Sources/AnyBrowserCore/BrowserRuntime+Data.swift:16-21,76-78,111-118,297-311` |

探针文件对应（`/tmp/stripe-plan-v2/work/`）：`resp1/a` 首访与带 m 回访（同 guid、回显给定 ID）；`b/J` 仅带 m（guid 保留、muid/sid 换新）；`c` 无 cookie 带合法 ID（新 guid、ID 回显）；`d` 传 `NA`（全换新）；`e` 只有 `__stripe_*` cookie（被忽略）；`G/L30/L42/L50/Q` 非法格式（全换新）；`H/K/M` 36 字符 UUID（补后缀）；`N/P/R/S` 合法 42 字符（原样回显，R/S 为单边合法、另一边换新）；`P2` 复核 `m`==`guid`。

## 10. 推断与未验证

- **推断**：服务端对 muid/sid 的接受正则为 42 字符 `uuid36+6hex` 全小写；36 字符 UUID 的后缀由服务端某确定性函数生成（同值稳定、非 md5/sha 前 6 位）。
- **推断**：`__stripe_orig_props`、`machine_identifier`、`private_machine_identifier`、`stripe.csrf` 由 Checkout/invoice 等服务端页面下发；本次三个 bundle（v3/shared/controller）grep 均为 0。
- **未验证**：`--headless`/命令行直启的探针里，`__stripe_mid` 在重启后没有落盘（`Default/Cookies` 0 行，连一个普通 `max-age=86400` cookie 也不落；日志有 `keychain_password_mac.mm: Encryption is not available / errKCInteractionNotAllowed`）。同一会话内 cookie 正常。判断是 OSCrypt/Keychain 在 shell 环境不可用所致，GUI 启动的 Profile（v10 加密、钥匙串可访问）应能落盘；重启持久性需要在真实 app 启动路径下补测。
- **未验证**：真实 3PC 放开后 `m` 是否被 CHIPS 分区（服务端没发 `Partitioned`，预期不分）；上线环境 CDN 是否与本地 curl 的响应头一致。
- **未验证**：`mids` 在 Stripe API 的字段名（客户端以 `mids[guid]`、`mids[muid]`、`mids[sid]` 或 `data.mids` 形式上报，服务端如何落库不可见）。
- 所有 curl 探针都写入了真实 `m.stripe.com` 记录（2026-11-22 19:22–19:40 UTC），guid/muid/sid 即上文样本值。