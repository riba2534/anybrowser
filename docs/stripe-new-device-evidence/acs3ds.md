# 3DS2 / controller / shared 采集面 — 事实、链路与新设备语义

> 对象：`/tmp/stripe-ctrl-dl/controller.html`、`controller.js`、`shared.js`，以及它们加载的
> `three-ds-2-fingerprint-*.html/.js`、`three-ds-2-challenge-*.html/.js`、`m-outer-*.html/.js`、
> `wanderlust-frame-*.html/.js`（后四者是同一版本控制器按需拉起的子帧，已一并落盘）。
> 美化副本在 `/tmp/stripe-ctrl-pretty/`，行号均指美化副本；原始压缩文件同内容。
> 全部为文本/AST 读取，未执行被分析代码。旧结论只用于对照，均已独立复核。

## 0. 四个问题的直接回答

**1) 3DS 挑战链路会不会二次采集？**

分三层，答案不同：

- **Stripe 自己的 `m.stripe.com` 指纹：不会在 3DS 帧里重跑。** `three-ds-2-fingerprint-*.html`
  只加载 `shared-*.js` 与本帧脚本，没有 canvas/WebGL/audio 采集器；唯一的 iframe 是
  `name="stripe-fingerprint-frame"` 的 POST 靶子（`/tmp/stripe-ctrl-pretty/tds-fp.html:1`）。
  3DS 帧里 `grep` 不到 `getContext`/`OfflineAudioContext`/`enumerateDevices`。
  身份沿用页面级 `MetricsController` 的 `guid/muid/sid`，见 §3。
- **ACS（发卡行/3DS 服务商）的 method URL：每次都会二次采集，采集方是 ACS 自己。**
  `PERFORM_3DS2_FINGERPRINT` 到达帧后，帧把 `threeDSMethodData` 以表单 POST 到
  `payload.methodUrl`，target 就是上面那个 iframe（`tds-fp.pretty.js:111-118`，
  `shared.js:17280-17295`）。此后该 iframe 是 ACS 自己的文档，ACS 可以在其中跑任意 JS 采集，
  Stripe 只是等待它回传。字段集合由 ACS 厂商决定，不在 Stripe 代码里。
- **Stripe 的 FingerprintJS Pro（wanderlust）：条件性二次采集，且是强身份锚点。**
  控制器在 Link 特性开启时向父页发 `stripe-init-wanderlust`（`controller.js:63386-63389`），
  父页创建 `wanderlust-frame-*.html` 并调用 FPJS Pro `v3.12.17` 的
  `load({endpoint:["https://f.stripecdn.com/rAMDWjgV/SqhZjMry", …]})` → `get({linkedId})`
  → `sealedResult`（`/tmp/stripe-ctrl-pretty/wander.pretty.js:4661-4663,4690-4717`）。
  只要 `__Secure-f-visitor-id` cookie 还在，就直接返回 `null`、**跳过采集**
  （`wander.pretty.js:4764-4777` 的 `rt()` 门闩；cookie 元数据见 §4.2）。

挑战（challenge）阶段 Stripe 不再采集：`three-ds-2-challenge` 只把 `creq` POST 到 `acsUrl`
（`tds-ch.pretty.js:7891-7893`），之后等 ACS 回 `cres`（`:7932-7956`）。ACS 页面在挑战期间
持续存活并可按自己的节奏采集/交互，Stripe 只记时间线。

**2) 采哪些字段？**

3DS2 认证请求（`POST https://api.stripe.com/v1/3ds2/authenticate`，`controller.js:6928-6937`；
base URL `shared.js:12236`）的 `browser` 是硬编码 JSON 字符串（`controller.js:54233-54245`）：

| 键 | 取值来源 |
|---|---|
| `fingerprintAttempted` | 帧是否真的执行过 method（跳过/无 methodUrl 为 false） |
| `fingerprintData` | ACS 经 trampoline 回传的原文；未回传为 null |
| `challengeWindowSize` | `window.innerWidth`（`v3.js:41789`）落在 `<390/<500/<600/<768/≥768` 的 `01/02/03/04/05` 档（`controller.js:54236`） |
| `threeDSCompInd` | 恒 `"Y"`（`controller.js:54237`） |
| `browserJavaEnabled` | `navigator.javaEnabled()`（Chrome 恒 false） |
| `browserJavascriptEnabled` | 恒 `true` |
| `browserLanguage` | `navigator.language \|\| navigator.languages \|\| navigator.browserLanguage` 的首值 |
| `browserColorDepth` | `screen.colorDepth` |
| `browserScreenHeight` / `browserScreenWidth` | `screen.height` / `screen.width` |
| `browserTZ` | `new Date().getTimezoneOffset()` |
| `browserUserAgent` | `navigator.userAgent` |

