# 终稿批判：PLAN.md 的完整性、破绽与不可实施点

对象：`/tmp/stripe-plan-v2/PLAN.md`（1032 行）及其引用的工作产物。
方法：逐条回到原文件/原抓包/仓库源码复核；抽查规则对 10 份真实 payload 的可满足性；在真实引擎上补跑语言/UA-CH 头探针。外部 JS 只解码、不执行。
结论：**方案的主体判断（m→guid、mid/sid、15 值 md5、屏幕死开关、v3 不采集）都成立，七阶段与能力门设计也合理；但有 2 个会直接毁掉“全新设备”目标的实现缺口、1 个被整体漏掉的采集面、以及一批会让它自己的基线全红的规则错误。以下按严重度列，修法都在条目里。**

---

## P0 — 会直接让「新设备」失效

### 1. [critical] 「整套重新生成」会把旧 `deviceIdentity` 原样带过去，旧 muid 复生

**claim**：`§6.6` 的 `identityBundle` 调用清单列了 makeDraft / clone / import / batch / adoptOrphan，`§4.2` 又说“要换身份必须走整套重新生成”。唯独没有列 `ProfileStore.regenerateIdentity`（`Sources/AnyBrowserCore/ProfileStore.swift:278-287`）——它只做 `var value = profile` 后替换 fingerprint；`LaunchCoordinator.generateIdentity` 也**只返回 fingerprint**（`Sources/AnyBrowserCore/LaunchCoordinator+Identity.swift:12-28`），UI 再把 fingerprint 赋回旧 profile 的副本。`deviceIdentity` 若只加在 `BrowserProfile` 上，会全程存活。

**failure scenario**：用户点“整套重新生成”→ 新 seed + `pendingIdentityReset` → 停浏览器 → `removeSiteData` 清空 jar → 启动。seeder 读不到 mid，按 `effective(profile)` 写入；`effective` 返回 `profile.deviceIdentity`（旧值）→ 首报 `b.d` 是**旧 muid**，服务端新建 guid 后把它与旧设备记录关联。指纹全换了、id 也变了，但服务端看到的是“老 muid 换了新指纹”，正是方案自己定义的“同设备换装”。

**新设备影响**：这是主流程的必经路径，不是边缘情况；I006（两个新 Profile 三元组全不同）也覆盖不到“同一个 Profile 重新生成”。

**修法**：`regenerateIdentity` 里 `value.deviceIdentity = nil`；`AutomationAPI.update` 改 seed 时同样清；`identityBundle` 的清单补 `regenerateIdentity`。加规则 `identity-derived-after-reset`：pending-reset 启动后首报的 mid 前缀必须等于 `derived(newSeed, platform)`，且 jar 里不得出现旧前缀。E2E 增一条“regenerate → 首报 mid 前缀变化”。

---

### 2. [critical] `.font` 默认不在 `adjustments` 里，字体表整条链路是死的

**claim**：`FingerprintSettings.adjustments` 默认 `[.canvas, .clientRects]`（`Sources/AnyBrowserCore/Profile.swift:94`）；`IdentitySampler.sample` 只补 `.audio`（`:188`），`IdentityPreset.apply` 只补 `.gpu`（`Sources/AnyBrowserCore/IdentityPresets.swift:27`），`adaptToPlatform`/`randomize` 只**保留**已存在的 `.font`，从不新增。`arguments()` 按 `FingerprintAdjustment.allCases` 反向拼 `--disable-spoofing`（`Profile.swift:387-391`），所以每个新 Profile 都带 `font`。

而 `§2.3` 的补丁 gate 明写“只在 `--fingerprint` 生效、**未 `--disable-spoofing=font`** 且 profile/variant 命中时查表”（PLAN:217），引擎侧的门也是子串匹配 `font`（`engine.md` §1/§3）。两者相乘的结果：`fontProfile`、`fontVariant`、55 位 golden、`document.fonts.check` 补丁、`C006`、`S017`、`S019`、`I006` 的“font 至少一项不同”**全部不生效**。当前 `fontProfile` 已经由 `sample` 写入（`IdentitySampler.swift:185`），所以 `C013` 还会是绿的，问题被掩盖。