另有顶层 `frontend_execution = btoa(JSON.stringify({fingerprintOutcome, fingerprintCompletedAt,
fingerprintTimeout, fingerprintStartedAt}))`（`controller.js:54212-54220,54249`）与
`one_click_authn_device_support` / `one_click_authn_authentication`
（`controller.js:54247-54248`；能力项见 `v3.js:41665-41672,41792-41799`：
`same_origin_frame / spc_eligible / webauthn_eligible / publickey_credentials_get_allowed`）。

FPJS 侧采集面（全部可在 `fpjs.pretty.js` 定位，属高熵集合）：
canvas 几何与文字（`:2022-2046`）、WebGL vendor/renderer/参数/扩展/shader 精度（`:2705-2740,9275-9290`）、
`OfflineAudioContext` 求和（`:9466-9520`）、`AudioContext.baseLatency`（`:2677-2690`）、Math 指纹（`:1910,2640-2670`）、
plugins 全表（`:2543-2560`）、languages（`:2485-2503`）、colorDepth（`:2500`）、deviceMemory（`:2502`）、
hardwareConcurrency（`:3648`）、timezone（`:2506-2515`）、storage/cookie/openDatabase 探针（`:2517-2530,2590-2592`）、
`pdfViewerEnabled`（`:2669`）、screen 边框 frame `[availTop, 右/下边距, availLeft]`（`:7119-7121`）、
outer/inner 窗口 frame（`:5433-5438`）、MathML（`:3530`）、error stack（`:2545-2552`）、
adblock DOM 探测（`:2405-2470`）、Moz/WebKit 特征集（`:6449,8078`）。
WebRTC 由 `webRtcViaPort80/webRtcViaUdp` 默认 true 传入（`:6527-6528`），具体模块被混淆，标推断。

分析通道也带环境字段：每条 `r.stripe.com/0|/b` 事件都附加
`os / browserFamily / browser_version`（由 `navigator.userAgent` 解析，`shared.js:15228-15230`）、
`connection_rtt / connection_downlink / connection_effective_type`（`shared.js:15080-15118`）、
`browserClassification / browser_classification_v2`（特性探测分类，`shared.js:14986-14992,15154-15155`），
以及 `cdn_name / cdn_pop_dc`（由 `.deploy_status_henson.json` 响应头得到，网络层事实）。

**3) 与主采集器是否共享身份（muid/sid）？——共享。**

- 页面级 `MetricsController` 创建 `METRICS_CONTROLLER` 帧（`v3.js:25570-25580`），
  `m-outer-*.js` 再嵌 `https://m.stripe.network/inner.html#…` 并双向转发消息
  （`/tmp/stripe-ctrl-pretty/mouter.pretty.js:3-11`）。
- inner 采集器把 `guid/muid/sid` 以 `{"originatingScript":"m2"}` postMessage 给父级
  （`/tmp/stripe-out-4.5.45/beautified.js:2219-2234`），页面用 `_getID` 写入商家域 cookie
  `__stripe_mid`（365 天，`v3.js:25698-25712` 与 `v3.js:24693-24709` 的默认 31536e6 ms）、
  `__stripe_sid`（1800 s，`v3.js:25713-25724`）。
- 卡片 token 的 `client_metadata` 直接带 `guid/muid/sid`（`controller.js:52628-52633`），
  Radar session 创建也带 `mids`（`controller.js:53256-53274`）。
- `muid/sid/guid` 还会进入 m.stripe 指纹 payload 的 `v.d/v.e`（`beautified.js:1339-1340`），
  请求带 `withCredentials`（`beautified.js:5618`）。
- 反向也成立：ACS 回传的 `fingerprintData` 被塞进 Stripe 的 authenticate，所以 ACS 的指纹结果
  也进入 Stripe 侧。
- FPJS 的 `sealedResult` 以 `linkedId = stripeJsId` 绑定，并上报
  `consumers/sessions/benchmark_visitor_id`（`controller.js:13424-13443`，调用点 `:26505-26513,49479-49485`），
  同时写 `__Secure-f-visitor-id`。

**4) 「新设备」在 3DS 风控里表现为什么？**

- 对 Stripe：新设备 = 新 m 设备身份（空 `m` cookie、新 muid/guid）+ 新 FPJS visitor
  （无 sealed cookie、无 `_vid`/`__fpjs_pvid`、指纹向量不同）+ 与之一致的 3DS `browser` 参数。
- 对发卡行/ACS：device binding 绑在**卡**上而不是浏览器全局；method 完成但向量陌生，
  `transStatus` 常见 `C`（升级挑战）、部分 `R/U`。`threeDSCompInd="Y"` 与
  `fingerprintAttempted=false/fingerprintData=null` 并存只在 skip/无 methodUrl/超时时出现，
  是「声称完成、实际没数据」的固定组合，不是新设备特征。
- 结论：**每次新 Profile 都必然提高挑战率，这是正确的「新设备」形态**；真正要躲的是
  「新 cookie + 与旧 Profile 完全相同的指纹向量」——那是设备农场聚类证据。
  反过来，同一 Profile 每次启动都换向量也是「cookie 被克隆」形态，见 §6。

## 1. 帧与脚本拓扑（谁加载谁）

`controller.html` 单行：

- `origin-trial` 令牌声明 `feature":"Tpcd"`、`origin":"https://stripe.com:443"`、`isSubdomain:true`
  （`/tmp/stripe-ctrl-dl/controller.html:1`）——为第三方 cookie/Storage Access 过渡预埋。
- 依次加载 `shared-e-2f1f….js`、`controller-e-21746….js`（同文件）。
- body 为空。

3DS 相关子帧由 `v3.js` 的 frameType→HTML 映射产生（`v3.js:14784-14790`）：

- `STRIPE_3DS2_FINGERPRINT` → `three-ds-2-fingerprint-3f1ce9001ffe1c6c4db7d48d8be5a1a4.html`
- `STRIPE_3DS2_CHALLENGE` → `three-ds-2-challenge-2be5dc9ce12dc32232ee139f4f992dd3.html`
- 另有 `STANDALONE_3DS_FINGERPRINTING/CHALLENGE`，服务于 `/three_d_secure/(fingerprint|challenge)/acct_*` URL
  （`v3.js:38060-38105`），走同一套帧逻辑。

所有子帧 URL = `https://js.stripe.com/v3/<fingerprintedPath>#<query>`，query 至少含 `parentOrigin`，
且 iframe 一律 `referrerpolicy="no-referrer"`（`shared.js:7297-7301,7479`，`74051` 拼 base）。
**推论：ACS 拿不到 Referer 头**，只能靠 POST body、自身 JS 环境和 `window.parent` 的可观测面。

指纹帧：HTML 里预置 `<iframe id="fingerprint" name="stripe-fingerprint-frame">`
（`tds-fp.html:1`）；帧脚本解析自己 hash 里的 `controllerId/intentId/hosted/locale/referrer`
（`tds-fp.pretty.js:156-166`）。优化位 `sandbox_method` 为真时给该 iframe 加
`allow-forms allow-same-origin allow-scripts`（`tds-fp.pretty.js:112-114`）。
`methodUrl` 必须 https，否则抛错（`shared.js:17280-17284`）。

挑战帧：lightbox（`v3.js:41064-41090`），可选全屏；iframe 属性见
`v3.js:14744-14752` 与 `tds-ch.pretty.js:8970-8986`：`name="stripe-challenge-frame"`、
`allow="payment *; publickey-credentials-get …"`、`allowpaymentrequest`；
`sandbox` 仅在 ACS 优化位 `sandbox_challenge` 时出现，值为
`allow-forms allow-scripts allow-same-origin allow-pointer-lock allow-popups`
（`tds-ch.pretty.js:8973`）。

## 2. 认证主链路（逐跳，含所有可控参数）

1. 意图 retrieve 返回 `next_action.use_stripe_sdk.type = stripe_3ds2_fingerprint|stripe_3ds2_itmx`
   （`controller.js:32306-32340`）→ 归一化成 `{type:"3ds2-fingerprint", gateway:"emvco"|"itmx",
   methodUrl: three_ds_method_url, threeDS2Source, merchant, transactionId, optimizations,
   oneClickAuthn, publishableKey}`。优化位从 `three_ds_frontend_optimizations` base64 解析，
   缺省回落 `bI`（`controller.js:32237-32271`），关键位：
   `skip_method`、`method_timeout`(1–10，默认 10)、`sandbox_method`、`fullscreen_hosted_challenge`、
   `fullscreen_challenge`、`show_challenge_frame_during_fingerprinting`、`poll_intent_during_challenge`、
   `warn_on_abandon`。