**failure scenario**：P5 完成后跑验收，所有 Profile 的 `a.j` 仍是宿主那 55 位串；Windows 身份继续带 macOS 字体向量，`C006`（Windows 含 Segoe/Calibri）在**每个** Windows 样例上红；`§8.9` 的“font 至少一项不同”永不满足。

**新设备影响**：j 是方案自己认定的三个高熵槽之一，且是唯一能区分同型号 Mac 的槽（屏幕只有 4 个目录、会撞）。`.font` 关着时，“新设备”只剩 canvas 一个真差异（R20 正是要避免的）。

**修法**：`sample`/`identityBundle`/`adaptToPlatform` 在 `platform != nil && capability.fontProfiles`（macOS 与 Win/Linux 都算）时强制 `adjustments.insert(.font)`，capability=false 时移除；`arguments()` 的 disabled 列表要能反映它；加规则 `font-spoof-disabled`（`fontProfile != nil` 且 `--disable-spoofing` 含 font → fail）。`C006`/`S017` 加 capability 前置。

---

## P1 — 完整性缺口

### 3. [high] 最强的第二采集面（FingerprintJS Pro / wanderlust）没进「新设备」定义

`acs3ds.md` 已经证到：控制器在 Link 特性开启时触发 `stripe-init-wanderlust`，由页面加载 FPJS Pro 3.12.17，`sealedResult` 以 `linkedId = stripeJsId` 绑定，cookie `__Secure-f-visitor-id`（`.link.com/.stripe.com/.stripecdn.com/.onelink.com`、86400 s、Secure、SameSite=None）、`_vid`(localStorage)、`__fpjs_pvid`（`acs3ds.md:41-56, §3, §4.2`）；采集面包含 WebGL vendor/renderer/参数、AudioContext/OfflineAudio、canvas 两读稳定性、plugins、languages、colorDepth、deviceMemory、hardwareConcurrency、screen 边框帧、outer/inner 帧、Math、error stack、WebRTC（`acs3ds.md:52-70`）。该文档把“无 `__Secure-f-visitor-id`”列为**最高可信度**的新设备判据（`acs3ds.md:§5` 第 2 行）。

而 PLAN 只把 FPJS 写进清理名单（PLAN:579,585,606,830），`§0.3` 的可操作定义、`§1` 的字段矩阵、`§8.9` 的身份矩阵都没有它；`§0.1` 还写“m.stripe.network/out-4.5.45.js 是一个完全被动的采集器”，容易让施工者把它当全部面。新 Profile 天然没有 FPJS cookie，但**任何“重置没清干净/只清 cookie 不重启/导入 jar”的失败路径**都会留下一个与旧 guid 通过 `linkedId` 绑定的 visitor，且它的 11 类高熵向量大多来自宿主。

**新设备影响**：这是 Link/3DS 路径上最硬的设备键；漏掉它，“新设备”在支付第一步就会被 FPJS 侧的旧 visitor 回收。

**修法**：把 FPJS 写进 `§0.3`（无 `__Secure-f-visitor-id`/`_vid`/`__fpjs_pvid`）、`§8.10`（首次 Link/3DS 前断言三者皆无，触发后断言建立新 visitor）、加规则 `fpjs-visitor`；把 FPJS 的字段清单作为引擎/种子硬化的第二张表（至少 WebGL/audio/hardwareConcurrency/deviceMemory/screen 帧要按 seed 分离且跨帧一致），并明确 wanderlust 帧跨域，只能靠引擎与 all_frames 内容脚本。

### 4. [high] 规则表没有“样本种类”分支；track 的键集写错，会把合法报文全部判红

三处都是硬错：

1. **track 体没有 `version` 键**。v3 的 `report()` 发出的是**消息** `{action:"track",payload:{sid,muid,url,source,data,version}}`（`v3.pretty.js:25756-25765`），但 inner 的监听器收到后**重建**一个五键对象 `{muid,sid,url,source,data}` 并把 `t.version` 当第二参数去拼 beacon 路径（`/tmp/stripe-re-20261122/inner.html` 唯一一行；`mod-10.js:95-106` 的 `h(e,t)` 只把 `t` 给 `safeBeacon` 的 URL）。`P023` 要求键集含 `version`（PLAN:730，以及 C10 PLAN:28 的“修正”本身是错的）。
2. **同名规则会落到 track / unavailable 体上**。track 体没有 `id`、`a`、`t`、`h`、`b`，`P002`（顶层键恰为 `{v2,id,t,tag,src,a,b,h}`）、`P005`（`id` 32 hex）、`P006`（a 为对象/null）、`P008`、`P011`（b 键集）、`P013`、`P015`、`P020` 都会失败；错误 beacon 的 `id:"unavailable"` 也过不了 `P005`。
3. **`a:null` 的次报没有前置条件**。`P008` 需要 join 的 15 个值、`P020` 需要 `a.*.t`、S001–S015 需要 `a` 的内容，但次报（5/5 的 `p6-*-2.txt`）都是 `a:null`；照字面执行必红。

**新设备影响**：基线不绿就无法当门禁；更实际的是，施工者为了“让规则过”可能去改采集路径，而不是改规则。

**修法**：先做样本分类（`first-ping` / `repeat-ping(a:null)` / `track` / `unavailable` / `v4-response`），每条规则声明适用范围；`P023` 键集改为五键（`version` 只作观测）；`P008/P020/S*` 加 `a != null`；`P005` 对 unavailable 放行。新增一条 mutation：把 track 体喂给 P002 必须不红。

### 5. [high] seeder 只认 `startURLs`，而新 Profile 的 `startURLs` 默认是空数组

`BrowserProfile.init` 的 `launch: LaunchOptions = LaunchOptions()`（`Profile.swift:179,189`），`LaunchOptions.startURLs` 默认 `[]`（`LaunchOptions.swift:23,34`）；`BrowserRuntime.start` 只有在 `!startURLs.isEmpty || placeholders > 0 || restoreSession` 时才调用 `openStartPages`（`BrowserRuntime.swift:344-347`）——空 array 时连接口都不开。`§4.4` 的整个 seeder 以 startURL host 为唯一锚（PLAN:488），于是默认路径（新建/批量/自动化不带 URL）**不写任何 mid/sid**，首访 NA；`I009`、`§0.3` 的“首访前 mid/sid 为 36”与 `§8.9` 的“首报 NA/种子”看起来照旧通过，实际 seeder 根本没跑。

**新设备影响**：不是安全事故（NA 首访仍会得到新 muid），但方案宣称的“可预置”与确定性全部打折；E2E 若像仓库测试那样用本地 URL 会掩盖，真实用户则不一定。

**修法**：要么给 Stripe 用途的新 Profile 默认一个起始 URL（或在 UI 提示“要预置身份需填启动网址”），要么把 seeder 改成首次导航钩子（`Target.setAutoAttach` 后、首帧前注入）；至少加规则 `identity-no-start-url`（info/warn）与一条空 startURLs 的用例。

### 6. [high] “不清 `.link.com` / 不清无关商家 cookie”与实现相反，`§6.7` 的断言会红

`removeSiteData` 删的是整份 `Default/Cookies` 与 `Default/Network/Cookies`（`BrowserRuntime+Data.swift:320-329`），不是按名过滤——**所有 cookie 都会没**，包括 `lsid`@.link.com 和无关域的 `keep`@example.com；仓库测试自己就断言重置后 `cookieNames(...).isEmpty`（`CoordinatorEngineTests.swift:119,162`）。运行态的 DevTools 路径也同样会删 `.link.com`：`cookie(_:matches:)` 只要 cookie 域等于/是 `siteOrigins` 里某个 host 的父域就命中（`:111-118`），而 `siteOrigins` 含 `https://link.com`（`:298-300`），`.link.com` 会被 `$0 == domain` 命中。`§6.2`（PLAN:590-591）与 `§6.7`（PLAN:635-637“keep 与 .link.com 保留”）都写错了。