2. 外帧 `w(t)` 创建隐藏指纹帧并等 `load`（`v3.js:41185-41210`），然后
   `perform3DS2Fingerprint({methodUrl, shouldSandbox, fingerprintingMaxTimeout, …})`
   （`v3.js:41261-41285`）。
3. 帧内 `A()` 组 `threeDSMethodData = btoa(JSON.stringify({threeDSServerTransID,
   threeDSMethodNotificationURL:"https://hooks.stripe.com/3d_secure_2/fingerprint/<merchant>/<source>"}))`
   （`tds-fp.pretty.js:68-89`，base `shared.js:7169-7171`），POST 到 methodUrl
   （`tds-fp.pretty.js:118`）。ITMX 分支改用 `{JWT: accessToken}`（`:80-85`）。
4. 等 postMessage：emvco 认 `type:"3ds2-trampoline"`；ITMX 认 Cardinal 三域发来的
   `MessageType:"profile.completed"`，Origin 白名单为
   `centinelapistag.cardinalcommerce.com / centinelapi.cardinalcommerce.com / client.cardinaltrusted.com`
   （`tds-fp.pretty.js:55`）。1–10 s 超时（`:108-110,134-144`），三态
   `captured / errored / timed_out`，结果形态 `{fingerprintAttempted, fingerprintData,
   frontendExecution:{startedAt, completedAt, outcome, timeout}}`（`:90-107`）。
5. 控制器收齐后发 authenticate（§0.2 的字段）。响应 `transStatus`：
   `C` → 建挑战（`creq`, `acsURL`, `acsTransID`, `threeDSServerTransID`，`controller.js:54446-54484`）；
   `N/R/U` 且有 >15 字 `cardholderInfo` → 提示信息（`:54435-54445`）；否则 `frictionless`（`:54486-54493`）。
6. 挑战：`creq` POST 到 `acsUrl`（`tds-ch.pretty.js:7891-7893`），30 s 载入超时（`:7919-7930`），
   等 `cres`；`atob(cres)`（`:7938`）后 `challenge_complete` 只发
   `{source, final_cres}`（`controller.js:50744-50752`）。hosted 流程另有
   `verifyUrl/completeUrl` 直投（`controller.js:6951-6965`）。
7. `3ds2.done`/`3ds2.challenge.report` 等全程只进 analytics（`controller.js:68658-68840`，
   `tds-ch.pretty.js:8859-8873`），带 `methodUrl`、`acsUrl`、`acsTransactionId`、
   `challengeTimeToLoad/Shown/Complete/OfInteraction`。

## 3. 身份：谁生成、谁保存、谁上报

| 项 | 生成 | 持久化 | 上报点 |
|---|---|---|---|
| `guid`（42 hex） | m.stripe inner，`crypto.getRandomValues`（`beautified.js:1302-1308`） | 仅内存 + `v.d` 指纹字段 | m2 消息、指纹 payload |
| `muid`（同 42 长度校验） | 同上，页面 `pt(e)=42===e.length`（`v3.js:25501-25502`） | 商家域 `__stripe_mid` cookie，365 d，SameSite=Strict、Secure、`domain=.<host>`（`v3.js:25700-25712,24700-24706`） | m2、指纹 `v.d`、卡 token `client_metadata.muid` |
| `sid` | 同上 | 商家域 `__stripe_sid`，1800 s，滑动续期（`v3.js:25713-25724`） | m2、指纹 `v.e`、`client_metadata.sid` |
| `m`（httpOnly） | m.stripe.com 响应（旧结论，静态不可见） | m.stripe.com 域，2 年；POST 带 credentials（`beautified.js:5618`） | 随每次 `/6` 自动携带 |
| FPJS visitor / sealed | FingerprintJS Pro 服务端 | `__Secure-f-visitor-id`：domains `.link.com/.stripe.com/.stripecdn.com/.onelink.com`、86400 s、Secure、SameSite=None（`wander.pretty.js:2551-2558`）；其自身 `_vid`(localStorage)、`__fpjs_pvid`（`fpjs.pretty.js:3039,3485`） | `sealed_result_base64` → `benchmark_visitor_id` |
| Link 会话 token | Link 后端 | `<merchant host>` localStorage 按 publishableKey 存 `authSessionClientSecret`（`controller.js:7760-7805`）；sessionStorage 键 `link.auth_session_client_secret`（`controller.js:7153,7817-7885`） | Link API |