**新设备影响**：方向上是“更干净”，不影响 Stripe 判新；但每次换身份都会把 Link 账号登出且丢所有站点 cookie，这是产品语义，必须在 UI/文档里说清；照现状写测试会红。

**修法**：改成“重置 = 全 cookie 清空（含 Link 登录）”，测试改为断言 `lsid` 也被删；若要保住 Link 登录，则备份/恢复 `.link.com` 的 `__Secure-sid`/`lsid` 白名单，并新增对应测试。

---

## P2 — 会被服务端/脚本交叉抓到或直接判红

### 7. [medium] 预置只写 36 是对的，但 seeder 的“采纳任意 42”会把客户端永久分叉带进新身份

`§4.4` 第 3 步用 `^uuid36([0-9a-f]{6})?$` 判“合法”并原样采纳（PLAN:490）。服务端并不只查长度：小写 v4 UUID + 正确 6 位校验和才逐字回显；大写后缀、v1、v2、任意 6 hex 都会被换新（`work/x_b_upper.body`、`work/x_b_v1.body`、`work/x_b_var.body` vs `x2/N/P/R/S`）。客户端 `mt` 只要长度 42 就永远优先旧值（`v3.pretty.js:25504-25506`），所以一个“下划线合法但后缀错”的 42 一旦在 jar 里（导入、旧备份、别家工具写入），seeder 会采纳、不重写，服务端每次 POST 换 muid，客户端永远不收敛——`identity-chain-verify.md` C3 已经写明这个分叉，但方案只在“不写任意 42”里提了一句，没有采纳侧的防呆。

**新设备影响**：cookie 与任何服务端记录都对不上，比 NA 更可疑。

**修法**：首见一律写 36（不写 42）；对 jar 里已有的 42 只有“与最近一次 /6 响应的 muid 逐字相同”才算合法并采纳，否则覆盖为 36；`I001` 的校验和判据改成“与服务端回显比”，不是本地格式。加一条 imported-invalid-42 用例。

### 8. [medium] `b.n` 的断言与真实样本相反

`§1.3` 把 `b.n` 的目标写成 1,000–1,100 ms（PLAN:146），`§8.8` 断言“`b.n` 在 300–5000 ms”（PLAN:819）。但 **5/5 的第二份真实报文是 194.7 / 195.3 / 195.9 / 196.9 / 198.4 ms**（`p6-*-2.txt`，本轮逐份解码），全部低于 300。`b.n` 是模块求值时的 `performance.now()`（`mod-06.js:50`），随 iframe 创建时机漂移，不是固定的 1 秒。

**新设备影响**：无（值本身正常），但验收会假红，且“1000+”的文档预期会误导对 `b.n` 异常的判断。

**修法**：只保留 `b.n > t` 与 `0 < b.n < 60000`；首报单独给一个宽下界（例如 ≥ 950 只对“v3 自动帧首报”生效）；把第二报的 195 ms 写进 golden。

### 9. [medium] `challengeWindowSize` 在非 hosted 流程恒为 null，取值源是 `outerWindowWidth` 不是 `innerWidth`

`controller.js` 的 `Dj` 里 `challengeWindowSize: (c = o.outerWindowWidth, d = o.hosted, …, d ? (…分档…) : null)`（controller.js 单行，`browserScreenWidth` 前约 1.3 KB 处）。`§8.10`（PLAN:827）说“challengeWindowSize 由 innerWidth 分档、与 Profile 一致”，而 `§8.10` 的测试是本地 Elements 页（非 hosted）：该字段会是 `null`，拿不到 `01..05`。档位是**枚举码**，不是像素；窗口关系是 outer。

**新设备影响**：无；但 3DS 验收条会假红，且会把实现引向错误的窗口源。

**修法**：普通 Elements 只断言其余 11 键；把 `challengeWindowSize` 移到 hosted Checkout 用例，按 `outerWindowWidth` 计算 `01..05`，并断言全屏优化位为 05 的覆盖。

### 10. [medium] loopback 自检对 m.stripe.com 是必然的 CORS 失败，且测错了 sessionStorage 分区

`m.stripe.com` 的 ACAO 是常量 `https://m.stripe.network` + `allow-credentials: true`（`work/a.headers:9-10`，`badorigin/noorigin` 同样），没有反射。`§8.12` 却让 loopback 页用 collectors 直接 POST 真实 `/6`（PLAN:843-844）：请求会发出、Set-Cookie 会落，但 `xhr.status` 为 0，`mod-29.js:29-33` 只在 `status===200` 时 resolve，`p()` 永远 reject；`responseText` 读不到。**而 `stripe-identity` 恰恰需要从响应才能拿到 42 去再写回 cookie**（fixture collector 本身没有 `MidSidManager`，`_getID` 不在里面）；实际只能通过 CDP 的 `Network.getRequestPostData` 看请求、通过 `Storage.getCookies` 看 cookie 副作用。另外自检页的 sessionStorage 属于 **loopback origin**，不是 `m.stripe.network`；`stripe-session-cache`/`C010` 测的不是生产分区。`inner.html` 的 version 默认还是 `"4"`（`inner.html` 唯一一行），本地按原样服务会拿到 36 B 纯文本 `/4`，过不了 `MSG_REGEX`。

**新设备影响**：无；但自检会看起来“半绿”，且 SS 屏障的真实性没被覆盖。

**修法**：自检只通过 CDP body/cookie 断言，明确不读 response；把 SS 断言改成在真实 v3 链路的 m.stripe.network 帧里读；本地 inner 固定 `#version=6`；或给自检 host 做 `--host-resolver-rules` + 可信证书，从 `m.stripe.network` 源跑。

### 11. [medium] 分屏/平铺会用宿主屏幕覆盖派生窗口，做出 `innerWidth > screen.width`

`WindowArrangement` 通过 DevTools `Browser.setWindowBounds` 按 `NSScreen.visibleFrame` 算格（`WindowArrangement.swift:30-74`），宿主 2560 宽的单窗格就是 2560；而 `§3.6` 的派生窗口来自伪造屏幕（1728×1117，`innerW ≤ 1348`，位置也在伪造坐标内）。平铺一次后 `innerWidth`=2560 > `screen.width`=1728，`screenX/Y` 也跑到伪造屏幕外，`challengeWindowSize` 分档随之漂移。

**新设备影响**：不新不旧，但内帧自证矛盾的窗口/屏幕组合是可被 3DS/FPJS 直接读到的“假设备”证据。

**修法**：`WindowArrangement` 以 Profile 的伪造屏幕（或 `screenMetrics` 下的目录值）为 area；capability 未开时至少 clamp 到派生窗口；加 `window-screen-consistency` 检查（`outer ≤ screen`、`screenX+outerW ≤ screen.width`）。

### 12. [medium] `sec-ch-ua` 请求头缺失 Google Chrome 没人断言

引擎默认 UA-CH 只有 `Not/A)Brand;v=99` + `Chromium;v=148`（`out/report_headwin.json` 的 `hasUAD.brands`），XHR（含 `/6`）会带 `sec-ch-ua`：本地回显页实测头就是 `sec-ch-ua: "Not/A)Brand";v="99", "Chromium";v="148"`（`/tmp/langprobe/hdr.txt`）。真实 Chrome 的该头含 `Google Chrome`。方案只在 JS 侧修（`§2.4`）并且只在 C004 断言 `navigator.userAgentData.brands`（PLAN:770），到 P6 之前每一条 m2 请求都在服务端可见地“不是 Chrome”。

**新设备影响**：这是 WS 之外最直接的“不是普通 Chrome”标记，且比 JS 字段更早被看到。

**修法**：`§2.4` 加“请求头同步”验证；E2E 用 `Network.requestWillBeSent` 的 headers 断言 `sec-ch-ua` 含 `Google Chrome`、`sec-ch-ua-platform` 与 platform 一致；C004 扩到 headers。

### 13. [medium] `C004` 对 Edge 身份是错的