`__stripe_mid/sid` 只在商家 host 可写，`m` 在 m.stripe.com，`__Secure-f-visitor-id` 在 Stripe 域族。
**只清其中一层都会留下另一层的同一身份。**

`mids` 是控制器 `appParams` 的正式字段（`controller.js:62580-62584`），并作为
`topOriginForCrossOriginFrame / parentOrigin / parentIsTop / controllerCount` 同列——
这几项本身也是可观测的嵌入指纹（`controller.js:62570-62600`）。

另有被动风控旁路：卡 token 的 `radar_options` 可带 `hcaptcha_token`（`controller.js:52617-52633`），
passive captcha 由同一组设备/IP 事实打分；它与 3DS 的 ACS 结果相互独立，但会叠加在同一笔支付上。

## 4. 跨域通信与信任边界

- 帧→控制器统一消息包：`{type:"child|sibling", sourceFrameId, targetFrameId,
  controllerAppFrameId, message}`；父帧仅当 `t.source === window.parent` 且
  `targetFrameId === 自身 id` 时采纳并锁存 `_verifiedParentOrigin`（`controller.js:65620-65640`）。
- inner 消息额外要求 origin ∈ Stripe 源集 `at.J6(_e.VT, t)`（`controller.js:65860`）；
  `VT = https://js.stripe.com`（`shared.js:12120-12122`）。
- 帧侧 `FrameClient` 只接受 `event.origin === frameOrigin`（由 iframe `src` 解析，`shared.js:7410-7425,7487-7489`）。
- 可信源集合：`*.stripe.com/*.stripe.me/*.stripe.dev`、Link/onelink 域、
  `hooks.stripe.com`、checkout.stripe.com 族，以及一份硬编码合作域
  `k`（chatgpt.com / pay.openai.com / platform.openai.com）和 24 个 `checkout/pay.*` 域
  （`shared.js:19440-19528`）。
- 转发原语 `stripe-forward-to-child-frame` 由中间帧把消息投给子帧，`targetOrigin` 必需（`shared.js:7510-7523`）。

对 AnyBrowser 的含义：引擎级改写 `location`/`document.referrer` 或注入会破坏这些 origin 校验；
spoof 必须发生在网络/引擎层，页面 JS 补丁只做兜底。

## 5. 「新设备」在 3DS 风控里的可判定面（排序）

| 可信度 | 判据 | 新设备该有的形态 | 当前 AnyBrowser 状态 |
|---|---|---|---|
| 最高 | `m` cookie / muid / guid 是否新 | 全空、新生成 | 取决于 cookie jar |
| 最高 | `__Secure-f-visitor-id` 是否存在 | 不存在，FPJS 现采 | 取决于 cookie jar |
| 高 | `browser` JSON 与 m.stripe 指纹、FPJS 向量是否同一台机器 | 自洽但陌生 | 部分字段仍报宿主 |
| 高 | 屏幕/窗口几何是否等于宿主 | 不等于宿主且自洽 | `--fingerprint-screen-*` 实测不生效（`IdentitySampler.swift:128-131` 已记录），必须引擎 patch |
| 高 | `navigator.plugins/mimeTypes/pdfViewerEnabled` 是否为 Chrome 148 macOS 固定表 | 固定 5 条，全集一致 | 引擎原生，未 spoof，风险低 |
| 中 | `screen.colorDepth`/`devicePixelRatio`/`avail*` 与预设平台是否搭 | 按预设，与 host 解耦 | 未接线 |
| 中 | `hardwareConcurrency/deviceMemory` 是否落在该 GPU/机型组合 | 按种子，且与 GPU 表一致 | 仅 cpuCount，无 memory |
| 中 | languages / `Accept-Language` / timezone / 出口 IP 是否同区 | 三者与出口同区 | 已接线，需强制一致性 |
| 中 | WebRTC 是否泄漏宿主 LAN/mDNS | 只按代理出口 | `disable_non_proxied_udp` 已加（`Profile.swift:323`） |
| 中 | `navigator.connection` rtt/downlink/effectiveType | 与出口类型一致 | 未处理 |
| 低 | UA-CH 与 UA 是否一致、`webdriver`、`window.chrome` | 原生 Chrome 形态 | 引擎原生 |
| 低 | 3DS 时序（method 用时、挑战用时、页面隐藏） | 真实人类量级 | 未处理 |