真实 Edge 的 Sec-CH-UA 是 `Chromium` + `Microsoft Edge` + GREASE，**不含 Google Chrome**；引擎自己的 Edge 输出也只多 `Microsoft Edge`（`engine.md` §4）。`C004` “CH brands 含 Google Chrome”（PLAN:770）会在所有 Edge Profile 上红。

**修法**：C004 仅在 `brand == .chrome` 时要求 Google Chrome；Edge 要求 `Microsoft Edge` 与 `Edg/` 同源；其余品牌按各自真机样本。

### 14. [medium] `I005` 的“三元组稳定”忽略 sid 30 分钟过期与 block 姿态的 guid churn

`__stripe_sid` 是 30 分钟 cookie、每个响应都换新（`v3.pretty.js:25715-25723`、`work/R2` 的 sid 换新），block 姿态下 guid 每条 POST 都变（`v2probe/logs/matrix.txt`）。`I005`（PLAN:753）却要求“两次启动三元组稳定”，跨 30 分钟的两次启动必红，block 姿态下也必红。

**修法**：I005 限定 allow 姿态且两次启动间隔 < 30 min，断言 guid+muid 稳定、sid 可不同；另加 block 变体只断言 muid 稳定。

### 15. [medium] `§8.7` 的“两 seed 只允许 o/j/f 变化”忽略了预设与 locale 是随机抽的

`IdentitySampler.sample` 自己 `choosePreset` 并 `choose(localeProfiles)`（`IdentitySampler.swift:160-182`），两个 seed 可能落到不同 preset/platform → `a.d`、`a.l`、`a.c`、`a.g` 全可能变（preset 若落到 Edge，`a.e` 的插件名也可能变）；`.font` 关着时 j 还不会变。该断言会红。`P1` 的“基线 0 违规”（PLAN:865）还要求对 5 份 **headless 800×600@1** 的 fixture 施加 `§1.2` 的 1728×1087@2 屏幕目标——S002 必红，S019/S020 在 P5/P4 之前也必红。

**修法**：探针固定 preset+locale+platform 后再谈“只允许”；S 规则按样本附带的期望值（或 capability 门）判定，P1 只对可复算子集（P 规则与 b.*）宣称零违规，S 的屏幕/字体项在 P4/P5 后才 block。

### 16. [medium] 缺 `navigator.connection`、执行计时与设备枚举等宿主面

`acs3ds.md` 第 74 行和 `shared.js:15080-15118` 证明 Stripe 的分析通道会带 `connection_rtt/downlink/effective_type`；`acs3ds.md` 第 65 行还列了 FPJS 读 `deviceMemory`/`hardwareConcurrency`；`§0.5` 只列了 Local Font Access/WebGPU/语音列表，没有 connection、`enumerateDevices`、`pdfViewerEnabled`、`matchMedia(prefers-*)`。另外 `t`/`at`/`b.n` 是同一台机器的执行时间签名，方案只把它们当校验对象，不当作关联信号。

**修法**：在 `§0.5` 明确 connection/媒体设备/计时都在宿主面；若要降关联，把 `connection` 与出口网络类型做一致性规则，并把 `t/at/b.n` 的分布记入 golden 以便定位；3DS/支付场景把 `enumerateDevices`、`pdfViewerEnabled` 加进 FPJS 观测。

### 17. [medium] `--disable-spoofing=screen`、`screenShimEnabled` 与派生窗口的开关语义没有落地

`--disable-spoofing` 的合法 token 只有 `font,audio,canvas,clientrects,gpu`（`engine.md` §1），而 `FingerprintAdjustment` 没有 `screen` case（`Profile.swift:53-66`）；`§2.1.5` 要求新增 `screen` token，但 `§3.1` 的字段清单与 UI 都没加。`§3.7` 的 `screenShimEnabled` 只出现在 struct 定义里（PLAN:393），没有赋值来源。`§3.6` 说“capability=false 时不派生窗口”（PLAN:380），但 `screenMetrics` 在 shim 下为 true（PLAN:392），到底以哪个为准不明。

**修法**：加 `FingerprintAdjustment.screen`（含标题/参数/全平台校验），`screenShimEnabled` 定义为“shim 已安装且未过期”，窗口派生改按 `screenMetrics` 判断，并在 `EngineCapabilities` 注释里写清两层。

### 18. [medium] 引擎升级后 `_mf` 缓存会让旧字体串继续压制全量 a

`stripe-session-cache` 只在 `capability.measureTextFixed=true && fresh` 时 fail（PLAN:558）。但字体表从无到有是**引擎升级**，不是 fresh：已有 Profile 的 `m.stripe.network` SS 里仍有旧 `_mf`，首次 ping 的 `a` 为 null，服务端拿到的 id 用的是旧位串；`document.fonts.check` 却按新表返回，页面内自相矛盾。

**修法**：把“引擎 sha / 字体 capability 变化”写进 `pendingIdentityReset` 的触发条件（或至少在 SS 里存一个 schema 版本，版本不符就清 `id/_mf/_ab`）；加规则 `session-cache-stale`。

### 19. [medium] `P012` 只查长度形态，放过服务端会拒的 42

`P012`（PLAN:719）写“合法 36 或合法 42（前缀 uuid + 6 hex）”，没有 version/variant/小写后缀要求。服务端对 v1、variant c/d、大写后缀都换新（`work/x_b_v1.body`、`x_b_var.body`、`x_b_upper.body`），这些值会通过 P012 却制造永久分叉。`I001` 有正确正则，但 P012 与它不一致。

**修法**：P012 直接复用 `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}([0-9a-f]{6})?$`，并单列 uppercase/v1/var 的反例。

### 20. [medium] `C011`/`I004` 与 pinned Checkout 冲突，`P013`/`P018` 缺限定词

- `C011`“任何带 mids 的请求与 cookie 一致”（PLAN:775）在 `__checkout.mids` 页面上必红：`_doNotPersist*` 下 cookie 根本不参与（`v3.pretty.js:588292-588345`、`591948`、`592207`），`I008` 只跳 I003/I004。
- `P013` 写 `f=false、g=true、h=true`（PLAN:720），在全是 `b.` 前缀的邻居里没写 `b.`，而 `a.f` 是屏幕串、`a.g` 是时区数字，照字面会套错槽。真实值：`b.f=false/b.g=true/b.h=true`。
- `P018` 要求 `b.u/b.v == domain`，但 5/5 首报的 `b.v` 都缺（referrer 为空，`mod-06.js:152-153` 的空值保护 + `getUrlDomain("")`），需要“若存在”。

**修法**：C011 加 `I008 == false` 前置；P013 统一写 `b.f/b.g/b.h`；P018 写“`b.u`（url 有域时）与 `b.v`（referrer 有域时）”。

### 21. [medium] 验证体系相对真正决胜的改动过重，且有 3 处“先改 mock”的对齐风险

P1 的 68 条规则 + golden + provenance + canary + 3DS 全链路约 20+ 人日，可其中一半是“给一个会被 P4–P6 改写的引擎写 golden”（S 规则的屏幕/字体、C006/C007/C008）。同时 `§8.1` 的“6 份首报”实际是 5 份，`Appendix B` 只列了 10 个 payload 哈希、没有 `live5-macos-on-747474.json` 的哈希（PLAN:681,1015-1029）；`§0.1` 的“三处双空格”实际是两处（k、m 两个空槽；本轮按 payload 复算 683 字符、`count("  ")==2`，`id` 命中）。

**修法**：P1 只做 P 规则与 b.w/b.b/b.c/b.u 复算、`/6` schema 与 cookie 身份规则；S 规则拆成“首报语义”和“能力项”。补 live5 哈希；双空格改“两处”。

### 22. [low] `§7.2` “不向内帧注入脚本”与既存实现矛盾

`IdentityShim` 已经是 `all_urls/all_frames/MAIN/document_start`（`IdentityShim.swift:64-72`），`§4.6` 的 SS 屏障与 `§3.9` 的 ScreenShim 也都要求注入 `m.stripe.network`。CSP `script-src`（`inner.headers:6`）只约束页面 `<script>`，内容脚本不受它约束——表述应改成“不向内帧插 `<script>` 标签，只用内容脚本”，否则施工会误删 all_frames 或另起注入通道。