## 6. 对 AnyBrowser 的实施方案

### P0 引擎（不做则 3DS 直接露馅）

1. **screen / 窗口几何 patch（最高优先）**。`browser` JSON 直读
   `screen.width/height/colorDepth`，FPJS 还读 `screen.availTop/availWidth/availHeight/
   availLeft` 与 `outerWidth/outerHeight/innerWidth/innerHeight`。现已验证
   `--fingerprint-screen-*` 在 headless 与窗口模式都不生效，只能 patch
   `screen.cc`/`local_dom_window.cc`/`widget` 层（与既有方案文档 P2 一致）。
   目标恒定式：`availLeft=0`、`availTop=25`（macOS 菜单栏）、
   `availHeight = height - 25 - dock(0/70)`、`availWidth = width`、
   `outerHeight - innerHeight ≈ 88`（含标签栏）、`outerWidth - innerWidth ≈ 0`、
   `innerWidth < screen.width`、`colorDepth=24`、`pixelDepth=24`。
   所有子帧（js.stripe.com 两帧、m.stripe.network、ACS 域）必须拿到同一组值。
2. **navigator 面**：`plugins/mimeTypes` 固定 Chrome 148 macOS 5 条 PDF 表（与
   `findings/extractors.md` §2.1 的实测表对齐）、`pdfViewerEnabled=true`、
   `vendor="Google Inc."`、`productSub="20030107"`、`hardwareConcurrency`（已）、
   `deviceMemory`（新增，按 GPU/机型表）、`connection.rtt/downlink/effectiveType`、
   `oscpu=undefined`、`javaEnabled()=false`、`webdriver=false`、`window.chrome` 原生。
3. **canvas / WebGL / audio / fonts** 必须按 seed 确定、同 Profile 内跨帧一致、
   跨 Profile 不同；且 canvas 在同一 origin 连读要稳定（FPJS `qT()` 会把两次
   `toDataURL` 不一致判成 `unstable`，`fpjs.pretty.js:2036-2040`）。
   这些必须在引擎层做：ACS iframe 跨域，页面注入够不到。
4. **UA-CH 五项**（brands/fullVersionList/platformVersion/architecture/bitness）与 UA、
   `--lang`、`Accept-Language`、timezone、出口 IP 联动；沿用现有 consistency 规则。
5. **WebRTC**：保持 `disable_non_proxied_udp`，保证无宿主候选；mDNS 行为与平台一致。

### P0 Profile 生命周期（「新设备」= 全套换新，而不是只换一层）

新建即视为新设备时，同时清：

- cookie：`__stripe_mid`、`__stripe_sid`（按名全域，含 `.app.link.com`）、
  `m`（m.stripe.com）、`__Secure-f-visitor-id`（`.stripe.com/.stripecdn.com/.link.com/.onelink.com`）、
  `stripe.link.persistent_token`；
- storage：`js.stripe.com` 的 localStorage `_vid`、`__fpjs_pvid`；
  sessionStorage `link.auth_session_client_secret`；`light_experiment_assignments` 等实验缓存；
- 同时**换 seed**（canvas/WebGL/audio/fonts/GPU/CPU/内存/屏幕几何全变），否则 FPJS 服务端仍会
  按向量把你并到旧 visitor。

稳定设备期（同 Profile 重启）：保留 mid/m/sid，指纹向量不变；只让 sessionStorage 自然消亡。
**两档不要混用**——「清 cookie 不换向量」与「换向量不清 cookie」都会留下特征。

### P1 验证

- 3DS 探针页：Payment Element + 测试卡 `4000002500003155`（必挑战）与 `4000002760003184`；
  CDP 记录 `three-ds-2-fingerprint-*.html`、`acsUrl` 的 POST body（`threeDSMethodData`）、
  `hooks.stripe.com/3d_secure_2/fingerprint/*`、`api.stripe.com/v1/3ds2/authenticate`、
  全部 `r.stripe.com/*` 与 postMessage；比对 Profile 间差异。