### 23. [low] 新 Profile 的 `Default/` 目录在写 Preferences 前不存在

`§4.3` 在 `PrivateDirectory.ensure(directory)`（只建根，`BrowserRuntime.swift:257`）之后就写 `directory/Default/Preferences`；新目录没有 `Default`，写会失败。seeder 的 `Storage.setCookies` 不依赖文件，但 posture 写入依赖。修法：`ThirdPartyCookiePosture.apply` 里 `PrivateDirectory.ensure(Default)`。

### 24. [low] 其余小项

- `§8.8` 的 `j.at ≤ 8` 偏紧（实测 5.7–7.4，慢机可能越界），建议 ≤ 12 或只在同机 golden 比。
- `§8.8` 的 `b.n` 与 `§8.7` 的“只允许 o/j/f”见 8/15。
- `SelfCheck` 的 `stripe-identity` 会在真实首次访问之前给 profile 建立 m/guid（副作用有益），但要在文档里说明它改动了被检对象。
- `§7.6`/`I011` 写 m 为“400 天”，`verify-m-anchor` 的 Set-Cookie 是 730 天；Chrome 存储时截到 400（`v2probe/logs/m_attr_engine_mode0.txt` 的 expires 差 ≈ 399.98 天）——两处都对，但建议在正文注明“线上头是 2 年、Chrome 上限 400 天”，避免被当成矛盾。
- `deviceIdentity` 由 seed 派生，seed 已由 store 保证唯一；但如果将来放开“同 seed 多 profile”，mid 会撞，建议 `checkForConflicts` 同时检查 `deviceIdentity`。
- `E001` 把 `id:"unavailable"` 设为 block，意味着一个无害的采集异常会红全套；建议首报 warn、连续两次才 block。

---

## 最强的三个残留风险（即使以上全修完）

1. **同一出口 IP 与同一网络栈**：所有 Profile 共用一个出口时，服务端一半的关联已经在网络层发生；TLS/JA3、HTTP/2 特性、RTT 都来自同一构建与同一线路。只有“新 Profile 配新出口（最好是不同 ASN/地区）并让语言/时区/connection 跟随出口”才算真新设备；方案 R13 只给 warn，应升级成发布门。
2. **两个不可控的第二采集面**：FPJS Pro（Link/3DS 前）与发卡行 ACS（method/challenge 帧）在 m2 之外独立采集，字段集由对方决定；方案只能保证“自洽 + 按 seed 分离”，不能保证“像真机”。其中 WebGL/audio 栅格、字体字形、Local Font Access、语音列表仍是宿主，3DS 挑战率上升是必然的，别把“免检”写进验收。
3. **服务端黑盒聚类 + 同构建簇**：id/muid/guid 全换也不等于不被归并；同版本引擎 148、同一扩展集、同一 canvas 噪声实现、近似的 `t/at/b.n` 分布，都是可聚类的族信号。方案应把“两个全新 Profile 的 id/三元组不同”当必要条件，把“金丝雀观察到的服务端行为差异”当唯一充分性证据，并预留换引擎/换网络做 A-B 的预算。

---

## 附：方案里已经做对、不要回退的部分

- 以 `m`（HttpOnly、host-only、服务端签发）为唯一 guid 锚，同时清 mid/sid/m 的三层身份模型；以及“保留 cookie 只算同设备升级”的语义。
- 3PC 用 `profile.cookie_controls_mode`（`v2probe/logs/matrix.txt` 全矩阵）而不是 `--disable-features`；P0.3 把 `Sec-Fetch-Storage-Access: active` 写成通过标准。
- 不预置 m、不预置 42、只写 36 让服务端补校验和；id 只让脚本算、不压缩双空格。
- 屏幕/字体/measureText 走 C++ 读取点，页面注入只留临时 ScreenShim 与 SS 屏障；`--force-device-scale-factor` 与 CDP Emulation 的否决都有现场证据。
- 规则/证据分级、mutation、golden 不自动 bless、`he=false`/`pinned`/IP-host 的特殊路径表。