- 每 Profile golden JSON：`browser` 块 10 项、FPJS 向量摘要、screen/avail/outer/inner、
  plugins 串、fonts 位串；断言无宿主值泄漏（宿主 2560×1440、DPR 2、Asia/Shanghai 之类）。
- 新 Profile 首访 Link，断言 `__Secure-f-visitor-id` 与 `_vid` 均为空，且 visitorId 与旧 Profile 不同。

### P2 加固

- 结账/3DS 专用 Profile 不要装扩展或广告拦截器：FPJS 有 adblock DOM 探测
  （`fpjs.pretty.js:2405-2470`），扩展还会改变 plugins/Worker 环境。
- 保持内置 Chromium 与声称品牌版本差 ≤4 个主版本（现有 `brand-version-behind` 规则），
  避免 «obsolete browser» 概率加权。
- 目标页停留时长、method 用时、挑战输入节奏按真人分布注入，避免 200 ms 内完成 method + OTP。

## 7. 未知与置信度

- ACS 具体采集字段/厂商：代码不可见。已知 ITMX 网关与 Cardinal 三域
  （`tds-fp.pretty.js:55`），emvco 走任意 `acsUrl`。**必须实网探针**；测试模式的 3DS 是
  Stripe 模拟器，不足以代替真实 ACS。
- `__Secure-f-visitor-id` 的写入方：cookie 登记表证明名字/域/24h/属性（`wander.pretty.js:2551-2558`），
  客户端只有读取与「存在即跳过」（`:4764-4777`）；**推断**由 FPJS 端点响应 `Set-Cookie`
  写入（`https://f.stripecdn.com/rAMDWjgV/SqhZjMry`，`wander.pretty.js:4661-4675`）。
  本机用无 body 的 GET 打该端点得到 404（缺签名 body），未能直接看到响应头。
- `m` cookie 在新版是否 `Partitioned`：静态不可见，沿用 E2E 观察项。
- `threeDSCompInd` 恒 `"Y"`（`controller.js:54237`）意味着 skip/超时也会声称 method 完成；
  服务端是否用 `fingerprintAttempted` 修正，静态不可见。

## 8. 关键证据索引

| 事实 | 证据 |
|---|---|
| 指纹帧 HTML/单一 POST 靶 iframe | `tds-fp.html:1` |
| method POST + trampoline + Cardinal 白名单 | `tds-fp.pretty.js:55,68-89,111-118,134-144` |
| 挑战 creq/cres/时序 | `tds-ch.pretty.js:7891-7893,7924-7956,8859-8873,8970-8986` |
| authenticate 字段与 URL | `controller.js:54233-54248,6928-6937`；base `shared.js:12236` |
| 指纹/challenge 动作归一化与优化位 | `controller.js:32237-32271,32306-32350` |
| 跳过/无 methodUrl 语义 | `v3.js:41233-41255` |
| 指纹结果三态 | `tds-fp.pretty.js:90-107` |
| 帧创建（隐藏/lightbox） | `v3.js:41185-41210,41064-41090` |
| 帧属性/allow/sandbox | `v3.js:14744-14752`；`tds-ch.pretty.js:8973` |
| no-referrer | `shared.js:7297-7301,7479` |
| 表单 POST helper | `shared.js:17280-17295` |
| hooks 通知 base | `shared.js:7169-7171` |
| radar session 带 mids | `controller.js:53256-53274` |
| 卡 token 带 mids | `controller.js:52628-52633` |
| muid/sid cookie 写入与长度校验 | `v3.js:25698-25724,25501-25502`；默认 365 d `v3.js:24693-24709` |
| m2 → guid/muid/sid | `beautified.js:2219-2234`；payload `d/e` `:1339-1340` |
| m.stripe POST withCredentials | `beautified.js:5618-5640` |
| m-outer 转发 | `mouter.pretty.js:3-11` |
| wanderlust 端点/门闩/cookie 元数据 | `wander.pretty.js:4661-4675,4690-4717,4764-4777,2551-2558` |
| benchmark_visitor_id | `controller.js:13424-13443,26505-26513` |
| analytics 环境字段 | `shared.js:14986-14992,15080-15118,15154-15155,15228-15230` |
| FPJS 各信号 | `fpjs.pretty.js:2022-2046,2485-2560,2590-2592,2669,2677-2690,2705-2740,3039,3485,3530,3648,5433-5438,7119-7121,9275-9290,9466-9520` |
| 父源校验/可信域 | `controller.js:65620-65640,65860`；`shared.js:19440-19528` |