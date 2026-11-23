# Stripe 新设备方案（内核优先 · 身份再生 · 可证伪验证）

- 交付日期：2026-11-23（终稿·按批判意见修订，可直接施工）
- 目标仓库：`/Users/riba2534/airepo/anybrowser`
- 分析对象：`https://m.stripe.network/out-4.5.45.js`（88,737 B，SHA-256 `f2a8a36c74c59cfbe7a73d441cfd180ca6e6a9942a74ef9b240191d1c6056a59`）、`inner.html`（930 B，`92844e6b…`）、`https://js.stripe.com/v3/`（`495eb6229865241b1cad8f660b1236a1bbe037273968861c24f870c6d1681840`）、controller/shared、3DS 帧
- 内置引擎：Fingerprint Chromium `148.0.7778.215`（`d918c691ce56648bc555f8f399c29fc83eb02224165a086491688d01707170cb`）
- 方法：外部 JS 只做文本/AST 读取，未 `node` 执行；引擎结论来自二进制字符串/反汇编与真实引擎探针；网络结论来自真实抓包与 curl
- 行号约定：`beautified.js` = `/tmp/stripe-out-4.5.45/beautified.js`；`mod-NN.js` = `/tmp/stripe-re-20261122/modules-pretty/`；`v3` = `/tmp/stripe-plan-v2/work/v3.pretty.js`；引擎偏移均为 `Chromium Framework` 文件偏移（`__TEXT` fileoff==vmaddr）
- 证据等级：**[C]** 本轮或前序现场产物直接确认；**[P]** 由源码/二进制直接推出但未全链路实测；**[I]** 推断
- 本轮按外部批判逐条修订的记录见 §11；会改变旧断言红绿含义的条目集中在 1/2/6/7/15。

> 路线：**在读取点解决，而不是在页面里补**。所有 15 个特征由 Blink/C++ 与启动参数产生；身份链由 App 在导航前以 cookie 种下并在每次启动采纳；所有清理在停止态完成；正确性由一套可复算的 oracle、golden 和真实 E2E 证明。页面注入只保留「字体/屏幕临时兜底」与「新身份启动时清 sessionStorage」两种，引擎补丁落地后 measureText 注入下线。

---

## 修正三份草稿与旧文档的硬错误（先看）

| # | 草稿/旧文档 | 实测事实 | 本方案处理 |
|---|---|---|---|
| C1 | draft-0 §0.3 断言 `profile.cookie_controls_mode=0` 无效 | `/tmp/stripe-plan-v2/v2probe/logs/matrix.txt`：profile 级 mode0 **有效**（m 落盘、guid 跨载稳定），顶层 mode0 才无效；`--disable-features` 也无效 | 用 `Default/Preferences` 的 `profile.cookie_controls_mode`，不写引擎开关（§6.5） |
| C2 | draft-0 §7.2 每次启动为每个 host 新 mint uuid | 重启后 jar 里已有 mid，应采纳；mint 会让同一 Profile 每次换 muid | 先读、后采纳、只在缺失/非法时写入（§4.4） |
| C3 | draft-0 §7.4 删 `Default/Session Storage` 就不复活 | `/tmp/stripe-plan-v2/work2/session-restore-iframe.txt`：删目录后 restore 仍带回 `_mf=1100` | 清 `Default/Sessions` + 强制关 restore + document_start 清 `id/_mf/_ab`（§4.6、§6.1） |
| C4 | draft-0 §9.1 `a.n.at ≥ 20ms` | 5 份真实首报 `n.at` 0.2–0.3，`n.t` 20.8–21.9（`p6-*-1.txt`） | 断言 `n.t ≥ 19`、`n.at ≤ 5`（§8.8） |
| C5 | draft-0 §5.3 `outer-inner=121` | 引擎自身 121（`out/report_winA.json`、`winC.json`）；真实 Chrome 158 是 143（`probe/chrome158-headed-screen.json`） | 按引擎实测常量 121 派生窗口；真实 Chrome 仅作参考（§3.6） |
| C6 | draft-1 步骤 6 macOS `colorDepth=30` | 真实 Chrome 158 在 M 系列上是 24（`probe/chrome158-headed-screen.json`） | 全部平台目录 24 Bit，30 仅留作可选（§3.3） |
| C7 | draft-1 风险 11 / 步骤 12 继续阻断 3PC | 阻断时 m 永不落盘、guid **每个 POST** 都换（`matrix.txt`）；Chrome 148/158 默认 allow | 默认 mode0，blocked 作显式档（§6.5） |
| C8 | draft-2 P002 要求顶层键含 `i` | 10 份真实 payload 全无 `i`；`canvasB64` 在 `beautified.js:1372` 声明后从未赋值，`:1392` 传的是 undefined | 规则改为「无 i」；出现时只 warn（§8.4） |
| C9 | draft-2 P018 `b.u==getUrlDomain(b.b)` | `b.b` 已被盐哈希（`beautified.js:1347-1349`），`b.u` 来自哈希前的明文（`:1345`）；真实样本 `b.b=https://<hash>`、`b.u=app.link.com` | 用捕获的明文 url/referrer 复算 b.u/b.v（§8.4） |
| C10 | draft-2 P023 要求 track 体含 `version` | v3 发的消息含 `version`（`v3:25756-25765`），但 inner 监听器重建的是五键体，`version` 只作 beacon 路径第二参（`inner.html` 唯一一行；`mod-10.js:95-106`） | P023 用五键体、version 只观测；track 喂给 P002/P005 必须不红（§8.3、§8.4） |
| C11 | draft-2 把 `495eb6…` 叫 collector hash | `495eb6…` 是 v3_plain.js；collector 是 `f2a8a36c…` | PROVENANCE 按文件名逐一列哈希（§8.1） |
| C12 | draft-2 步骤 8 / C4 要求第二条 POST 必为 42 | 实测 3 条 POST 全在响应前发生，全部 NA；响应最后才到（`live5-macos-on-747474.json` t=9.35/10.034/10.515） | 断言响应后 cookie 为 42，响应后主动触发新 ping 再断言 42（§8.8） |
| C13 | draft-0 §0.3 引用「`--fingerprint-screen-*` 死字符串」但把 3PC 也归给引擎 | 屏幕开关确实死（`engine.md` §1-2）；3PC 是 pref 层 | 屏幕改引擎；3PC 留在 App（§2、§6.5） |

---

## 0. 威胁模型与判定链

### 0.1 对手面是什么

`m.stripe.network/out-4.5.45.js` 是一个**完全被动**的采集器：

- 15 个 extractor 按固定注册表 a–o 顺序注册（`mod-11.js:27`）。每个 extractor 只读一个原生属性或做一个纯页面探测：CookieSupport（`mod-16.js:15-17`）、DoNotTrack（`mod-17.js:15-27`）、languages（`mod-20.js:15-22`）、platform（`mod-21.js:15-17`）、plugins（`mod-22.js:17-28`）、screen（`mod-23.js:15-20`）、timezone（`mod-24.js:15-21`）、touch（`mod-25.js:15-21`）、storage（`mod-12.js:15-28`）、fonts（`mod-18.js:54-165`）、graphics 常量空串（`mod-19.js:14-16`）、UA（`mod-26.js:15-17`）、flash（`mod-27.js:15-32`）、adblock DOM bait（`mod-28.js:15-43,91-92`）、400×60 canvas md5（`mod-08.js:17-33`）。
- `id = md5(15 个 value 以单个 U+0020 join)`（`beautified.js:1322-1327`；`mod-06.js:137-141`）；`k`/`m` 恒空串，join 串因此恰有**两处**双空格（k、m 两个空槽，`mod-19.js:14-16`、`mod-27.js:28-45`；按 5 份首报复算 join 683 字符、`count("  ")==2` 且 id 命中）。
- `b` 上下文由页面自算（`beautified.js:1256-1276`），含 `Object.keys(document)`、`Object.keys(navigator)`；`b.w=<ms>:sha256hex(h+(ms+1))`（`beautified.js:1311-1314`）。
- 传输是 `btoa(encodeURIComponent(JSON.stringify(payload)))` 的 `withCredentials` POST 到 `https://m.stripe.com/6`（`beautified.js:5611-5638`；`mod-29.js:18-35`）。
- 采集器**零主动反篡改**：`Proxy`/`Reflect`/`getOwnPropertyDescriptor`/`debugger`/`Function.prototype.toString`/`webdriver`/`cdc_` 在 6,158 行里 0 命中（`integrity.md` §11.1）。它靠被动值与服务端交叉判定。

本采集器**不是全部采集面**：Link 特性下 v3 会触发 FingerprintJS Pro（wanderlust）在 3DS/Link 路径独立采一遍（§0.3 第 7 条、§2.9），发卡行 ACS 还会在挑战帧采自己的字段；m2 的结论只覆盖 m2 面。

因此：**页面上任何 JS patch 都能被值/形态/计时侧写看出；C++ 读取点不产生 JS 帧，是首选。**

### 0.2 服务端的判定链（推断，[I] 部分）

1. **传输与新鲜度**：`h` 是 20 位小写 hex nonce，`b.w` 是 `Date.now()` 与 `h+1` 的 sha256（`beautified.js:1302-1314`）；时钟偏差、`b.w` 不可复算、`b.n` 早于 `t` 都会先被看见。
2. **结构**：`a` 必须 a–o 15 键、`id` 必须等于 join 的 md5（`beautified.js:1322-1327`）；`at` 只允许在 `a.j`/`a.n`（`mod-02.js:39-48`）；顶层无 `i`（`beautified.js:1372,1392`）。
3. **环境可信**：platform/UA/UA-CH/plugins/fonts/screen/storage/touch/language/timezone 互相自洽，并与出口 IP 的地区与时区相容。
4. **身份**：`b.d/b.e` 对应 muid/sid；服务端以 `.m.stripe.com` 的 HttpOnly `m` 锚定 guid（`work/a.headers:5`、`verify-m-anchor.md` §1.5：带 m 回显同 guid，不带就新发）。
5. **设备类聚类**：`id` 相同、字体向量相同、屏幕串相同、canvas 相同，都会被当成同一设备类或同一台机。

### 0.3 「新设备」的可操作定义（验收对象）

一个 Profile 同时满足才算：

1. **身份**：重置后 cookie jar 与相关本地存储全空（含 FPJS 的 `__Secure-f-visitor-id`、localStorage `_vid`/`__fpjs_pvid`@js.stripe.com、`stripe.link.persistent_token`，见第 7 条）；首访前 `__stripe_mid`/`__stripe_sid` 为 36 位小写 uuid4（种子值）；首报 `b.d/b.e` 等于种子或 NA；响应后 mid/sid 变为 42，且 36 前缀不变；`m` 在 allow 姿态下存在且跨载稳定，在 block 姿态下不存在且 guid 每次变。
2. **可复算**：`id` 由 15 个真实 `a.*.v` 复算命中；`b.w`、`b.b`、`b.c`、`b.u` 全部复算命中；顶层无 `i`；`at` 只在 j/n；`b.n > t`。
3. **自洽**：15 项与平台/引擎/出口一致；`Object.keys(navigator)===[]`、`Object.keys(document)===["location"]`（内帧）。
4. **可分离**：两个新 Profile 的 `guid/muid/sid` 全不同，`id` 不同，且 canvas 与「screen 或 font」至少各一项不同。
5. **时序**：停→清→种子→首访；`restoreSession` 不参与；首帧前无旧 sessionStorage。
6. **3DS/Checkout 自洽**：`browser` 全字段（12 键）由同一 Profile 推导；`challengeWindowSize` 只在 hosted Checkout 非 null，按 controller 的 `outerWindowWidth` 输入（v3 以 `window.innerWidth` 赋值）落 01..05 档；Checkout 的 `__checkout.mids` 被识别为 pinned。
7. **第二采集面（FPJS Pro / wanderlust）**：首次 Link/3DS 前 `__Secure-f-visitor-id`、`_vid`、`__fpjs_pvid`、`stripe.link.persistent_token` 皆无；触发后建立的新 visitor 的 `linkedId` 等于本 Profile 本次的 stripeJsId（规则 `fpjs-visitor`）。它的 WebGL/audio/hardwareConcurrency/deviceMemory/screen 帧至少按 seed 分离且跨帧一致（§2.9）；wanderlust 帧跨域，只有引擎与 all_frames 内容脚本能覆盖。

**不充分的证据**：只有 `id` 不同（canvas 一变就不同）；只有 muid 新（m 还在）；只有屏幕新（同型号）。

**预期形态**：新 Profile 的 3DS 挑战率本来就会上升（设备绑定在卡上，陌生向量常见 `C`，`acs3ds.md` §4）——这是正确的「新设备」；要避免的是「新 cookie + 与旧 Profile 完全相同的向量」。新设备也不等于免检。

### 0.4 本方案不打什么

- 不改写 `m.stripe.com` 的请求体/响应体，不做 MITM。
- 不手写 `id`、不压缩双空格。
- 不用页面脚本改 `navigator`/`document` 的自有可枚举属性。
- 不伪造服务器锚点（m 只由服务端签发）。

### 0.5 全局残余事实（无法在单机解决，必须明说）

- 引擎 148 落后本机 Stable 159 共 11 个大版本（`engine.md` §7）；所有 Profile 共享 `Chrome/148`，这是全局簇。
- 出口 IP 若所有 Profile 共用一个，关联度只降一半；新设备应与新出口成对（发布门，不只是一条 warn）。
- TLS/JA3/HTTP2 特性来自 148 的 Chromium 网络栈，不受指纹配置影响。
- `navigator.connection`（`effectiveType`/`rtt`/`downlink`/`saveData`）来自宿主网络栈与线路，Stripe 分析通道会带 `connection_rtt`/`downlink`/`effective_type`（`acs3ds.md` 第 74 行；`shared.js:15080-15118`）。只能与出口网络类型做一致性校验，不能改值。
- `navigator.mediaDevices.enumerateDevices()`、`pdfViewerEnabled`、`matchMedia('(prefers-*)')` 同样是宿主面；FPJS 读设备枚举与 `deviceMemory`/`hardwareConcurrency`（`acs3ds.md` 第 65 行）。
- `t`/`at`/`b.n` 是同一台机器的执行与模块求值计时签名，分布可聚类（§8.5 记入 golden 供定位）。
- 本地字体枚举（Local Font Access）、WebGPU adapter、语音列表仍暴露宿主；Stripe 本版本不读，3DS/FPJS 可能读。

---

## 1. 目标设备画像与逐字段取值矩阵

### 1.1 默认目标画像

默认只出 **macOS 26 · Chrome 148 · MacIntel**：本机引擎对 macOS 的原生面最真（字体关闭时与真实 Chrome 158 的 23/55 位串逐项相同，`engine.md` §3；plugins/keys/DNT 与 Chrome 158 一致，`engine.md` §6）。Windows/Linux 身份只在 fork 的字体与屏幕补丁落地后启用。

默认画像（由 seed 与目录决定）：

- screen 1728×1117，avail 1728×1087，availTop 30，availLeft 0，colorDepth/pixelDepth 24，dpr 2（14/16 寸 MacBook 的缩放分辨率；真实 Chrome 158 在同机为 2560×1440/availTop 30/24/2，`probe/chrome158-headed-screen.json`）
- fontProfile `macos26`，variant 0/1 由 seed 选；vector 取真实参考机
- CPU 8/10，deviceMemory 16（M4 机型集合，`EngineHardwareTable.swift:105-107`）
- language/timeZone = 出口地区；无出口时 `en-US`/`America/New_York`

### 1.2 15 个特征逐项

「含义」列回答：这一项对「像一台新设备」意味着什么；「做法」列回答 AnyBrowser 该做什么。

| 槽 | extractor 与证据 | 目标值 | 来源 | 跨 Profile 熵 | 对「新设备」的含义 | AnyBrowser 做法 | 必须避免 |
|---|---|---|---|---|---|---|---|
| a | `navigator.cookieEnabled.toString()`（`beautified.js:3120`；`mod-16.js:15-17`） | `"true"` | 引擎原生 | 无 | 证明存储可用；false 会连带 i 退化 | 保持原生；不关 cookie | 打开任何禁 cookie 开关 |
| b | `navigator.doNotTrack` 判真（`beautified.js:3286`；`mod-17.js:15-27`） | `"false"`（属性为 null） | 引擎默认 | 无 | DNT=true 是隐私扩展痕迹 | 保持 null；不随机 | 隐私扩展/偏好改 DNT |
| c | `navigator.languages.join(",")`（`beautified.js:4025`；`mod-20.js:15-22`） | `"en-US,en"` 等有序列表 | `--lang` + `--accept-lang` + `-AppleLanguages` | 出口 locale | 必须与出口国、Accept-Language、Intl 同源 | 采样器把 locale 绑成 bundle；三者同写 | 单项列表；语言与出口矛盾 |
| d | `navigator.platform`（`beautified.js:4194`；`mod-21.js:15-17`） | `MacIntel`；Windows `Win32`；Linux `Linux x86_64` | `--fingerprint-platform`（映射 `0x95BA1E0-0x95BA350`） | 平台预设 | 平台是其余项的根；错一处全盘矛盾 | 只由 preset 决定；平台变更重采样 | 无 platform 却填 screen/font |
| e | 遍历 `navigator.plugins`，5 条 PDF、`++` 连接（`beautified.js:4362`；`mod-22.js:17-28`） | 5 条 `internal-pdf-viewer` 全集 | 引擎原生（`out/report_pplugE.json`） | 无 | 真实 Chrome 148 的固定形态；拦截扩展会改 | 不装插件类扩展；不在内帧写 DOM | 扩展增删插件；用 Edge 插件名配 Chrome 身份 |
| f | `availWidth+"w_"+availHeight+"h_"+colorDepth+"d_"+devicePixelRatio+"r"`（`beautified.js:4542`；`mod-23.js:15-20`） | `1728w_1087h_24d_2r` 之类 | 引擎 screen 配置 | 平台目录×seed | **id 的高熵槽**；所有 Profile 同值即同屏设备 | 引擎 Screen/DPR/media patch；目录见 §3.3 | headless 800×600；avail>screen；macOS 30bit |
| g | `-getTimezoneOffset()/60`（`beautified.js:4712`；`mod-24.js:15-21`） | `-5`/`8`/`5.5` | `--timezone` | locale 目录 | 与 Intl、出口矛盾即异常 | 与 c 同一 bundle；DST 由引擎处理 | 手改其一；与出口不符 |
| h | `"ontouchstart" in window`（`beautified.js:4881`；`mod-25.js:15-21`） | `"false"`；`maxTouchPoints=0` | 引擎默认；可选 `--fingerprint-touch` | 预设 | 桌面 Mac 无触点；成对才自洽 | 桌面固定 false；touch 与 maxTouchPoints 联动 | `ontouchstart` 有而 maxTouchPoints=0 |
| i | session/localStorage 试写（`beautified.js:2677-2691`；`mod-12.js:15-28`） | `"sessionStorage-enabled, localStorage-enabled"` | 引擎原生 | 无 | 任一 disabled 会同时废掉 Stripe 的 id 缓存 | 新设备清内容不关 API；内帧可写 | 第三方存储被分区阻断 |
| j | 55 个字体逐个对三个 generic 基线测宽（`beautified.js:3508-3681`；`mod-18.js:112-165`） | 55 位平台参考串，bit 1=与 monospace 可区分 | 引擎 font profile 表（§2.3） | profile 变体×seed | **id 的高熵槽**；缺 Segoe/Calibri 是「假 Windows」的一眼证据 | 内核表 + 参考向量；clean/office 变体 | 逐 bit 随机翻；`"unavailable"`；macOS 出现 Segoe |
| k | 无读取（`beautified.js:3860`；`mod-19.js:14-16`） | `""` | 常量 | 无 | 空串造成 join 双空格 | 保持空 | 把 WebGL 串塞进来 |
| l | `navigator.userAgent`（`beautified.js:5050`；`mod-26.js:15-17`） | reduced `Chrome/148.0.0.0` + 平台 token | 引擎 UA 生成 | 引擎版本（全局相同） | 版本是全局簇；必须与 UA-CH 同主版本 | 只由引擎；brand 默认 Chrome | 伪造更高版本；Chrome 身份带 `Edg/` |
| m | Flash（`beautified.js:5217`；`mod-27.js:15-32`） | `""` | 无 Flash 分支 | 无 | 空串造成 join 双空格 | 保持空 | `"no-flash-plugin"`/`"mime-types-unavailable"` |
| n | 20 ms bait div（`beautified.js:5413-5430`；`mod-28.js:15-43`） | `"false"` | 引擎原生探测 | 无 | 拦截扩展会翻 true | 不装 adblock；新身份清 `_ab` 恢复首次探测 | clientHeight 被扩展改 |
| o | 400×60 两段文字 + 😃，`md5(toDataURL())`（`beautified.js:1772-1792`；`mod-08.js:17-33`） | 32 位小写 hex，同 seed 稳定 | 引擎 canvas 噪声 | seed | **id 的高熵槽，必须变**；跨调用必须稳定 | `.canvas` 默认开；golden 断言稳定性 | 每次随机；emoji 路径漏掉 |

**形态常量**（不制造差异，但改了就露）：`a.e` 的 5 条插件与 `++`、`a.i` 的 enabled 串、`a.a=true`、`a.b=false`、`a.h=false`、`a.k=""`、`a.m=""`、顶层无 `i`。

**熵的等级**（决定验收要求）：

- 高熵：o（canvas）、f（screen）、j（fonts）。
- 低熵：c/g（locale）、d（平台）、l（引擎版本）。
- 无熵：a/b/e/h/i/k/m/n。

### 1.3 `b` 上下文逐键

`b` 由 `browserFeatures()`（`beautified.js:1256-1276`）与 sourceData 合并；任何一项都是交叉信号。

| 键 | 目标 | 来源/实现 | 证据 | 失败形态 |
|---|---|---|---|---|
| b.a | `""`（直接打开）或盐哈希 | 内帧 hash 的 referrer，脚本自算 | `beautified.js:1347-1349`；`mod-04.js:62-64` | 明文 referrer 出现在 b.a |
| b.b | 商家 URL 的盐哈希；stripe.com 主域原样 | 内帧 hash 的 url | `beautified.js:1348`；`mod-04.js:86-93` | 哈希算法/ua 段不符 |
| b.c | title 的 sha256WithSalt | 内帧 hash 的 title | `beautified.js:1349`；`mod-04.js:62-64` | 不可复算 |
| b.d/b.e | 首报 NA 或 36；随后 42 | 来自 cookie/URL | `beautified.js:1329-1340` | 与 cookie 不一致；42 无校验和 |
| b.f | `false` | `new Audio().mozSrcObject===null && srcObject===undefined` | `beautified.js:1256-1276` | 被 polyfill 改 |
| b.g | `true` | 不带 new 调 `ArrayBuffer()` 抛错 | 同上 | `ArrayBuffer` 被包 |
| b.h | `true` | `Array.from("hello")` 成功 | 同上 | 被 polyfill |
| b.i | `["location"]` | 内帧 `Object.keys(document)` | 5 份真实 payload 全部 | 扩展/注入加 own key |
| b.j | `[]` | 内帧 `Object.keys(navigator)` | 5 份真实 payload 全部 | `defineProperty(navigator,…)` |
| b.n | `performance.now()`，随帧创建时机漂移：v3 自动帧首报 1,056–1,101 ms，第二份报文 194.7–198.4 ms | 模块求值时刻 | `live5-macos-on-747474.json` t≈10 s 的首帧；`p6` 首报 b.n 1,056–1,101、次报 194.7–198.4（5/5） | 被注入抬高或整帧被提前创建 |
| b.u/b.v | url/referrer 的明文域名（b.v 在 referrer 为空时缺失） | `getUrlDomain` 在哈希前调用 | `beautified.js:1345-1346`；5/5 首报无 b.v | 用哈希后的 b.b 去取域名（draft-2 的错） |
| b.w | `ms:sha256hex(h+(ms+1))` | 真实系统时钟 | `beautified.js:1311-1314` | 时钟偏 >2 s；不可复算 |

**硬约束**：`b.i`/`b.j` 只能由真实 DOM 生成；`b.n` 同帧恒定；`b.u/v` 用明文；`b.w` 依赖校时。

`t`/`at`/`b.n` 不只用于自校验，也是本机执行时序的关联信号：同机多次会聚在同一量级（首报 `n.t` 20.8–21.9、`n.at` 0.2–0.3、次报 `b.n` 194.7–198.4，`p6-*-1.txt`/`-2.txt`），换引擎或换硬件才会整体漂移；分布记入 golden，但不做跨机硬门槛。

### 1.4 外壳与计时

- `id`：脚本算（`beautified.js:1322-1327`），不手写。
- `v2`：默认 1；交互时 v3 发 2（`v3:25745`），强制全量 `a`。
- `t`：15 项总耗时，5 位有效数字（`beautified.js:1390`）；`t ≥ max(a.*.t)`，实测 220–300 ms。
- `at`：只允许 `a.j`（5.7–7.4 ms）与 `a.n`（0.2–0.3 ms）；`at ≤ t_i`。
- 顶层 `i`：不存在；出现则 warn。
- `h`：20 位小写 hex（`beautified.js:1302-1309`）。

---

## 2. 引擎补丁清单（按风险从高到低）

所有补丁在 fork `adryfish/fingerprint-chromium` 的 `148.0.7778.215` tag 上进行，分支 `anybrowser/148`，一补丁一 commit。现有 fingerprint 解析器位于二进制 `0x14D85A0–0x14D8B1C`（`engine.md` §1），补丁只扩展它。

本节的文件名/函数名按 Chromium 148 源码结构给出 **[P]**（二进制只证明函数与 gate 的地址）；行为是否达成一律由 §8 的探针验收 **[C]**。源码定位在 fork 内以「按地址附近的字符串/调用点反查」为准，不照抄路径。

### 2.0 风险最高的前置：capability 版本与基线构建

**问题**：fork 若不可构建/不可签名，整个方案降级为 App 侧伪装。

**改动**：

- 分支完成后先构建**未改基线**，产物版本改为 `148.0.7778.300-anybrowser.1`（只改版本号），记录 `CFBundleShortVersionString` 与 sha256。
- 用未改基线跑 §8.7 的全套探针，逐项与 `148.0.7778.215` 对比；差异必须为零。
- `scripts/versions.env:7-9` 增 `engine_repository=riba2534/fingerprint-chromium`、`engine_version=148.0.7778.300`、`engine_revision=anybrowser.1`；`scripts/build-app.sh:7-8` 用 `${engine_repository}` 拼 URL；`BundledVersions.swift:5-9` 与 `VersionConsistencyTests.swift:22` 同步。
- `EngineCapabilities` 以**版本 + 运行时探针**判定；仅当 `major.minor == 148 && build >= 300`（或已合并补丁的更高分支）且探针通过时开启。旧版本一律 false。

**验证**：基线 DMG 的版本是 `.300`；探针与 `.215` 逐项一致；`codesign --verify --deep --strict`；sha256 记录；`EngineCapabilitiesTests` 表：`.215` false、`.300` true、`150.0.7871.186` false（未合并分支）、非法版本 false。

**回退**：保留发布前的旧 DMG 与版本锁；App 用 capability 自动降级。

### 2.1 屏幕、DPR、媒体查询、headless

**改动**（按依赖顺序）：

1. 扩展 fingerprint 配置结构（浏览器进程解析 + renderer 下发）：`screenWidth`、`screenHeight`、`availWidth`、`availHeight`、`availTop`、`availLeft`、`colorDepth`、`pixelDepth`、`deviceScaleFactor`。
2. `third_party/blink/renderer/core/frame/screen.cc`：`Screen::width/height/availWidth/availHeight/availLeft/availTop/colorDepth/pixelDepth` 先读配置，缺省回退宿主；`orientation()` 由 width/height 推导（横屏 `landscape-primary`/0°，竖屏 `portrait-primary`/90°）。
3. `third_party/blink/renderer/core/frame/local_frame.cc` 的 `DevicePixelRatio()`：返回配置 dpr。`LocalDOMWindow::devicePixelRatio()`（`local_dom_window.cc`）与 `media_query_evaluator.cc` 的 `resolution`/`-webkit-device-pixel-ratio` 都经它取值，因此两条链天然一致。
4. headless：在 headless 的 window 创建路径按 `--window-size`/`--window-position` 设定 outer/inner，且 `Screen` 不走 `800×600` 回退。
5. `--disable-spoofing` 增加 `screen` 子串；关闭后全部回退宿主。

**复活死开关**：`--fingerprint-screen-width`（226227466）、`--fingerprint-screen-height`（226227491）、`--fingerprint-device-scale-factor`（226227517）；新增 `--fingerprint-screen-avail-width`、`--fingerprint-screen-avail-height`、`--fingerprint-screen-avail-top`、`--fingerprint-screen-avail-left`、`--fingerprint-color-depth`、`--fingerprint-pixel-depth`。

**含义**：f 是 id 的第二高熵槽；不补则所有 Profile 同一个屏幕值（`engine.md` §2 的 report 矩阵已证明）。

**验证**：headless 与 headed 各起一个 Profile，六项 + cd/pd/dpr 与配置逐字相等；`matchMedia('(resolution: Xdppx)')` 与 dpr 一致；`matchMedia('(min-resolution: …)')` 一致；`outer-inner == 121`（本引擎）；两个 Profile 的 f 不同；orientation 与宽高一致。

### 2.2 修复 measureText 乘性缺陷

**问题**：引擎把每个 `TextMetrics` 指标乘以 seed 常数 `k`（±5e-6）而不是 `1 + k`；真实宽度 563 px 变成 -0.00105（`report_raw*.json`；`IdentityShim.swift:48-55` 的因子推导）。Stripe 与所有字体探测因此失效，只能靠页面 shim 除以因子。

**改动**：在 `CanvasRenderingContext2D::measureText` 与 `OffscreenCanvasRenderingContext2D` 的同一实现（`canvas_rendering_context_2d.cc`/`offscreen_canvas_rendering_context_2d.cc`；共享 `TextMetrics` 构造）里，把指标乘数从 `k` 改为 `1 + k`。`k` 在 document 初始化时用现有 `clientrects_noise_x` 派生一次并放进配置。保留 `clientRects` 原语义。

**含义**：修完后主线程/Worker/iframe 的真实宽度回归，字体位串才可能被引擎自己算对；这也是能下线 IdentityShim 的唯一条件。

**验证**：`measureText` 主线程/Worker/iframe 三者相等且 >100；seed 22223 的真实宽度回落到 337.4765625 附近（`IdentityShimTests.swift:27-29` 的换算基准）；100.3 px 元素 clientRect 仍 `100.296875`（`out/report_ggrect.json`）；12 个 getter 与 `Object.keys(TextMetrics.prototype)` 不变。

**回退**：capability `measureTextFixed` 由运行时探针（宽度 >100）确认，否则 shim 继续挂载。

### 2.3 平台字体表与 55 位向量

**改动**：

- 扩展 `--fingerprint-font-profile=<macos26|macos15|windows11|windows10|linux68>` 与 `--fingerprint-font-variant=<0|1>`。
- `third_party/blink/renderer/platform/fonts/font_cache.cc` 的 `GetFontPlatformData`（二进制 `0xA127F00–0xA1332D8`，gate `0xA127FD4`/`0xA12806C`；平台表 macOS `0xA129B68`、Windows `0xA128AC4`、Linux `0xA1329C0`）。只在 `--fingerprint` 生效、capability `fontProfiles` 成立、**未 `--disable-spoofing=font`** 且 profile/variant 命中时查表（App 侧负责保证 `.font` 在 capability 下必开且不从 disabled 列表出现，§3.2）：
  - 表项 `{family, bit, fallback, widthScale}`；
  - `bit=0` → 返回 generic `monospace` 的 platform data（宽度等于基线）；
  - `bit=1` → 返回表中 `fallback` 的真实 face；
  - 表外字体 → 现状回退。
- `canvas_rendering_context_2d.cc` 的 measureText：对 bit=1 的 family 再乘 `1 + widthScale`（0.4%–3%，非 0，按 family 固定）；对 bit=0 和 generic 不乘；结果按 `FontDescription+family` 缓存。
- `third_party/blink/renderer/core/css/font_face_set.cc` 的 `FontFaceSet::check`：表内 family 按 bit 返回，表外回退宿主。
- **不要修** Stripe 的 comparator bug：源码比较的是 `"monospace"` 而类别是 `mono/sans/serif/...`，因此 55 项**全部**以 `monospace` 为基准（`mod-18.js:154`；`beautified.js:3677`）。名字顺序严格按 `beautified.js:3508-3617`。

**向量来源**：

- macOS：以真实 Chrome（同主版本）在「干净 macOS」与「Office 已装」两类参考机上抓 55 位串；本机现有向量 `1000111100000000100110111100000000000011001000010111111`（23/55，`/tmp/stripe-recon/font-off.json`；Chrome 158 nofont 探针相同）。
- Windows：真实 Win11/Win10 参考机各两份；核心 Windows 字体必为 1，macOS 专属必为 0，Office 字体只在 office 变体为 1。
- Linux：Ubuntu 24.04 干净与安装常用字体两份。
- 每平台至少两个变体；同 Profile 生命周期固定，不按请求翻转。

**含义**：j 是「假 Windows」的最硬证据；macOS 变体给不同 Profile 增加区分度。

**验证**：每个平台每个变体 55 位串与 golden 逐位相等；Windows Segoe UI(46)/Calibri(11) 恒 1；macOS 无 Segoe；`document.fonts.check('72px "Segoe UI"')` 与 bit 一致；同 Profile 三次加载同串，不同 seed 允许不同；无 `"unavailable"`。

### 2.4 UA-CH 默认品牌

**问题**：不传 `--fingerprint-brand` 时 UA 仍是 `Chrome/148.0.0.0`，UA-CH 只有 `Not/A)Brand;v=99` + `Chromium;v=148`，**没有 Google Chrome**（`report_headwin.json`、`headmac.json`）。真实 Chrome 必有。

**改动**：`components/embedder_support/user_agent_utils.cc` 在 `--fingerprint` 生效且无 `--fingerprint-brand` 时默认 `Google Chrome`；`fullVersionList` 含 `Google Chrome` + 现有 seed 版本表（`0xE758CD0` 的 `148.0.7778.{97,168,179,217}`）；GREASE 保持 `Not/A)Brand;v=99`（148 真机一致，`engine.md` §4）；顺序对齐同版本真实 Chrome 的采集样本。App 侧同时在 `brand==nil && platform!=nil` 时补 `--fingerprint-brand=Chrome`，做双保险。

**含义**：品牌缺失是「不是普通 Chrome」的第一眼证据；UA 与 CH 同源是硬约束。**服务端先看请求头再看 JS**：引擎默认 `sec-ch-ua` 只有 `"Not/A)Brand";v="99", "Chromium";v="148"`（本地回显 `/tmp/stripe-plan-v2/out/hdr_echo2.txt`），真实 Chrome 该头必含 `Google Chrome`；Edge 的回显则是 `"Chromium";v="148", "Microsoft Edge";v="148"`（`out/hdr_echo.txt`），同样不含 Google Chrome。只在 JS 侧修而 header 不修，P6 之前每条 `/6` 都在服务端裸奔。

**验证**（三层，缺一不可）：

1. JS：UA-CH brands 含 Google Chrome，`fullVersionList` 主版本 == 148；UA 仍是 reduced。
2. 请求头：`Network.requestWillBeSent` 捕获的 `sec-ch-ua` 含 `Google Chrome` 且与 `navigator.userAgentData.brands` 同源；`sec-ch-ua-platform` 与 platform 一致；`sec-ch-ua-mobile: ?0`。C004 同时查 JS 与 headers（§8.4）。
3. 品牌分支：Edge 不发 Google Chrome，只要求 `Microsoft Edge` 与 `Edg/` 同源；其余品牌按各自真机样本，不套 Chrome 期望（C004 按 `brand` 分支）。

### 2.5 deviceMemory 与 touch

**改动**：

- `third_party/blink/renderer/modules/device_memory/navigator_device_memory.cc`：`--fingerprint-device-memory=8|16|32` 优先；缺省保持 `[8,16,32][seed%3]`（`engine.md` §5）。
- `third_party/blink/renderer/core/frame/navigator.cc` 与事件注册：`--fingerprint-touch=0` 时不暴露 `ontouchstart`，`maxTouchPoints=0`；为 1 时暴露并返回 `--fingerprint-max-touch-points`（1–10）；`navigator.userAgentData.mobile=false` 不变。

**含义**：内存必须与 GPU 机型集合相容，否则 FPJS/3DS 的硬件交叉会红。

**验证**：显式值逐字返回；落点在 GPU 集合；touch=false 时 `ontouchstart` 不存在、maxTouchPoints=0；touch=true 时成对。

### 2.6 canvas 稳定性与 emoji

**改动**：保持现有 seed 噪声实现；确认噪声作用在最终像素（含 😃 彩色字形），不是绘制前文本；`--disable-spoofing=canvas` 仍回退宿主；同一 document 两次 `toDataURL` 逐字节相同。

**含义**：o 必须随 Profile 变且稳定；不稳定会让 id 抖动。

**验证**：两次 toDataURL 相同；不同 seed 不同；emoji 区域像素参与差异；`--disable-spoofing=canvas` 时同 seed 相同、异 seed 也相同（与 `report_cvoff*` 一致）。

### 2.7 构建、签名、发布

- 保持上游 `is_official_build`、ARM64；产物 `ungoogled-chromium_148.0.7778.300-anybrowser.1_macos.dmg`；Chromium.app 与 framework 的 `CFBundleShortVersionString` 都写 `148.0.7778.300`（不带 `-anybrowser.1`，后缀只进文件名），`BrowserEngine.version` 才能读到 capability 门槛。
- 发布前：全量探针 → golden diff → 签名 → sha256 → `versions.env`。
- `scripts/check-updates.sh:42` 改为盯 fork release，同时保留 Chrome stable 落后告警；新增 `scripts/engine-probe.sh`。
- 升级 runbook：`git rebase --onto <new tag>` → 重跑探针 → 与官方同版本 Chrome diff keys/plugins/UA-CH/GREASE → 重 bless → 全量回归。

### 2.8 3PC：不进引擎

`profile.cookie_controls_mode` 在 `Default/Preferences` 中预置即可（§6.5），比新增引擎开关少 250 行和一条升级面。只有在引擎升级后 pref 失效时才回退到引擎 patch。

### 2.9 FPJS Pro（wanderlust）第二采集面的硬化

`acs3ds.md:56-70,184-188` 已证：Link 特性下 v3 触发 `stripe-init-wanderlust`，加载 FPJS Pro 3.12.17，`sealedResult` 以 `linkedId = stripeJsId` 绑定；采集面包括 WebGL vendor/renderer/参数、AudioContext/OfflineAudio、canvas 两次读数稳定性、plugins、languages、colorDepth、deviceMemory、hardwareConcurrency、screen 边框帧、outer/inner 帧、Math/error stack、WebRTC。它在 `m.stripe.network` 之外，且帧跨域。

硬化目标不是「像真机」（字体字形、语音列表、Local Font Access 仍宿主），而是**同一 Profile 内跨帧一致、两个 Profile 间按 seed 分离**：

| 字段 | 依托 | 验收 |
|---|---|---|
| WebGL vendor/renderer/参数 | 现有 GPU seed 表 | 两个 seed 的 renderer 不同、同 seed 跨帧相同 |
| AudioContext/OfflineAudio | `.audio`（sample 已默认加） | 同 seed 两次相同、异 seed 不同 |
| hardwareConcurrency / deviceMemory | cpuCount 与 §2.5 的 memory 开关，二者绑同一 GPU 机型 | 落到同一机型集合，跨帧一致 |
| screen 帧（outer/inner、边框、`screenX/Y`） | §2.1 屏幕补丁 + §3.6 派生窗口 | 内帧与外帧相等；`screenX+outerW ≤ screen.width`（`window-screen-consistency`） |
| canvas 两读稳定性 | §2.6 | 两次 `toDataURL` 相同 |
| plugins/languages/colorDepth/touch | 已有原生面 | 与 a.e/c/f/g/h 同值 |

跨域帧只有两条路：引擎在读取点生效（首选），以及内容脚本 `all_frames`（只用于 SS 屏障与临时 ScreenShim）。`enumerateDevices`、`pdfViewerEnabled`、`matchMedia('(prefers-*)')` 作为观测项进 §8.10，不做伪造声明。

---

## 3. 配置模型与预设

### 3.1 模型

`FingerprintSettings`（`Profile.swift:85-113`）新增：

```swift
public var availTop: Int? = nil
public var availLeft: Int? = nil
public var pixelDepth: Int? = nil
public var fontVariant: Int? = nil          // 0|1
public var maxTouchPoints: Int? = nil
public var thirdPartyCookies: Bool? = nil   // nil = allow（mode 0）
```

`FingerprintAdjustment`（`Profile.swift:53-66`）增加 `screen` case（标题「屏幕」，所有平台可校验），参与 `arguments()` 的反向 `--disable-spoofing` 拼接：

- capability.screen=true 时从 `adjustments` 移除 `.screen`（改由内核读点）；
- capability.screen=false 且 platform 非 nil 且 `screenShimEnabled` 时加入 `.screen`（页面兜底）；
- platform=nil 时移除。

`BrowserProfile` 新增：

```swift
public var deviceIdentity: String? = nil     // 36 位小写 uuid4；nil 时按 seed 确定性派生
```

`FingerprintField` 增加 `screen, deviceMemory, touch, fontProfile, fontVariant, maxTouchPoints, thirdPartyCookies`。

`FingerprintSettings.init(from:)`（`:118-141`）全部 `decodeIfPresent`；`BrowserProfile.init(from:)`（`:194-212`）同样。旧 JSON 解码结果不变（以 `StoreTests.swift:85-95` 的 payload 为回归）。

### 3.2 校验（`Profile.swift:439-472`）

| 字段 | 规则 |
|---|---|
| screenWidth/Height | 480–7680 |
| availWidth/Height | 320–7680 |
| availWidth | ≤ screenWidth |
| availHeight + availTop | ≤ screenHeight |
| availTop/availLeft | 0–200 |
| colorDepth/pixelDepth | 24 或 30；sampler 选 24 |
| dpr | macOS {1,2}；Windows {1,1.25,1.5}；Linux {1} |
| deviceMemory | 8/16/32；显式时必须在 `EngineHardwareTable` 的对应 GPU 集合内 |
| touch/maxTouchPoints | false→0；true→1–10 |
| fontProfile | 必须与 platform 一致；capability.fontProfiles 时必须非 nil 且 `adjustments.contains(.font)`；capability=false 时 fontProfile 可留作展示但 `.font` 必须缺席 |
| fontVariant | 0–1 |
| screen/font | platform 为 nil 时不得填写；platform 非 nil 且 capability.screenMetrics 时必须填写 screen 六字段 + cd/pd/dpr |
| adjustments | `.screen` 与 capability/平台一致（§3.1）；`.font`：capability.fontProfiles 时必须与 fontProfile 同时成立，capability=false 时必须缺席 |
| deviceIdentity | `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` |
| thirdPartyCookies | 无额外校验（nil=allow） |

`adaptToPlatform()`（`:589-612`）与 `randomize()`（`:495-579`）的修正：

- **字体改写项强制**：`sample`（`IdentitySampler.swift:159-191`）、`identityBundle`、`adaptToPlatform`、`randomize` 在 `platform != nil && capability.fontProfiles` 时 `adjustments.insert(.font)`（当前 `sample` 只补 `.audio`、preset 只补 `.gpu`、`randomize` 只保留已有 `.font`，整条字体链在默认 Profile 上是死的）；capability=false 时移除 `.font`。`arguments()` 的 disabled 列表因此不再含 `font`。
- `deviceMemory` 平时保留显式值，不再被 seed 派生值覆盖（现 `:602-604`、`:578` 是无条件覆盖）。
- 平台变更、seed 变更（`randomize(.seed)`）时，从新 seed 的 GPU 机型内存集合重抽 memory；平台变更同时清空 screen/font/variant/maxTouchPoints 并按 §3.1 收紧 `.screen`。
- `randomize` 抽 screen/font/memory 时走 §3.3/§3.4 的目录，并保持 GPU 相容；memory 从 `gpu.deviceMemory.randomElement()` 取，不用全局 `[8,16,32]`。

`brand==nil && platform != nil`：`arguments()` 自动补 `--fingerprint-brand=Chrome`；`SelfCheck` 的 nil 品牌期望改为「必须含 Google Chrome」（现 `SelfCheck.swift:236` 的 `!brands.contains("Google Chrome")` 要反过来）。

期望源统一：`SelfCheck.swift:263-267` 的 device-memory、`FingerprintConsistency.swift:123-141` 的 `hardware-impossible`、`FingerprintCard` 的摘要都必须优先 `fingerprint.deviceMemory`，只有 nil 时才回退 seed 派生值，否则显式值会被 seed 值误报。SelfCheck 的 `Screen` 观察结构补 `availTop/availLeft/pixelDepth`，屏幕项逐六字段 + cd/pd/dpr 比较，capability=false 时整项为 info。

### 3.3 屏幕目录（修正 draft-1 的 30bit 与旧文档的 availTop 25）

`availTop` 是菜单栏/任务栏占位：macOS 30，Windows/Linux 0；`availHeight = height - 30`（macOS）或 `- 48`（Win/Linux 任务栏）；`availLeft=0`；cd=pd=24。

| 平台 | width×height | availWidth×availHeight | availTop | dpr | 权重 |
|---|---|---|---|---|---|
| macOS | 1728×1117 | 1728×1087 | 30 | 2 | 40 |
| macOS | 1512×982 | 1512×952 | 30 | 2 | 30 |
| macOS | 2560×1440 | 2560×1410 | 30 | 2 | 20 |
| macOS | 1440×900 | 1440×870 | 30 | 1 | 10 |
| Windows | 1920×1080 | 1920×1032 | 0 | 1 | 45 |
| Windows | 1536×864 | 1536×816 | 0 | 1.25 | 20 |
| Windows | 1366×768 | 1366×720 | 0 | 1 | 15 |
| Windows | 2560×1440 | 2560×1392 | 0 | 1 | 20 |
| Linux | 1920×1080 | 1920×1032 | 0 | 1 | 60 |
| Linux | 1366×768 | 1366×720 | 0 | 1 | 20 |
| Linux | 2560×1440 | 2560×1392 | 0 | 1 | 20 |

宿主 `CGDisplayBounds`（点，CSS px）作为上限：目录值大于宿主时整项跳过；不把 2560×1440 当唯一上限。多显示器时以主屏为准。

### 3.4 字体 profile 与 variant

- `fontProfile(for:platform:)` 每平台两组（macOS `macos26/15`，Windows `windows11/10`，Linux `linux68`），由 preset 的平台与版本选择；variant 0/1 由 seed 奇偶或 hash 选择。
- macOS clean 变体：核心字体位恒 1，Office 字体位 0；office 变体：参考机实际向量。Windows/Linux 同法。
- profile/variant 一旦写入，生命周期内固定。

### 3.5 预设

- 默认预设只留 macOS（`defaultPresetIDs` 已是，`IdentitySampler.swift:126`）。
- Windows/Linux preset 在 capability true 前保持 `isExperimental`；`IdentityPresets.apply`（`:20-33`）只在 capability 后不再写实验标记。
- `brandVersion` 保持空，由引擎 seed 选已发布 build；`brand` 永不 nil（preset 与 adapt 双重保证）。

### 3.6 窗口派生

新增 `WindowLayout.derived(from:hostBounds:) -> WindowLayout?`（`LaunchOptions.swift:4-14` 的模型）。三个比例用 `sha256(seed|"window"|n)` 取模归一化，不使用 `Int.random`，保证同 seed 同窗口：

```
innerW = clamp(round(availW * rand(0.60…0.78)), 900, min(availW, hostW))
upperH = max(599, min(availH, hostH) - 121)
innerH = min(clamp(round(availH * rand(0.70…0.85)), 599, upperH), upperH)
outerW = innerW; outerH = innerH + 121        // 121 = 本引擎 outer-inner（report_winA/winC）
x = availLeft + hash % max(1, availW - outerW)
y = availTop + hash2 % max(1, availH - innerH)
```

- `LaunchOptions.deriveWindowFromScreen: Bool = true`（新字段，decodeIfPresent 默认 true）。
- 用户显式窗口时 `deriveWindowFromScreen=false`，一致性检查只警告越界。
- `screenMetrics=false` 时不派生，保持旧行为；`screenMetrics=true`（内核或 shim）时派生，判定源与 `ScreenShim` 相同，注释写清 native/shim 两层。

**分屏/平铺必须用同一块伪屏**：`WindowArrangement` 现在按 `NSScreen.visibleFrame` 算格并不设上限（`WindowArrangement.swift:30-74`），宿主 2560 宽单窗格会把窗口撑到 2560，而伪造屏是 1728（`innerWidth > screen.width`、`screenX` 越出、`challengeWindowSize` 档位漂移）。改为：

- `screenMetrics=true` 时以 Profile 的伪造屏幕（按 §3.3 目录取 width/height/availTop）为 `area`，格宽上限为 `screen.width`，行高上限为 `availHeight`；
- capability 未开（`screenMetrics=false`）但已有派生窗口时，至少把格 clamp 到「派生窗口与宿主 visibleFrame 的并集」；
- 平铺后追加 `window-screen-consistency` 检查（§5）。

`--window-size` 取 outer，`--window-position` 取 x/y；headless 也传，由 §2.1 的 headless patch 消费。
- 小屏（1366×768）窗口宽 900、innerH 取 599、outerH 720，恰好等于 availH；公式里的 599 与 `upperH` 保证不会倒挂。

### 3.7 capability 与迁移

`EngineCapabilities`：

```swift
struct EngineCapabilities {
    let screen, measureTextFixed, fontProfiles, deviceMemorySwitch, touchSwitch, uaChChromeDefault: Bool
    /// 只在 capability.screen=false 时有意义：shim 已安装且未过期
    /// （安装时间与版本记在 storage/screen-shim-<sha>.json；过期或引擎换了即 false 并重装）。
    let screenShimEnabled: Bool
    /// 两层：native `screen` 优先，否则 shim。唯一决定是否填写/派生/比较屏幕字段与窗口的判据。
    var screenMetrics: Bool { screen || screenShimEnabled }
}
```

`screenShimEnabled` 的赋值在 capability 加载处完成（`screen=false` 且 shim 已安装、未过期 → true；`screen=true` → false 且卸下）；`.screen` 改写项与它同步（§3.1）。窗口派生、`ScreenShim` 安装、`SelfCheck` 屏幕项、C001/C014 全部只看 `screenMetrics`。

- 版本门（§2.0）+ 首次启动探针（headless 起一个 1234×777@2 的页面，读 screen/matchMedia/measureText/fonts.check/deviceMemory/touch）。结果按引擎 sha256 缓存到 `storage/capability-<sha>.json`（0600），同一引擎只跑一次；探针失败的功能降级为 false，记录 `capability-probe-failed`。
- `IdentitySampler.screenSpoofingSupported`（`:131`）改为 `capabilities.screenMetrics`（原生或 shim）；`:166-176` 全部字段在 `screenMetrics` 为 true 时填写。`fontProfile` 继续作为展示值存在，但只有 `capabilities.fontProfiles` 时才 `adjustments.insert(.font)`（§3.2）。
- 迁移：`LaunchCoordinator.launch` 在拿到 profile 后，若 `screenMetrics`/`fontProfiles` 且 platform 非 nil，用 seed 补齐缺失的 screen/font/variant/memory/窗口，`fontProfiles` 时 `adjustments.insert(.font)`，然后 `store.save`；读只读库时只在本进程内存里补，并告警。保证 `launchArguments` 与 `matchesRunningConfiguration` 同源（`BrowserRuntime.swift:224-238`、`:535-540`）。

### 3.8 启动参数

`FingerprintSettings.arguments()`（`:353-402`）在现有 screen/dpr 三行后补齐：

```
--fingerprint-screen-avail-width / -height / -avail-top / -avail-left
--fingerprint-color-depth / --fingerprint-pixel-depth
--fingerprint-font-profile / --fingerprint-font-variant
--fingerprint-device-memory
--fingerprint-touch=0|1 / --fingerprint-max-touch-points
```

顺序固定，`StripeConfigurationTests` 逐项断言。`thirdPartyCookies` 不进参数（§6.5）。`--disable-spoofing` 的 disabled 列表继续由 `adjustments` 反向派生（`Profile.swift:387-391`），因此 `.font`/`.screen` 的开启状态会直接反映到参数与 `font-spoof-disabled` 规则上。

### 3.9 capability 关闭期间的临时 ScreenShim

fork 未落地前，屏幕不能等：在 `IdentityGuard` 里附带常量 getter（仅在 `capability.screen == false`、`screenShimEnabled == true` 且 platform 非 nil 时写入 content.js）：

- `document_start`、`all_frames`、`MAIN` world；
- `Object.defineProperty(Screen.prototype, 'width'|'height'|'availWidth'|'availHeight'|'availLeft'|'availTop'|'colorDepth'|'pixelDepth', {get:()=>常量, enumerable:原, configurable:true})`；
- `Object.defineProperty(window, 'devicePixelRatio', {get:()=>常量, configurable:true})`；
- 不新增 navigator/document 键；实测装 shim 后 `Object.keys` 仍是 `["location"]/[]`（`work2/object-keys-shim.txt`），跨源 iframe 生效（`work2/screen-shim-iframe.txt`）。
- 安装时写 `storage/screen-shim-<sha>.json`（安装时间、版本）；同一引擎过期（默认 7 天、或引擎 sha 变化）即重装并重新标记；capability.screen=true 时卸载并把 `.screen` 从 adjustments 移除。

已知缺口，必须由规则标注而不是假装通过：

- `matchMedia('(resolution:2dppx)')` 仍按宿主 DPR 返回（`work2/screen-shim-dpr-media.txt`），`screen-shim-media` 记 warn；
- getter 的 `toString` 非 native，`screen-shim-native` 记 info；
- `ScreenOrientation` 未覆盖，按横屏常量与 width>=height 自洽即可；
- capability.screen=true 后不再安装该分支。

验证：两个 Profile 的 `a.f` 不同且符合 `^\d+w_\d+h_(24|30)d_(1|2|3)r$`，跨源 iframe 同值，`b.i/j` 不变；`SelfCheck` 的屏幕项在 shim 下可 pass，`matchMedia` 项 info/warn。

---

## 4. 新设备身份再生时序

### 4.1 身份模型（四层，一起变才叫新设备）

| 层 | 内容 | 再生点 |
|---|---|---|
| L1 目录 | 独立 `--user-data-dir` | 新 Profile（`Profile.swift:177`、`BrowserRuntime.swift:175`） |
| L2 指纹包 | seed、平台、brand、CPU、locale、screen、font、memory、canvas | makeDraft/clone/import/regenerate 的同一个 `identityBundle` |
| L3 Stripe muid | `deviceIdentity`（36 uuid4）→ 预置 `__stripe_mid`；sid 独立新 uuid4 | 新身份生成时派生/采纳 |
| L4 服务端锚点 | `.m.stripe.com` 的 `m` | 整库删除 |

只换 L2 不清 L3 = 同设备换指纹；只清 L3 不换 L2 = 旧设备清存储；两者同时且 L3 全新 = 新设备。

### 4.2 确定性 UUID

```swift
enum DeviceIdentity {
    static func derived(seed: Int, platform: BrowserPlatform?) -> String {
        // sha256("anybrowser.stripe.mid.v1|\(seed)|\(platform?.rawValue ?? "host")")
        // 取前 16 字节，b[6]=(b[6]&0x0F)|0x40，b[8]=(b[8]&0x3F)|0x80，格式化成 36 位小写
    }
    static func effective(_ profile: BrowserProfile) -> String
        { profile.deviceIdentity ?? derived(seed: profile.fingerprint.seed, platform: profile.fingerprint.platform) }
}
```

- 确定性保证：即使库只读、`store.save` 失败、或进程被杀，同一 seed 始终同一 mid。
- **重新生成必须清旧值**：`ProfileStore.regenerateIdentity`（`:278-287`）只复制 profile 再换 fingerprint，`LaunchCoordinator.generateIdentity` 也只返回 fingerprint；不显式清 `deviceIdentity`，旧值会穿透“新 seed + pending reset + 清 jar”的主流程并把自己的旧 muid 写成新设备首报。因此 regenerateIdentity 里 `value.deviceIdentity = nil`，`AutomationAPI.update` 改 seed 时同样清，`saveNewIdentity` 断言 draft 的 deviceIdentity 为 nil。identityBundle 清单补 `regenerateIdentity`（§6.6）。
- 用户只手动改 seed（非 regenerate）：cookie 仍存在 → 采纳旧 mid 是正确语义；要换身份必须走「整套重新生成」。
- 导入/克隆一律换新 seed，派生值随之变化；备份恢复保留 seed 与 deviceIdentity。
- `deviceIdentity` 目前由 seed 派生，seed 由库保证唯一；为防将来放开“同 seed 多 Profile”，`checkForConflicts` 一并检查 `deviceIdentity`（`ProfileStore.swift:698`），重复即拒。

### 4.3 启动前（持锁、进程未起）

`BrowserRuntime.start`（`:245-370`）的既有顺序不改，插入两点：

```
lock → PrivateDirectory.ensure(directory)                 (:257)
→ PasskeyBox/IdentityGuard prepare                        (:280-284)
→ 若 resetSiteData：removeSiteData（含 Sessions）          (:286-289)
→ ThirdPartyCookiePosture.apply(mode, directory)          （新，:289 后）
→ spawn                                                    (:306-320)
→ verifiedEndpoint                                         (:341)
→ StripeIdentitySeeder.seed(...)                          （新，:341 后）
→ openStartPages                                           (:344-347)
```

- `removeSiteData` 只走停态整库删除；运行中调用返回错误（`:264-266`），与现有语义一致。
- 3PC pref 写在 `removeSiteData` 之后，避免被任何清理覆盖；Preferences 本身不在 `siteDataPaths`（`BrowserRuntime+Data.swift:320-329`）。
- 若引擎 sha 或 `fontProfiles` 与上次记录不同，进入本函数时置一次 pending reset（§4.6），让 `id/_mf/_ab` 随同清掉。
- 迁移补齐（§3.7）与身份派生都在 spawn 前完成。

### 4.4 启动中（端点就绪、首访前）

`StripeIdentitySeeder`（新，`Sources/AnyBrowserCore/StripeIdentitySeeder.swift`）：

0. **host 来源**：`startURLs` 的 http(s) 主机（≤20）。但 `LaunchOptions.startURLs` 默认 `[]`（`LaunchOptions.swift:23,34`），`BrowserRuntime.start` 在空 URL 时连 `openStartPages` 都不调（`BrowserRuntime.swift:344-347`）——默认路径 seeder 没机会跑。两条都做：Stripe 用途的新 Profile 由 makeDraft/batch/自动化默认填一个 Stripe 入口 URL（`https://app.link.com`，用户商家域可换），UI 在 startURLs 为空时提示「要预置身份需填启动网址」；同时加规则 `identity-no-start-url`（空 startURLs → info，不阻断，退化为 NA-first）。P2 内评估首帧前导航钩子（`Target.setAutoAttach` 后、首帧前注入）作为不依赖 startURLs 的备选。
1. 按 host 生成 domain：普通域名用 `.<host>`；IP 主机用 host 本身（写失败时回退 `.<host>` 再回读）。
2. `Storage.getCookies` 读 jar，按 host 过滤。
3. **采纳（从严）**：只认 36 位小写 v4 uuid（`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`）与「与最近一次 `/6` 响应回显的 muid 逐字相同的 42」（响应值由上一轮启动的 CDP 记录持久化为 `lastResponseMuid`）。jar 里的 42 若长度/下划线合法但 version 不是 4、variant 不是 8/9/a/b、后缀非小写，或与 `lastResponseMuid` 不同，**一律覆盖为 36**（服务端对这些都会换新，而客户端 `mt` 只要长度 42 就永远优先旧值，`v3:25500-25506`，不覆盖会永久分叉）。采纳的 36 前缀与 `deviceIdentity` 不同时放入 `discoveredIdentity` 由调用方持久化；36 与派生值相同则不重写 cookie。
4. **写入**：mid 缺失/非法/按上条被拒时写 `effective(profile)`；sid 缺失/非法时写新 uuid4。属性与 v3 完全对齐（`v3:24691-24712`、`:25695-25723`）：普通域 `domain=".<host>"`、path="/"、`https` 才 `secure`、`httpOnly=false`、`sameSite="Strict"`、mid 365 d（v3 默认 `31536e6` ms）、sid 1800 s（`18e5` ms）。
5. `Storage.setCookies` 后 `Storage.getCookies` 回读；不一致重试一次；仍失败记录 warning，不阻断（NA-first 仍正确）。
6. 返回 `discoveredIdentity`；`LaunchOutcome` 透传，`LaunchCoordinator` 在启动成功后 `store.setDeviceIdentity`。

实测支撑：只写不回读时首个请求可能不带 cookie，回读后带（`work2/seed-before-navigation.txt` 的 `HEADERS-one COOKIE`）；裸 36 uuid 被服务端补 6 位校验和并回显（`work2/checksum-uuid-1.body`/`-2.body` 同 uuid 同后缀 `683ce0`），预置值被 v3 采用并写回 42（`work2/seed-adopted.txt`）；随意 42 会被换新（`work2/checksum-nonuuid.body`）。

**顺序不可交换**：只写不带、后写被首帧抢跑、写入晚于导航，都是「首访 NA 且无种子」的失败形态。

### 4.5 首访与验收时序

- 首报 `b.d/b.e` 允许是 36（种子）或 NA（无种子/失败）。
- `/6` 200 后服务端回 42；v3 `mt` 优先已有 42（`v3:25500-25506`、`25692-25723`），把 42 写回 cookie。
- 观测窗结束（≥15 s）后断言 `__stripe_mid` 为 42 且前缀 == identity。**不要断言第二条 POST 为 42**：实测 3 条 POST 都在响应前（`live5-macos-on-747474.json`，t=9.35/10.034/10.515）。
- 需要第二条 42 报文时，用 `history.pushState` 触发一次 URL 变更 ping（`v2probe` 的 `inspect_ec.py` 已验证会产生新 POST）。

### 4.6 会话存储屏障

- `saveNewIdentity`（`LaunchCoordinator+Identity.swift:33-41`）同时把 `launch.restoreSession` 持久置 false，UI 提示「换新身份已关闭会话恢复」。
- coordinator 在 `pendingIdentityReset` 的启动路径把运行中的 `restoreSession` 覆盖为 false 并 save（此时 profile 已在手，不依赖 `validated`）。
- 扩展类型由 `IdentityShim` 更名为 `IdentityGuard`（磁盘目录仍叫 `IdentityShim`，避免旧 Profile 迁移）：`prepare(..., freshIdentity:)` 把 `__FRESH__` 写进 content.js；脚本在 `document_start` 且 `location.hostname === "m.stripe.network"` 时 `sessionStorage.removeItem` `id`、`_mf`、`_ab`，`try/catch` 包裹，不加全局。
- `freshIdentity = overrides.resetSiteData || engineChanged`（coordinator 已把 `pendingIdentityReset` 映射为 `resetSiteData=true`，`LaunchCoordinator.swift:211-215`；engineChanged 来自 §4.3 的 sha/capability 比较）。
- `siteDataPaths` 增 `Default/Sessions`（会话文件是 restore 的源头；`work2/session-restore-iframe.txt` 证明删 Session Storage 目录不够）。
- 即使 restore 被意外打开、崩溃续跑或手工重开，屏障也保证首个采集不带旧字体位串/不抑制全量 a。
- **引擎/字体能力变化也视同 fresh**：SS 屏障脚本先读 `schema` 键（`<engineSha>:<fontCapability>`）；版本不符就删 `id`、`_mf`、`_ab` 再写新 schema。字体表从无到有是引擎升级而不是 fresh，旧 `_mf` 会让首 ping 的 `a` 为 null、服务端继续拿旧位串 id，而 `document.fonts.check` 已按新表返回，页面内自相矛盾。运行时若探测到 engine sha 或 `fontProfiles` 变化，置一次 `pendingIdentityReset`。规则 `session-cache-stale`。
- m 的线上 Set-Cookie 是 2 年，Chrome 存储时截到 400 天（`v2probe/logs/m_attr_engine_mode0.txt` 的 expires 差 ≈399.98 天）；正文统一按“目标 ≤400 天、约 400 天”验收。

### 4.7 特殊路径

| 情形 | 标记 | 行为 |
|---|---|---|
| `restoreSession=true` 的普通启动 | `restore` | 预置可能晚于首帧；warning；首报允许 NA |
| URL 带 `__checkout.mids` | `pinned` | v3 不读写 cookie（`v3:25526-25536`）；接受 payload mids，跳过 I003/I004 |
| v3 URL 带 `_1776170249=false` | `no-persist` | 不建帧、不持久化、每次 36 随机（`v3:24720-24746`、`25529`）；seeder 跳过该 host；跳过身份断言 |
| 启动 host 是 IP | `ip-host` | domain 先写 host 本身，回读失败改 `.<host>` |
| 浏览器运行中 | `running` | 只标记 pending，下次启动生效；不让开放页面写回旧值 |
| `startURLs` 为空 | `no-start-url` | seeder 不跑；info；NA-first；UI 提示补 URL |
| jar 内有非法/未验证 42 | `bad-42` | 覆盖为 36；warning；见 §4.4 第 3 步 |

### 4.8 运行中重新生成

保持现有语义：`saveNewIdentity` 只保存与标记；`clearPendingSiteData` 在 stopped 时立即清，running 时等重启（`LaunchCoordinator.swift:211-226`）。UI 明确「下次启动生效」。

---

## 5. 一致性规则

`FingerprintConsistency`（`:152-180`）与 SelfCheck 增加；`ConsistencyContext` 增加 `capabilities`、`keysBaseline`、`posture`。

| ID | 严重度 | 条件 | 文案 / 含义 |
|---|---|---|---|
| `screen-unspoofed` | warn | `screenMetrics=false` 且 platform 非 nil | 当前引擎不读屏幕开关，所有 Profile 同屏 |
| `screen-platform-mismatch` | fail | Win/Linux dpr∉允许集或 cd≠24；macOS dpr∉{1,2} | 屏幕与平台不符 |
| `screen-geometry` | fail | availWidth>width、availHeight+availTop>height、top/left 越界、窗口大于 avail | 几何不自洽 |
| `screen-follow` | warn | `screenMetrics=true` 但 screen 字段缺失 | 未生成本机屏幕 |
| `screen-shim` | info | capability.screen=false 且 ScreenShim 生效 | 页面级 getter，非 native |
| `screen-shim-media` | warn | shim 下 `matchMedia(resolution)` 与 dpr 不一致 | 已知缺口，等引擎 |
| `screen-shim-native` | info | ScreenShim 生效 | getter `toString` 非 native |
| `font-profile-missing` | fail | capability.fontProfiles=true 且 fontProfile=nil | 未选字体表 |
| `font-spoof-disabled` | fail | capability.fontProfiles=true 且（fontProfile 非 nil）且 `--disable-spoofing` 含 `font`（或 adjustments 缺 `.font`） | 字体表整条链路不生效，j 仍是宿主位串 |
| `font-spoof-seed` | warn | capability.fontProfiles=false 且 Profile 仍带 `.font`（未迁移或导入的旧值） | 只是按 seed 增删宿主字体，不是字体表 |
| `device-memory-platform` | fail | 显式 memory 不在 GPU 集合 | 该机型无此内存 |
| `third-party-cookies-blocked` | warn | thirdPartyCookies=false | m 不落盘、guid 每条 POST 变 |
| `brand-nil` | fail | platform 非 nil 且 brand=nil | UA-CH 缺 Google Chrome |
| `brand-version-future` | fail | brandVersion 主版本 > 引擎主版本 + 2 | 版本穿越 |
| `keys-baseline-drift` | fail | keys 与 golden 不同 | 有 own enumerable key 被加 |
| `canvas-unstable` | fail | 同 Profile 两次 canvas md5 不同 | id 会抖动 |
| `stripe-cookie-imported` | warn | 导入的 jar 含 mid/sid/m/FPJS | 会变成同一设备 |
| `identity-missing` | fail | 首访前 mid 缺失且非 restore 且 startURLs 非空 | 会以 NA 首访 |
| `identity-no-start-url` | info | startURLs 为空且导航钩子未启用 | seeder 不跑，退化为 NA-first |
| `identity-derived-after-reset` | fail | pending-reset 启动后首报 mid 前缀 ≠ `derived(newSeed, platform)`，或 jar 里仍出现旧前缀 | 旧 muid 被原样带进“新身份” |
| `identity-churn` | fail | 同 Profile 非重置两次启动 mid 不同 | 采纳逻辑坏了 |
| `m-missing-allow` | fail | posture=allow 且响应后无 m | 3PC 没生效 |
| `m-present-block` | warn | posture=block 且有 m | 姿态与配置相反 |
| `session-restore-fresh` | warn | reset 启动且 restoreSession=true | 可能带旧 `_mf` |
| `stripe-session-cache` | fail | capability.measureTextFixed=true 且 **fresh 或引擎/字体能力变化后**首访前 SS 有 `_mf` | 旧字体串会被复用 |
| `session-cache-stale` | warn | SS 里 `schema` ≠ 当前 `<engineSha>:<fontCapability>` | 屏障没随引擎升级生效 |
| `clock-skew` | warn | 本机与 HTTP Date 差 >2 s | b.w 可复算失败 |
| `posture-unknown` | warn | Preferences 回读失败 | 3PC 姿态不可断言 |
| `exit-shared` | warn | 同一出口被其他 Profile 使用 | 关联度高（已有；发布门见 §10 最强风险） |
| `connection-exit-mismatch` | warn | `effectiveType`/`rtt` 与出口链路类型矛盾 | 网络层关联信号 |
| `window-screen-consistency` | fail | `outerW>screen.width`、`screenX+outerW>screen.width`、`innerW>screen.width` | 分屏后窗口与伪屏互相打脸 |
| `fpjs-visitor` | fail | 首访前三件套/`stripe.link.persistent_token` 任一仍在；或触发后新 visitor 的 `linkedId` ≠ 本次 stripeJsId | 旧 visitor 把新设备回收 |
| `time-zone`/`language` | warn | 与出口不符 | 已有 |
| `linux-webgl`/`webgpu-host-gpu`/`voices-host-os` | warn | 平台非 macOS | 已知宿主面（已有） |
| `checkout-pinned` | info | 入口带 mids | 不复用本 Profile 种子 |
| `he-disabled` | info | 入口 `_1776170249=false` | 无持久身份 |

规则只提示，不阻断保存/启动；SelfCheck 把 fail 显示为红，warn 显示黄，info 不显示成 pass。

---

## 6. 存储与 cookie 清理

### 6.1 必清对象

| 层 | 对象 | 现有覆盖 | 处理 |
|---|---|---|---|
| cookie | `m`@m.stripe.com/.stripe.com/checkout.stripe.com（HttpOnly） | `siteOrigins` + 域匹配（`BrowserRuntime+Data.swift:111-118,297-307`） | 保留；不要按名全域（m 太常见） |
| cookie | `__stripe_mid`/`__stripe_sid`@任意商家域 | `stripeDeviceCookies`（`:311`） | 保留并按名全域 |
| cookie | `__Secure-f-visitor-id`、`__fpjs_pvid`、`stripe.link.persistent_token`（FPJS/Link） | 未覆盖 | 名字表新增 |
| cookie | `machine_identifier`、`private_machine_identifier` [I] | 未覆盖 | 名字表新增（域匹配兜底） |
| cookie | `.stripe.com`/`checkout.stripe.com` 任意名 | 部分 | 域匹配 |
| sessionStorage | `m.stripe.network` 的 `id`/`_mf`/`_ab` | `Default/Session Storage` | 整删 + §4.6 屏障 |
| Storage | `link.auth_session_client_secret`（session）、`light_experiment_assignments` 等 Link 实验缓存 | 同上 | 整删 |
| 会话文件 | `Default/Sessions` | 未覆盖 | 新加入 `siteDataPaths` |
| 其它存储 | Local Storage/WebStorage/SharedStorage/Trust Tokens/MediaDeviceSalts/IDB/SW/Cache/Code Cache/GPUCache/databases/File System | `siteDataPaths`（`:320-329`） | 保留 |
| FPJS localStorage | `_vid`、`__fpjs_pvid`@`js.stripe.com` | 未覆盖（`js.stripe.com` 已在 siteOrigins 的 origin 删除内） | `siteOrigins` 加 `f.stripecdn.com`、`w.stripecdn.com`、`stripecdn.com` 覆盖 f 帧 |

`siteOrigins` 新增三条 stripecdn；`stripeDeviceCookies` 新增五个名字（含 `stripe.link.persistent_token`）。**不把 `m` 放进名字表。**

### 6.2 不清什么（以及「保留」的真实边界）

- **重置 = 全 cookie 清空，Link 登录也会没**：`removeSiteData` 删的是整份 `Default/Cookies` 与 `Default/Network/Cookies`（`BrowserRuntime+Data.swift:320-329`），不是按名过滤，`lsid@.link.com` 与无关域 `keep` 一起消失；运行态 DevTools 路径同样会因为 `siteOrigins` 含 `https://link.com` 而让 `.link.com` 被父域命中（`:111-118`）。现有测试自己就断言重置后 `cookieNames(...).isEmpty`（`CoordinatorEngineTests.swift:119,162`）。UI 与文档必须写「重置会登出 Link 和所有站点」。
- **可选 Link 保登录（默认关，产品确认后开）**：重置前只备份 `__Secure-sid`/`lsid`@`.link.com` 两个名字，清完写回并回读；其余照旧全删。开启时 §6.7 有对应断言；不开启时断言两者也被删。
- Preferences、History、Bookmarks、扩展的 chrome.storage/IndexedDB/CacheStorage（现有注释 `BrowserRuntime+Data.swift:9-13`）。
- 非 cookie 层没有“按名保留”：Local Storage/IndexedDB/Service Worker 是整库删；名字精确匹配只存在于可选的白名单路径。

### 6.3 状态与顺序

1. 必须 stopped：running 走 DevTools 时清不了 sessionStorage 且页面会写回（`BrowserRuntime+Data.swift:14-19`）。
2. 停态 `removeSiteData` 在目录锁内、spawn 前（`BrowserRuntime.swift:286-289`）。
3. 清完再写 3PC pref，再 spawn。
4. 失败保留 `pendingIdentityReset`，下次再试（`LaunchCoordinator+Identity.swift:43-65`）。
5. 运行态 DevTools 删除必须带完整 `partitionKey`（`:72-78`）。

### 6.4 导入/导出/备份语义

- `CookieTransfer.importCookies(_:into:stripeIdentity:)` 新增 `.drop|.keep`：
  - `.drop`：按名字删 mid/sid/machine_identifier/private_machine_identifier/`__Secure-f-visitor-id`/`__fpjs_pvid`/`stripe.link.persistent_token`，并按域删 m.stripe.com/.stripe.com/checkout.stripe.com 的任意名；不碰 `.link.com` 的其他 cookie（`__Secure-sid`/`lsid`）。
  - 手动 UI 导入默认 `.drop`，提供「保留 Stripe 身份（同设备迁移）」开关；摘要写丢弃条数。
- 备份 `ProfileBackup.restore` 传 `.keep`；restore 后若 profile 无 `deviceIdentity` 则按 §4.4 第 3 步从 mid 采纳（只认 36 或与最近响应一致的 42，其余下次启动覆盖）；seed 冲突被换时 warning。
- Profile JSON 导入无 cookie，只有 profile 字段；由 §6.6 的整套重采样覆盖。
- 导入/恢复后必须重写 3PC pref（headless 启动前，见 §6.5）。

### 6.5 3PC 姿态落盘

新增 `Sources/AnyBrowserCore/Stripe/ThirdPartyCookiePosture.swift`：

- `apply` 入口先 `PrivateDirectory.ensure(directory.appendingPathComponent("Default"))`：`PrivateDirectory.ensure(directory)` 只建根（`BrowserRuntime.swift:257`），新 Profile 还没有 `Default/`，直接写文件会失败。
- 读 `directory/Default/Preferences`（JSON），合并 `profile.cookie_controls_mode = allow ? 0 : 1`，保留其它键；非法 JSON 重建；原子写；0600；回读校验。
- 在 `BrowserRuntime.start` 的 reset 之后、`launchArguments` 之前调用（`:289`/`:306`）。
- 值语义（`v2probe/logs/matrix.txt`）：`profile.cookie_controls_mode=0` allow、1 block、2 allow；顶层 key 无效；`block_third_party_cookies` 单独无效。
- `thirdPartyCookies` nil 视为 allow。每次启动都重写（幂等），防止引擎升级/退出覆盖。
- 旧 Profile 迁移时默认 allow；若用户显式选 block，写 1 并在 UI 说明 guid 会每 POST 变。

### 6.6 新建/克隆/导入的一致性

- `ProfileStore.makeDraft`（`:268-273`）、`ProfileLibrary.clone`（`:151-158`）、`importProfiles`（`:100-130`）、`batch`、`adoptOrphan`（`:511-519`）、**`ProfileStore.regenerateIdentity`（`:278-287`）** 统一调用 `identityBundle`：
  - 新 seed（import 也一律换 seed，不再只在冲突时换）、重抽 CPU/memory/screen/font/variant，按新屏幕重算窗口；
  - `deviceIdentity` 清空（走派生）；capability.fontProfiles 时强制 `adjustments.insert(.font)`；`.screen` 按 §3.1 的 capability 规则收紧；
  - 保留 name/port/proxy/其余 launch/语言时区（clone/import 保留原 locale，设备特征与窗口重抽）；
  - `adoptOrphan` 复用旧目录，置 `pendingIdentityReset`。
- `regenerateIdentity` 走同一函数，因此“整套重新生成”在 API/自动化/UI 三条入口都不会再把旧 `deviceIdentity` 带过去（`generateIdentity` 返回值只有 fingerprint 也不影响，draft 在调用前已是 nil）。
- 验证：两次 makeDraft/clone 的 seed、deviceIdentity、screen（capability 后）不同；regenerate 后 draft.deviceIdentity 为 nil 且派生值变化；consistencyIssues 为空。

### 6.7 种-清-验

`StripeStorageTests`（复用 `EngineTestSupport.swift:191` 的 `DevToolsPage`）：

1. stopped 下起临时浏览器，写 m（两种 partitionKey）、mid/sid 到 3 个域、FPJS 三件（cookie/localStorage/pvid）与 `stripe.link.persistent_token`、目标域 localStorage/IDB/SW/Cache、内帧 SS 四键 + 旧 schema、无关域 `keep`、`.link.com` 的 `__Secure-sid`/`lsid`。
2. stop → `removeSiteData` → start。
3. **默认（无白名单）**：断言 cookie **全空**（目标名、`keep`、`__Secure-sid`/`lsid`、FPJS 都在内）、SS 空且 schema 已重写、目录消失、HTTP 缓存空、pending 清、lastLaunchFingerprint 更新、pref 仍 0。
3b. **白名单开启**：只断言 `__Secure-sid`/`lsid`@.link.com 存在且值逐字相同，其余仍空。
3c. **能力变化**：把 SS 的 schema 改成旧值后启动，断言 `id/_mf/_ab` 被清且新 schema 写入，`session-cache-stale` 不红。
4. running 直接重置按现规则报错；`identity-no-start-url` 在空 startURLs 的 Profile 上是 info 而非 fail。

---

## 7. 明确不做

1. 不拦截/改写 `m.stripe.com` 请求或响应；不做 MITM。
2. 不向内帧 `m.stripe.network` 插 `<script>` 标签；只用内容脚本（`all_urls`/`all_frames`/`MAIN`/`document_start`，IdentityGuard 与 ScreenShim 都保留）。CSP `script-src`（`inner.headers:6`）只约束页面 `<script>`，内容脚本不受它约束。
3. 不 `defineProperty(navigator/document, …)` 加 own 可枚举属性；不用 Proxy 包 `navigator/document`。
4. 不手写 `id`/`a`；不压缩双空格；不伪造顶层 `i`。
5. 不写任意 42 进 mid/sid；只写 36 uuid4，让服务端补校验和。已知正确 42（如 `111…7bbff4`）可用于固定测试。jar 里已有的 42 只有与最近 `/6` 响应逐字相同才采纳，其余覆盖为 36。
6. 不清 m 就声称新设备；allow 姿态下 m 是 HttpOnly 锚点，线上头 2 年、Chrome 存储上限 400 天。
7. 不只清 mid/sid、漏 m/.stripe.com/Sessions/SS/FPJS/`stripe.link.persistent_token`。
8. 不在 running 状态做「立即换身份」（只标记）。
9. 不预置 m.stripe.network 的 sessionStorage（默认空）；不用它刻意跳过全量 a。
10. 不预置 `m`（自造 uuid 无校验和，服务端会换；已实测 `aaaaaaaa-…000000` 被换）。
11. 不用 `--force-device-scale-factor` 伪造 DPR（会改布局）；补 `LocalFrame::DevicePixelRatio` 与 media query。
12. 不用 CDP `Emulation.setDeviceMetricsOverride` 当屏幕方案：跨源 iframe 不继承、对 iframe target 报「只能顶层」（`work2/screen-emulation*.txt`）。
13. 不把 `--window-size` 当屏幕来源；screen 与 window 分开。
14. 不用 headless 的默认 800×600 当屏幕来源，也不在 headless 验语言（`-AppleLanguages` 在 headless 崩，`engine.md` §6）；headless 只验引擎读点数值。
15. 不靠 `--disable-features` 或顶层 pref 切 3PC。
16. 不在字体补丁前把 Windows 身份称为已支持。
17. 不在没有 mutation/失败用例时先改 mock。
18. 不断言请求序号；42 只看响应后的 cookie，必要时主动触发新 ping。
19. 不把 `id` 相同当唯一失败条件；也不把 id 不同当新设备充分条件。
20. 不把宿主机型（屏、macOS 版本）写进 golden 比较。
21. 不执行下载的 JS；oracle 全用 Swift 写，页面探针只做镜像。
22. 不在 golden 里放 cookie 密文或整页 HTML。
23. 不在普通重启时清存量会话 cookie（除非 reset）。
24. 不误删 `.link.com` 的账号级登录态当设备数据——但要点明：默认重置路径会连它一起删；只有开启白名单时才保留 `__Secure-sid`/`lsid` 两个名字。
25. 不在 Stripe 专用 Profile 装广告拦截/指纹插件类扩展（会改 e/n/keys）。
26. 不把 `passkeyBox` 注入当作无痕：Stripe 专用 Profile 可关 `loadPasskeyBox`，并保留 keys 断言。
27. 不在 capability.screen=true 后继续挂 ScreenShim（避免 getter 与内核双写）。
28. 不把 startURLs 当唯一可行路径；空 startURLs 必须有一条可观测的退化与规则，不允许静默不写种子。
29. 不把 FPJS visitor 留给服务端回收；三件套与 linkedId 进验收。
30. 不在没有 `/6` 回显佐证时采纳 42；不把“长度像 uuid”当合法。

---

## 8. 验证体系

原则：先有失败用例，后有实现；所有外部样本只解码不执行；每条规则一份 mutation；golden 只能显式 bless。

### 8.1 证据固化与 provenance

- 把 5 对（10 份）`/tmp/stripe-recon/p6-*-{1,2}.txt`、1 份 `live5-macos-on-747474.json`（含响应与 156 B）、collector、inner、v3 复制进 `Tests/AnyBrowserCoreTests/Fixtures/Stripe/`，写 `PROVENANCE.md`：源 URL、**每个样本对应页面的明文 URL/referrer**（b.u/b.v 与 P016/P018 复算需要）、UTC 时间、大小、sha256、抓取方式、样本到规则与样本种类的映射（首报/次报/track/unavailable）。
- 哈希清单：collector `f2a8a36c…`、inner `92844e6b…`、v3 `495eb622…`、controller `7ba9321a…`、shared `8f962043…`、live5 `176e7087…`、10 份 payload 各自 sha256（见附录 B）。
- `StripeProvenanceTests` 断言大小与哈希；`scripts/stripe-fixtures.sh` 重新生成清单。任一份字节改动即红。

### 8.2 编解码与复算 oracle

新增 `Sources/AnyBrowserCore/Stripe/`：

| 文件 | 内容 |
|---|---|
| `StripeMD5.swift` | 纯 Swift MD5（CryptoKit 无 MD5） |
| `StripeHash.swift` | latin1 语义 sha256、base64url 无填充、`PartitionedUrl`、40/30/10/6 分段、盐 `7766e861-…` |
| `StripePayloadCodec.swift` | base64→percent→JSON，错误带字节偏移 |
| `StripePayload.swift` | 强类型模型，保留原始 JSON |
| `StripeFeatureOracle.swift` | 15 项镜像：55 字体表、400×60 canvas、插件串、屏幕串、TZ 偏移 |

验收：5 份首报逐字节复算 `id`/`b.w`/`b.b`/`b.c`/`b.u` 全部命中；边界用例（UTF-8 title、userinfo、端口、`//checkout.stripe.com`、11 段后 6 位截断）；解码错误有偏移。

### 8.3 规则引擎与 mutation

`StripeRules`/`StripeViolation`/`StripeRuleCatalog`；规则不可变表；**每条规则先声明适用样本种类**，再配「只改一处」mutation。基线 0 违规；mutation 恰触发对应规则；覆盖测试枚举规则表。

强制 mutation：把一份 `track` 体喂给 `P002` 必须不红；把 `a:null` 次报喂给 `P008`/`P020`/`S*` 必须不红；把 `unavailable` 喂给 `P005` 必须不红。施工者不得为让规则过而改采集路径。

### 8.4 规则目录（修正后）

**先分类，再套规则**。样本种类：

- `first`：v3 自动帧的首个全量 ping（`a` 为对象，15 键）。
- `repeat`：同帧次报（`a:null`，仍带 `v2/id/t/...`）。
- `track`：inner 监听器重建的五键 beacon 体 `{muid,sid,url,source,data}`；`version` 只作 beacon 路径第二参，**不在体里**。
- `unavail`：错误包 `id:"unavailable"`（无 `a`/`b`/`h`）。
- `resp`：`/6` 响应（36 B / 156 B）。
- `chain` / `cross`：跨报文或跨 Profile 的链路断言。

表中「域」= 适用种类；不在域内的样本不喂该规则。旧目录的「顶层键恰为…」等断言据此重分组。

**结构/完整性**

| ID | 域 | 严重度 | 断言 |
|---|---|---|---|
| P001 | any | block | 合法 base64、percent、JSON |
| P002 | first, repeat | block | 顶层键恰为 `{v2,id,t,tag,src,a,b,h}`；**无 i**；若出现 i 记 warn |
| P003 | first, repeat | block | `tag=="$npm_package_version"`、`src=="js"` |
| P004 | first, repeat | block | `v2∈{1,2}` |
| P005 | first, repeat, unavail | block | `id` 32 位小写 hex；`unavail` 的 `id=="unavailable"` 放行 |
| P006 | first, repeat | block | `first` 的 `a` 为非空对象；`repeat` 的 `a` 必须为 null |
| P007 | first | block | 每项 `{v:string,t:number,at?:number}`，无额外键 |
| P008 | first（a≠null） | block | `id==md5(join(" "))`，双空格未压缩（两处） |
| P009 | first | block | k/m 为空；无 `"unavailable"`；c/e 空允许 |
| P010 | first, repeat | block | h 为 20 位小写 hex |
| P011 | first, repeat | block | b 键 ⊆ `{a..j,n,u,v,w}`；a–j、n、u、w 必在；v 只在 a 非空时出现 |
| P012 | first, repeat | block | d/e 为 NA、合法 36 或合法 42：`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}([0-9a-f]{6})?$`；uppercase/v1/variant c-d 为反例 |
| P013 | first, repeat | block | `b.f===false`、`b.g===true`、`b.h===true`（带 `b.` 前缀；`a.f` 是屏幕串、`a.g` 是时区数字） |
| P014 | first | block | b.i/b.j 与内帧实测深相等 |
| P015 | first, repeat | block | b.n 数字、0<n<60000、n>t |
| P016 | first | block | b.a/b.b 用明文输入复算；stripe 权威域保留、checkout 只保留 authority |
| P017 | first | block | b.c == sha256Base64URL(utf8(title)+salt) |
| P018 | first | block | `b.u`（url 有域时）与 `b.v`（referrer 有域时）== 明文 domain；不是 b.b/b.a 的 domain；`b.v` 允许缺（5/5 首报缺） |
| P019 | first, repeat | block | b.w 时间在 [capturedAt-2s, +120s]，sha256hex(h+(ts+1)) 命中 |
| P020 | first（a≠null） | block | t ≤5 位有效数字、t≥max(a.*.t)（sum 可更大） |
| P021 | resp | block | /6 200、application/json、156 B、三键 42 |
| P022 | chain | block | a=null 时前报文同 id 且 SS.id==id；v2:2 时 a 必须为对象 |
| P023 | track | block | 无 id/a/h；体键恰 `{muid,sid,url,source,data}`（**无 version**；version 只应出现在 beacon 路径第二参），url 已哈希 |
| P024 | first | block | at 只在 j/n，0≤at≤t_i |
| P025 | any | warn | 顶层 `i` 若出现，必须等于 canvas 的 dataURL（`internalValue`，不是 md5）；当前版本 absent |

**语义/环境**（全部 `first`；能力项加前置）

| ID | 域 | 严重度 | 断言 |
|---|---|---|---|
| S001–S015 | first | block | 逐项等于 §1.2 目标：a true / b false / c languages join / d platform / e 5 插件串 / f avail 串 / g `-offset/60` / h false 且 maxTouchPoints=0 / i enabled 串 / j oracle 位串 / k "" / l UA / m "" / n false 且 bait 可测 / o oracle canvas md5。**S006(f)、S017、S019 只在对应 capability 为 true 时 block，否则 info**；其余项在 P1 基线允许按样本期望值断言 |
| S016 | first | block | e 的 `++` 与逗号分隔逐字一致 |
| S017 | first（fontProfiles） | block | j 55 位仅 0/1，与测量位串逐位相等 |
| S018 | first | block | o 与会话内两次独立绘制一致 |
| S019 | first（fontProfiles） | block | `document.fonts.check` 与 j 位一致 |
| S020 | first（screenMetrics） | block | `matchMedia('(resolution:Xdppx)')` 与 dpr 一致 |

**身份**

| ID | 域 | 严重度 | 断言 |
|---|---|---|---|
| I001 | first, repeat, chain | block | 三值匹配 P012 正则；42 的校验和须与最近 `/6` 响应回显逐字相同（不是本地格式判断） |
| I002 | chain | block | allow 姿态且响应后 guid == m |
| I003 | chain | block | muid==`__stripe_mid`、sid==`__stripe_sid`（`I008==true` 时跳过） |
| I004 | chain | block | 首报 d/e ∈ {NA, 种子 36}；响应后 cookie 42；响应后再触发的新 ping 为 42（`I008==true` 时跳过） |
| I005 | chain | block | allow 姿态且两次启动间隔 <30 min：guid+muid 稳定（sid 允许不同）；block 变体只断言 muid 稳定 |
| I006 | cross | block | 两个新 Profile 三元组全不同、id 不同、canvas 必不同；capability.screen/fontProfiles 时再要求 screen/font 至少一项不同 |
| I007 | chain | block | 帧 hash 的 mids 等于首帧前 cookie 或 NA，version=6 |
| I008 | chain | info | Checkout mids → pinned，跳过 I003/I004（`C011` 也据此跳过） |
| I009 | chain | block | 种子 mid 前缀 == effective(identity) |
| I010 | chain | block | 第二次启动不重写 mid（jar 值不变） |
| I011 | resp, chain | block | block 姿态无 m 且 guid 每载必变；allow 姿态 m 存在、HttpOnly、SameSite=None、≤400 天（线上 2 年、Chrome 截断）、无 partitionKey，第二次 POST 带 Cookie |

**跨项/几何**

| ID | 域 | 严重度 | 断言 |
|---|---|---|---|
| C001 | first | block/warn | outer ≤ screen、inner ≤ screen（headless 且无 screen capability 时 warn） |
| C002 | first | block | screen 几何与平台 dpr/cd |
| C003 | first | block | platform/UA/CH platform 一致；UA 主版本==引擎主版本 |
| C004 | first | block | JS brands 与 `sec-ch-ua` 头同源；`brand==.chrome` 时两者都含 Google Chrome；Edge 要求 `Microsoft Edge` 与 `Edg/` 同源；其余品牌按各自真机样本 |
| C005 | first | block | languages[0]==language；主语言与出口一致 |
| C006 | first（fontProfiles） | block | 字体位串平台可信（Windows 含 Segoe/Calibri，macOS 无 Segoe，核心位为 1） |
| C007 | first | block | deviceMemory 在 GPU 集合 |
| C008 | first（screenMetrics） | block | screen/DPR 属平台目录 |
| C009 | first | block | canvas 同会话稳定 |
| C010 | chain | block | fresh 启动的首报前 m.stripe.network 无 SS 键 |
| C011 | chain | block | `I008==false` 时任何带 mids 的请求与 cookie 一致 |
| C012 | first | block | window 无 anybrowser/fingerprint/stripe 自建全局；keys 基线 |
| C013 | first | block | capability.fontProfiles 时 fontProfile 非 nil 且 `.font` 未被 disable |
| C014 | first | block | screenMetrics 时 screen 六字段 + cd/pd 非 nil |
| C015 | first | block | posture 与 pref 实测一致 |
| C016 | first | warn | 本机时钟与 HTTP Date ≤2 s |
| C017 | cross | warn | Profile 出口未被其他 Profile 共享（发布门） |
| C018 | first | block | 扩展不改变 e（插件串）与 keys |
| C019 | first | block | brand 非 nil 或 arguments 已补 Chrome |
| C020 | first | block | `unavailable` 包结构合法：只含 `id:"unavailable"`，不含 `a/b/h` |
| C021 | first | warn | `navigator.connection.effectiveType/rtt` 与出口链路类型相容 |

**错误/时序**

| ID | 域 | 严重度 | 断言 |
|---|---|---|---|
| E001 | any | warn→block | 无 `id:"unavailable"` 包：首报 warn，同链路连续两次 block |
| E002 | chain | block | 内帧出现后 15 s 内至少 1 条 /6 |
| E003 | chain | block | 到 m.stripe.com 的请求均为 POST /6（/4 用例除外） |
| E004 | chain | block | 无 CSP 违例 |
| E005 | chain | block | 单链路 /6 ≤8 |
| E006 | chain | block | 40 s 内链路完整 |
| E007 | chain | block | 无扩展控制台错误 |
| E008 | resp | block | 任何 /6 响应 200/156 B/三键 42 |
| E009 | cross | block | 首访前无 FPJS 三件套；触发后 `linkedId == stripeJsId`（`fpjs-visitor` 的运行时版） |

### 8.5 规范化与 golden

`StripeCanonical`: 结构字段保序；可复算字段保留；`t/at/n/h` 与时间、cookie expires、端口替换为占位。另在同机 golden 里记 `t/at/b.n` 的分布区间（首报 `n.t` 20.8–21.9、`n.at` 0.2–0.3、次报 `b.n` 194.7–198.4），只做同机漂移提示，不做跨机门槛。
`StripeGolden`: 目录 `Fixtures/Stripe/golden/<engine>/<macOSMajor>/<preset>/<mode>.json`，内嵌 collector/v3 哈希。禁止自动 bless；`ANYBROWSER_BLESS_STRIPE=1` 才写盘；CI 未 bless 的漂移红；引擎升级分支允许 bless 且双人复核。

### 8.6 CDP 事件订阅（先 15 分钟 spike）

改 `DevToolsClient.receive`（`:93-118`，当前 `:109-111` 把无 id 消息丢弃）：无 id 消息路由给 `AsyncStream` 订阅者；新增 `DevToolsClient+Events.swift`（subscribe、`Target.setAutoAttach` 递归、`Network.enable`、`Network.getRequestPostData`）。

Spike 失败即退到 `Page.addScriptToEvaluateOnNewDocument` 记录器 + 探针页自报；记录代价与缺口。

### 8.7 只读探针与快照

`StripeProbePage`（镜像 15 项与 b）与 `StripeProbe`（CDP attach 顶层与内帧、记录 request/response/cookies/SS、内外各测一次；b.a/b.b/b.c 取内帧 hash 的 referrer/url/title）。

探针先**固定 preset、locale、platform** 再比较两 seed：`IdentitySampler.sample` 自己 `choosePreset` 并 `choose(localeProfiles)`（`IdentitySampler.swift:160-182`），不固定会连 `d/l/c/g/e` 一起变，旧“只允许 o/j/f”断言必红。

验收：同 seed 两次 15 项全相等；固定三项后两 seed 只允许 o/j/f 变化（seed 派生的 audio/clientRects/CPU/GPU/deviceMemory 在探针里另列并允许不同；capability.fontProfiles=false 时 j 不要求分离、screenMetrics=false 时 f 不要求分离）；探针 j 与 payload j 逐位相等；快照 schema 通过；内帧无注入痕迹。

### 8.8 真实 v3/m2 链路

本地固定端口 9480 的 `StripeE2EPage`，`/elements` 只加载 v3+pk_test 并 mount card；断言 15 s 内出现 /6、首报 15 键、响应后 5 s 内 `__stripe_mid` 为 42、响应后 `history.pushState` 再触发一次 ping 并断言其 d/e 为 42、次报 a:null 同 id、/interact 触发 v2:2 全量、156 B、无 CSP。

**时序断言修正**：首报 `n.t` ≥19、`n.at` ≤5；`j.at` 存在且 ≤12（实测 5.7–7.4，同机 golden 另按区间）；`t ≥ max(a.*.t)`；`b.n > t`；`b.n` 在 v3 自动帧首报 ≥950 且 <60000，次报只要求 0<n<60000（194.7–198.4 写进 golden）；`b.w` epoch 在 ±5 s；42 cookie 在响应后 5 s 内出现。

### 8.9 身份矩阵与跨 Profile

`StripeIdentityTests`：

- 三 Profile 并发：三元组全不同；首报 NA/种子；响应后 42；同 Profile 不重置重启稳定（<30 min、allow）；两 Profile canvas 必不同，capability 打开后再加 screen/font 的差异断言；allow/block 两姿态分别跑；FPJS 三件套与 `stripe.link.persistent_token` 首访前为空。P2 阶段先跑无 screen/font 的基线断言，P7 补齐。
- **regenerate E2E**：Profile 已有旧 mid/旧 m，跑一次 regenerate 并确认 `deviceIdentity == nil` → 记 pending reset → 停/清/启；首报 mid 前缀必须等于 `derived(newSeed, platform)`，jar 里不得出现旧前缀（`identity-derived-after-reset`）；同一断言走一遍 `AutomationAPI` 只改 seed 的 PATCH。
- **空 startURLs 用例**：不带 URL 的新 Profile 启动，seeder 不跑，`identity-no-start-url` 为 info，首访 NA 可接受；补一个带 URL 的对照确认 seeder 确实写入 36 且首请求带 Cookie。
- **imported-invalid-42 用例**：导入 jar 里塞 uppercase 后缀、v1 前缀、variant c/d、以及与 `lastResponseMuid` 不同的 42 各一份；启动后断言全部被覆盖为 36，且 `I001` 在下一份与服务端回显一致的响应上才是绿。
- cookie 期望按 §6.2：默认重置后 `cookieNames().isEmpty`（含 `__Secure-sid`/`lsid`）；白名单模式单独用例只保两个 Link 名。

### 8.10 3DS / Checkout / he=false

- 3DS 卡 `4000002500003155` 必挑战；抓 `three-ds-2-fingerprint` 帧；断言 `browser` 的其余 11 项与 Profile 一致（`browserColorDepth`=cd、`browserScreenWidth/Height`=screen.width/height、`browserTZ`=offset、`browserLanguage`=language、`browserUserAgent`=UA）；`threeDSCompInd=Y`。
- `challengeWindowSize` 只在 hosted 分支非 null：controller 消费的键是 `outerWindowWidth`（`controller.js:54235-54236`），v3 把 `window.innerWidth` 赋给它（`v3:41789`），档位是枚举码 `01..05`。普通 Elements 页只断言其余 11 键并确认该键为 null；hosted Checkout 用例按该输入值算档，并测全屏优化（`overrideHostedChallengeWindowSizeToFullscreen`）覆盖为 `05`。
- Checkout 页带 `__checkout.mids`：pinned，断言 b.d 等于 payload mids。
- `he=false`：seeder 不写该 host、无 cookie 变化、guid 36、无帧。
- FPJS：首访/Link/3DS 前断言 `__Secure-f-visitor-id`、localStorage `_vid`、`__fpjs_pvid`、cookie `stripe.link.persistent_token` 皆无；触发后断言新建 visitor、cookie 为 `.link.com/.stripe.com/.stripecdn.com/.onelink.com` 的 Secure/SameSite=None、86400 s，`sealedResult.linkedId === stripeJsId`。同 Profile 跨帧核对 §2.9 的字段（WebGL/audio/hardwareConcurrency/deviceMemory/screen 帧）；`enumerateDevices`、`pdfViewerEnabled`、`prefers-*` 只记录观测值，不做断言。
- 请求头：E2E 用 `Network.requestWillBeSent` 断言 `sec-ch-ua` 与 `navigator.userAgentData` 同源（Chrome 身份含 Google Chrome、Edge 含 Microsoft Edge），`sec-ch-ua-platform` 与 platform 一致。

### 8.11 金丝雀、门禁与 CI

- `scripts/check-stripe.sh` 每日抓 `inner.html`/`out-*.js` 的哈希/大小/字段数，并抓 wanderlust 的 FPJS 脚本版本/哈希；变化开 issue。`check-updates.sh` 只管引擎/Passkey。
- `scripts/stripe-canary.sh` 每晚 app.link.com/login，3 Profile，除 Stripe 外也观察 FPJS visitor 是否按 Profile 分离，只告警（≤5 min）。
- CI：无引擎单测 <5 s；改 fingerprint/sampler 跑 macOS 3 预设×2 seed×2 姿态；改存储/身份跑 StripeStorage/Identity；引擎升级跑全矩阵 + 重 bless + 双人复核。
- 失败输出：规则 ID + `file:line` + 期望/实际 + 原始字节偏移；不打印 cookie 以外的隐私。
- 每版本与官方同版本 Chrome diff keys/plugins/UA-CH/GREASE；差异必须写进 golden 白名单。

### 8.12 自检与 UI

- `SelfCheckObservation` 增加 `keysDoc`/`keysNav`、screen 全字段、`resetFresh`、`posture`；`SelfCheck.run` 的 runner 侧用 `Storage.getCookies` 读取 mid/sid/m 并写入 observation（页面脚本读不到 HttpOnly）。
- 新增项：`stripe-identity`（runner 先用 `Storage.setCookies` 给探针 host 写 effective identity 的 36 mid/sid 并回读，再用应用内 fixture collector 发两次：首报全量 a、id 与 a 复算、第二次 a=null）、`stripe-cookies`（mid 前缀==effective identity、sid 存在、allow 有 m/block 无 m）、`object-keys`、`screen`、`font-bits`、`stripe-error`。
- **loopback 不读响应**：`m.stripe.com` 的 ACAO 是常量 `https://m.stripe.network` + `allow-credentials: true`，不反射源（`work/a.headers:9-10`）。loopback 页带凭据 POST 会发出去、Set-Cookie 会落，但 `xhr.status` 恒 0，collector 只在 `status===200` 时 resolve（`mod-29.js:29-33`），`responseText` 读不到。所以自检一律：fire-and-forget 发请求 → 通过 CDP `Network.requestWillBeSent.postData` 断言 body → 通过 `Storage.getCookies` 断言 cookie 副作用；不 await collector 的 promise、不等 42。
- **sessionStorage 断言放真实帧**：自检页的 SS 属于 loopback origin，不是 `m.stripe.network`；`stripe-session-cache`/`C010` 改为在真实 v3 链路的 m.stripe.network 帧里读（自检只作补充）。本地 `inner.html` 默认 `#version=4` 会拿到 36 B 纯文本，`SelfCheck` 供的副本固定 `#version=6`。可选方案：自检 host 走 `--host-resolver-rules` + 可信证书，从真实 `m.stripe.network` 源跑。
- `Package.swift` 的 AnyBrowserCore target 加 `resources: [.copy("Resources/Stripe")]`（目录为 `Sources/AnyBrowserCore/Resources/Stripe`）；`SelfCheck` 的 loopback 页按路径提供 `collector.js` 与 `inner.html`，只执行本地文件。
- `SelfCheckSheet` 增加 Stripe 页签；失败项可展开规则 ID、期望/实际与请求证据（`SelfCheckSheet.swift:38-70` 之后）；支持导出诊断 JSON（不含 cookie 值以外的隐私）。
- **自检副作用**：`stripe-identity` 会在真实首次访问之前给 Profile 建立 m/guid（有益但改动了被检对象）；首次访问若由自检完成，Profile 不再“首访新鲜”。UI 需注明，E2E 与手工验收也要意识到这点，不能拿自检后的 cookie 当首访证据。
- 新建 Profile 全绿；手工塞回旧 cookie 后 `stripe-identity`/`stripe-cookies` 红；旧 `_mf` 塞回后 `font-bits` 红；capability=false 的屏幕项按 §5 标 info/warn，不假装 pass。

---

## 9. 分阶段实施（风险从高到低）

> 每一阶段都以「能证伪」为完成标准；前一阶段不过不进入下一阶段。高风险 spike 全部前置。

### P0 去风险 spike（1–3 天）

| # | Spike | 通过标准 | 失败处置 |
|---|---|---|---|
| 0.1 | CDP `Network.requestWillBeSent.postData` + auto-attach | loopback POST 完整取到 body；事件不吞命令 | 改 new-document 记录器，观测段降级 |
| 0.2 | fork `148.0.7778.215` 未改基线构建/签名 | DMG 起得来、版本 `.300`、探针与 `.215` 一致、codesign 通过 | 只做 App 侧，屏幕/字体标实验性 |
| 0.3 | `profile.cookie_controls_mode=0` 写入/保持 | m 落盘、guid 跨载稳定、`Sec-Fetch-Storage-Access: active` | 回到引擎 3PC patch |
| 0.4 | fixture 回放复算 | 5/5 id/b.w 命中 | 修正 oracle 后再继续 |

### P1 观测与规则（2–3 天，只做决胜子集）

fixtures/provenance → codec → 可复算子集（P 规则、b.w/b.b/b.c/b.u 复算、`/6` 响应 schema、cookie 身份规则 I001/I003/I009/I010）与样本分类。**S 规则拆成“首报语义”与“能力项”：屏幕/字体能力项在 P4/P5 前只 info，不阻塞。** 基线只对可复算子集宣称 0 违规，5/5 复算命中。golden/provenance 先立骨架，屏幕/字体 golden 等 P4/P5 后补；canary 与 3DS 移到 P7。产品零改动。

### P2 身份生命周期、3PC、清理（5–8 天）

deviceIdentity 派生/采纳 → seeder + 回读 → IdentityGuard 屏障 + restore 关闭 + Sessions 清理 → pref 写入 → 导入/备份策略 → 存储种-清-验 → 身份矩阵。

验收：新 Profile 首访前 mid=36 前缀；首请求带 Cookie；响应后 42 前缀不变；二次启动不重写；jar 内错误 42（uppercase/v1/variant/未回显）被覆盖为 36；两 Profile 全不同；regenerate 后 deviceIdentity=nil、首报前缀等于新派生值、jar 无旧前缀；allow/block 姿态实测正确；默认重置后 cookie 全空（含 Link 登录），白名单模式只保两个 Link 名；重置后旧值全无。

### P3 Swift 模型、目录、窗口、capability（5–7 天）

字段/解码/校验 → 目录修正 → 窗口派生 → ScreenShim 兜底 → capability 与探针 → UI 摘要与跟随开关 → 迁移写回。

验收：`StripeConfigurationTests` 逐项断言开关与顺序（含 `.screen`/`.font`）；所有边界拒绝；旧 JSON 不变；窗口落在伪造 avail 与宿主交集内；平铺后的窗口仍 ≤ 伪屏（`window-screen-consistency` 绿）；`screenShimEnabled` 有过期/重装用例；capability=false 时 shim 让两个 Profile 的 f 分离，SelfCheck 屏幕项可 pass、matchMedia 项 info。

### P4 引擎屏幕补丁（6–10 天）

config plumbing → Screen getter → LocalFrame dpr/media → headless → capability 开启。

验收：headless/headed 六项+cd/pd/dpr 逐字；matchMedia 一致；orientation 一致；窗口 121 offset；两 Profile f 不同；golden 屏幕项通过；capability=false 的引擎上旧 Profile 参数不变，capability=true 的引擎上迁移后参数稳定。

### P5 measureText 修复与字体表（8–12 天）

乘数修复 → TextMetrics 回归 → shim isNeeded=false → font 表/变体 → fonts.check → 参考机抓串。

验收：主线程/Worker/iframe 宽度 >100 且相等；12 getter 原生；rect 100.296875 不变；55 位 golden 逐位；默认 Profile 的 `--disable-spoofing` 不含 `font` 且 `adjustments` 含 `.font`；Windows Segoe/Calibri=1；macOS 无 Segoe；同 Profile 三次稳定；无 unavailable。

### P6 UA-CH、deviceMemory、touch、canvas（4–6 天）

默认品牌/CH → memory/touch → canvas emoji → SelfCheck 期望修正。

验收：JS brands 与 `sec-ch-ua` 头同源；Chrome 身份两者都含 Google Chrome、Edge 身份两者都含 Microsoft Edge 且 UA 带 `Edg/`；显式 memory 生效；touch 成对；canvas 两次相同、跨 seed 不同、关 spoof 回宿主。

### P7 E2E、3DS、UI、发布（6–10 天）

真实链路 → 3DS → identity/cookies/object-keys/screen/font 自检项 → 金丝雀 → 签名/sha/版本锁/回退。

验收：§0.3 全项；§8 全矩阵绿；DMG sha 与版本锁一致；回放 id 与 a 复算一致；两 Profile 所有 id 不同；3DS browser 全 12 键自洽（hosted 档位另测）；FPJS 三件套与 linkedId 断言绿；`sec-ch-ua` 头断言绿；UI 不把 info 说成 pass。

### 交付顺序与可并行性

P0 全部并行；P1 串行出基线；P2/P3 可并行（不同文件）；P4/P5/P6 在 fork 分支内并行但 P4 先合；P7 依赖全部。

### 每阶段回退

- P2：关掉 seeder 即回 NA-first；pref 回 1；Guard 卸下。
- P3：capability false 即回到当前行为。
- P4–P6：版本锁回退 `.215` 与旧 DMG，capability 自动 false。
- P7：金丝雀告警不阻断；发布回退旧 DMG。

---

## 10. 残留风险（高→低）

即使以下全修完，三条最强残余仍在：**同一出口 IP 与同一网络栈**（关联在网络层先发生，新 Profile 必须配新出口，最好不同 ASN/地区，并让语言/时区/connection 跟随）、**两个不可控的第二采集面**（FPJS Pro 与发卡行 ACS，字段集由对方决定，只能自洽不能保证像真机）、**服务端黑盒聚类 + 同构建簇**（id 全换也可能被归并）。因此“两个新 Profile 的 id/三元组不同”只是必要条件，金丝雀观察到的服务端行为差异才是唯一充分性证据。

| # | 风险 | 影响 | 缓解 | 对「新设备」的残余 |
|---|---|---|---|---|
| R1 | 服务端黑盒规则 | 自洽仍可能被拒/加验 | 金丝雀、真实测试模式、3DS 观察；明确“证明自洽与非关联，不证明免检” | 永远存在 |
| R2 | 采集器换版 | id/盐/字体表/画布算法全失效 | 每日哈希门禁；换版先补 fixture 再发版 | 24 h 内可见 |
| R3 | fork 构建/签名成本 | 路线整体不可用 | P0 前置验收；保留旧 DMG；只用 ARM64 官方构建参数 | 退回 App 侧后屏幕/字体半残 |
| R4 | 字体表失真 | Windows/Linux 仍像假机；宽度被高级脚本识破 | 真实参考机、双变体、宽度 0.4%–3% 由真实分布校准 | j 可信度下降；canvas 字形仍是宿主 fallback |
| R5 | 3PC 姿态漂移 | m 忽有忽无，验收假过 | 每次实测 pref 与 POST 带 Cookie；两套 golden；升级标 pending reset | 身份连续性断裂 |
| R6 | 屏幕大于/小于宿主、分屏覆盖 | 窗口越界、inner>screen | 目录上限、CGDisplayBounds 点尺寸、窗口 clamp、WindowArrangement 用伪屏 area、多屏重采样 | 少量机型不可用 |
| R7 | 采纳逻辑 bug | 每次启动换 muid | 确定性派生 + 采纳 + I010 断言 | 普通重启变新设备 |
| R8 | Session restore 复活 | 旧 `_mf` 抑制全量 a | Sessions 清理 + restore 关闭 + 屏障 + 首访 SS 观测 | 手工 restore 时仍可能 |
| R9 | 清理不全 | 旧 m/mid/FPJS visitor 残留 | 整库删 + 按名 + 域匹配 + 种-清-验 + FPJS 三件套 | 导入/备份路径最易漏 |
| R10 | DPR 只改 getter 与布局不一致 | 页面可测 matchMedia 矛盾 | 改 `LocalFrame::DevicePixelRatio` 并测 media；不用 force-scale | backing 仍宿主尺度 |
| R11 | 时钟偏差 | b.w 不可复算 | 校时；C016；与 HTTP Date 比较 | 无 |
| R12 | Checkout `__checkout.mids` | 新 Profile 仍报旧 mids | pinned 标记；E2E 两条链路 | Checkout 场景关联度高 |
| R13 | 同出口 IP 与同网络栈 | 关联度只降一半 | 新设备配新出口（发布门）；语言/时区/connection 跟随；C017/C021 | 强残余 |
| R14 | 引擎 148 全局簇 | 版本年龄可算 | 规划 rebase 到 150/159；不伪造版本 | 全局相同 |
| R15 | Keychain 不可用（shell 直启） | cookie 不落盘、跨启动断言假红 | 以 GUI/App 路径为准；shell 注明 | 仅测试环境 |
| R16 | 扩展足迹 | keys/getter toString 可见 | Guard 只改 SS；PasskeyBox 审计；Stripe 专用 Profile 可关 | 低 |
| R17 | Object.keys 基线随引擎漂移 | 假红或静默弱化 | 每版本官方 Chrome diff；golden 阻断 | 无 |
| R18 | 现有 Profile 迁移不完整 | launchArguments 与运行配置不一致 | 启动前补齐并写回；同源生成 | 老库需一次迁移 |
| R19 | Local Font Access | 仍枚举宿主字体 | Stripe 不读；记为已知边界 | 其他 SDK 可见 |
| R20 | 只有 id 不同 | 同型号同屏同字体的“新机” | 要求 canvas + screen/font 双差异；C008 | 单特征不够 |
| R21 | 过度伪造（不存在的机型组合） | 硬件交叉失败 | 只用平台常见目录与 GPU 集合；C007/C008 | 无 |
| R22 | 公开 pk_test 限流 | E2E 不稳定 | 环境变量自有 key；缺 key 跳过记 info | 无 |
| R23 | FPJS visitor 残留 | Link/3DS 首步被旧 visitor 回收 | 三件套清理 + linkedId 验收 + `fpjs-visitor` + 种子硬化 §2.9 | 失败路径仍可能 |
| R24 | sec-ch-ua 请求头缺品牌 | 服务端第一眼就不是普通 Chrome | §2.4 默认品牌 + 头断言 + E2E | 无 |
| R25 | regenerate 带旧 deviceIdentity | 新指纹背旧 muid | regenerate/API 清值 + `identity-derived-after-reset` + E2E | 无 |

---

## 11. 批判与修订记录

逐条吸收 `/tmp/stripe-plan-v2/critique-final.md`；本表只记动作，不重复论证。全部 24 条（含子项）已落地，无未采纳项。

| # | 级别 | 批判要点 | 修订位置与动作 |
|---|---|---|---|
| 1 | critical | regenerate 把旧 deviceIdentity 带过去 | §4.2 增“重新生成必须清旧值”与 `checkForConflicts` 查重；§6.6 把 `regenerateIdentity` 并入 identityBundle 并断言 draft 为 nil；§5 增 `identity-derived-after-reset`；§8.9 增 regenerate E2E 与 API PATCH 变体；R25 |
| 2 | critical | `.font` 默认不在 adjustments，字体链路全死 | §3.2 增字体改写项强制规则（sample/bundle/adapt/randomize），capability=false 移除；§2.3 gate 写 capability；§5 增 `font-spoof-disabled`；§8.4 C006/S017/S019 加 capability 前置与 C013 扩项；P5 验 `--disable-spoofing` 不含 font |
| 3 | high | FPJS/wanderlust 未进新设备定义 | §0.1 声明 m2 不是全部面；§0.3 增第 7 条（三件套 + linkedId）；新增 §2.9 字段硬化表与跨域约束；§5 增 `fpjs-visitor`；§8.10 加首访前/触发后断言与观测项；§8.11 canary；§8.4 E009；R23 |
| 4 | high | 规则无样本种类分支、track 键集错 | §8.3 增样本分类与三条强制 mutation；§8.4 全面改为“域”列，P023 五键、P005 放行 unavail、P006 区分 null、P008/P020/S* 仅 a≠null；C10 改写；E009 独立成行 |
| 5 | high | seeder 只认 startURLs，默认空 | §4.4 第 0 步：默认起始 URL + UI 提示 + `identity-no-start-url` + 导航钩子备选；§4.7 增加 no-start-url 行；§8.9 增空 startURLs 用例；§7 第 28 条 |
| 6 | high | “保留 .link.com/无关 cookie”与实现相反 | §6.2 改为“重置=全 cookie 清空（含 Link 登录）”，另给可选两名字白名单；§6.7 拆默认/白名单两组断言；§8.9 改断言；§7 第 24 条 |
| 7 | medium | 采纳任意 42 固化客户端分叉 | §4.4 第 3 步只为 36 与“最近 /6 回显逐字相同”的 42 放行，其余覆盖 36；§4.7 bad-42；P012 收紧；I001 改为与服务端回显比；§8.9/P2 用例；§7 第 5/30 条；附录 B 反例 |
| 8 | medium | b.n 断言与样本相反 | §1.3 改首报 1,056–1,101/次报 194.7–198.4；§1.4 把计时写成关联信号并给分布；§8.5 golden 记 195；§8.8 分首报/次报下界 |
| 9 | medium | challengeWindowSize 只在 hosted、源是 outer | §0.3 第 6 条改；§8.10 普通页只测其余 11 键、hosted 按 outer 分档并测全屏覆盖 05；附录 A.2 改 12 键 |
| 10 | medium | loopback CORS 必失败且 SS 分区错 | §8.12 改为只经 CDP postData/cookie 断言、不读 response；SS 断言移真实帧；副本固定 `#version=6`；给 host-resolver 备选；注明自检副作用 |
| 11 | medium | 分屏覆盖派生窗口 | §3.6 增 WindowArrangement 用伪屏 area + clamp；§3.7 `screenMetrics` 为唯一判据；§5 增 `window-screen-consistency`；P3 验收；R6 |
| 12 | medium | sec-ch-ua 请求头缺品牌无人断言 | §2.4 增三层验证（JS/头/品牌分支）；C004 扩到 headers；§8.10 E2E 加头断言；R24 |
| 13 | medium | C004 对 Edge 错 | §2.4 与 C004 均按 brand 分支，Edge 要 Microsoft Edge + Edg/ |
| 14 | medium | I005 忽略 sid 过期与 block churn | I005 限 allow + <30 min、只断 guid+muid；block 变体只断 muid；§8.9 同步 |
| 15 | medium | §8.7 两 seed 断言忽略随机 preset/locale，P1 屏幕必红 | §8.7 先固定 preset/locale/platform 且按 capability 分层；§8.4 S 规则按域 + capability；§9 P1 缩到可复算子集 |
| 16 | medium | 缺 connection/设备枚举/计时宿主面 | §0.5 增 connection/enumerateDevices/pdfViewerEnabled/prefers-*/计时分布；§1.4 计时关联；C021；§8.10 FPJS 观测；§8.5 golden |
| 17 | medium | screen token/shim/派生窗口语义未落地 | §3.1 增 `FingerprintAdjustment.screen` 与开关规则；§3.2 校验；§3.7 定义 `screenShimEnabled` 过期/重装与两层注释；§3.9 安装记录；§4.3 引擎变化置 reset |
| 18 | medium | 升级后 `_mf` 压制全量 a | §4.6 增 schema 键与自清；§5 `stripe-session-cache` 扩到能力变化并增 `session-cache-stale`；§6.7 3c 用例；§4.3 |
| 19 | medium | P012 只查长度 | P012 改完整 v4 正则并列 uppercase/v1/variant 反例；I001 同步 |
| 20 | medium | C011/I004 与 pinned 冲突、P013 缺 b.、P018 缺若存在 | C011 加 `I008==false`；I003/I004 标注 pinned 跳过；P013 写 `b.f/b.g/b.h` 并注明槽位；P018 改条件式且允许 b.v 缺 |
| 21 | medium | 验证过重与 3 处事实错 | §9 P1 缩为 2–3 天只做决胜子集；§8.1/§8.2 改 5 份；附录 B 补 live5 哈希与大小；§0.1 改“两处”并给复算依据 |
| 22 | low | §7 第 2 条与 all_frames 实现矛盾 | §7 第 2 条改为“不插 `<script>`，只用内容脚本”，显式保留 IdentityGuard/ScreenShim |
| 23 | low | 新 Profile 无 Default 目录 | §6.5 `apply` 先 ensure `Default/` |
| 24 | low | 小项合集 | j.at 放宽到 ≤12（同机 golden 更严）；§8.12 注明自检副作用；§4.6/§7 第 6 条注明 2 年 vs 400 天；checkForConflicts 查 deviceIdentity；E001 首报 warn、连续两次 block |

**修订后的自检口径**：本表 1/2/6/7/15 会改变既有断言的红绿含义（旧断言按旧事实写），施工时先改测试再改实现，不允许为了让旧测试过而回退本节。

---

## 附录 A：证据索引

### A.1 采集器

- 15 槽注册：`mod-11.js:27`。
- join+md5：`beautified.js:1322-1327`；`mod-06.js:137-141`；md5 hex `mod-07.js:65-73,85-86`。
- `a` 抑制：`beautified.js:1352-1361`；`mod-06.js:158-168`。
- 顶层 i 来源为空：`beautified.js:1372,1392`；真实 10 份 payload 全部无 i。
- extractor：a 3120；b 3286；c 4025；d 4194；e 4362；f 4542；g 4712；h 4881；i 2677-2691；j 3508-3681；k 3860；l 5050；m 5217；n 5413-5430；o 1772-1792。
- `b`：`beautified.js:1256-1276`；`b.w` 1311-1314；nonce 1302-1309。
- `at` 语义：`mod-02.js:33-48`；实测 n.at 0.2–0.3。
- 传输：`beautified.js:5611-5638`；`mod-29.js:18-35`。
- inner 的 track 监听器重建五键体、`version` 作 beacon 路径第二参、默认 version 为 `4`：`inner.html` 唯一一行、`mod-10.js:95-106`。
- 字体 comparator bug：`mod-18.js:154`；`beautified.js:3677`；`fontsToDetect` 3508-3617。
- 真实 payload：`/tmp/stripe-recon/p6-*-1.txt`、`-2.txt`；`live5-macos-on-747474.json`。

### A.2 身份链

- cookie 写入：`v3:24691-24712`（`.host`、Strict、https 才 Secure、31536e6 默认）。
- `pt`/`mt`：`v3:25500-25506`；`_getID` 25692-25723。
- 42 补全/错误后缀被换：`work2/checksum-uuid-1.body`/`-2.body`（同 uuid 同 `683ce0`）、`work2/checksum-nonuuid.body`；uppercase/v1/variant 反例 `work/x_b_upper.body`、`x_b_v1.body`、`x_b_var.body`。
- `challengeWindowSize` 字段与赋值：`controller.js:54235-54236`；`v3:41789`（`outerWindowWidth: window.innerWidth`）。
- 预置采用：`work2/seed-adopted.txt`；只写不带/回读后带：`work2/seed-before-navigation.txt`。
- m 锚 guid：`work/a.headers:5`、`verify-m-anchor.md` §1.5；任意 m 被换（本轮 curl）。
- 3PC/guid churn：`v2probe/logs/matrix.txt`、`twoload_engine_default.txt`、`twoload_engine_mode0.txt`、`m_attr_engine_mode0.txt`。
- pref 语义：`matrix.txt` 的 scope/value 段；`pref_variants.txt`。
- session restore：`work2/session-restore-iframe.txt`。
- FPJS/wanderlust：`acs3ds.md:56-70`（`frontend_execution` 与 FPJS 采集面）、`:184-188`（visitor 判据与“只清一层仍留同一身份”）；`shared.js:15080-15118`（connection 字段）。
- `he=false`：`v3:24720-24746`、`25586-25588`。
- `__checkout.mids`：`v3:25526-25536`、`38718`。
- 3DS：`acs3ds.md` §0.2、§3；`controller.js:54233-54245`（browser 12 键，`challengeWindowSize` 仅 hosted，controller 键为 `outerWindowWidth`，v3 以 `window.innerWidth` 赋值，`v3:41789`）。

### A.3 引擎

- 开关池：226227393 brand 405 brand-version 423 disable-spoofing 449 screen-width 466 screen-height 491 dpr 517 hw 549 platform 582 platform-version 603 location 632 timezone 661（`engine.md` §1）。
- 解析函数：0x14D85A0–0x14D8B1C；默认品牌 0x14D8908；`Google Chrome` 0xDAA22B7。
- 字体：0xA127F00–0xA1332D8；gate 0xA127FD4/0xA12806C；macOS 0xA129B68；Windows 0xA128AC4；Linux 0xA1329C0。
- 平台映射：0x95BA1E0–0x95BA350。
- canvas gate：0xB00B178/0xBBEAA68。
- deviceMemory：`[8,16,32][seed%3]`（`engine.md` §5）。
- 屏幕死开关：`engine.md` §1-2；`report_winA/winB/winC/oldh/ordem.json`。
- Segoe/Calibri 恒等于基线：`report_raw100003/4.json`；`report_mm1.json`；`work2/font-seed-probe.txt`。
- 默认 CH 无 Google Chrome：`report_headwin.json`、`report_headmac.json`；请求头同样缺：`out/hdr_echo2.txt`（Chrome 身份 `sec-ch-ua: "Not/A)Brand";v="99", "Chromium";v="148"`）、`out/hdr_echo.txt`（Edge 身份只多 `Microsoft Edge`，仍无 Google Chrome）。
- 探针：`probe/chrome158-headed-screen.json`；`work2/screen-emulation*.txt`、`screen-shim*.txt`、`object-keys*.txt`。
- b.n 漂移：`p6-*-2.txt` 5/5 为 194.7–198.4 ms；`p6-*-1.txt` 首报 1,056–1,100 ms。
- m 的 expires 截断：`v2probe/logs/m_attr_engine_mode0.txt`（≈399.98 天）。
- Object.keys 基线：`report_pplugE.json`（keysNav []/keysDoc ["location"]）。

### A.4 仓库

- 模型：`Profile.swift:85-113`、解码 118-141、校验 439-472、adapt 589-612、randomize 495-579。
- 参数：`Profile.swift:305-332,353-402`。
- 采样：`IdentitySampler.swift:126,128-131,159-191,240-287`。
- preset：`IdentityPresets.swift:20-38`。
- 一致性：`FingerprintConsistency.swift:152-180`。
- 启动：`BrowserRuntime.swift:224-238,245-370,535-540`；清理 `BrowserRuntime+Data.swift:20-129,297-329`。
- 身份：`LaunchCoordinator.swift:158-165,185-250`；`LaunchCoordinator+Identity.swift:33-66`。
- 库：`ProfileStore.swift:268-287,511-519,698`；`ProfileLibrary.swift:96-158,400-460`。
- cookie：`CookieTransfer.swift:113-160`；`Workbench+Cookies.swift:22-38`；`ProfileBackup.swift:289-300,383-390,423-440`。
- shim：`IdentityShim.swift:23-25,48-55,64-72,84-165`；`WindowArrangement.swift:30-74`。
- 自动化：`AutomationAPI.swift:778-793`（PATCH update）。
- 自检：`SelfCheck.swift:124-158,237-267,344-351,430-560`；`SelfCheckSheet.swift:38-70`。
- UI：`FingerprintCard.swift:72-86,145-190`。
- 版本：`BundledVersions.swift:4-6`；`scripts/versions.env:7-9`；`scripts/build-app.sh:7-8`；`VersionConsistencyTests.swift:22`。
- 测试基座：`EngineTestSupport.swift:112-310`；`CookieEngineTests.swift:30-53`；`IsolationProbeTests.swift:84-130`。
- 应用资源：`Package.swift`（需给 AnyBrowserCore 加 `.copy("Resources/Stripe")`）。

### A.5 既有报告

`collector.md`、`integrity.md`、`identity.md`、`identity-chain-verify.md`、`engine.md`、`acs3ds.md`、`verify-m-anchor.md`、`verify-3pc-m-guid.md`、`verify-mids-feasibility.md`、`scores.md`；`docs/stripe-fingerprint-mock-plan.md`、`docs/stripe-refresh-on-launch.md`（旧结论按 C1–C13 修正后使用）。

---

## 附录 B：fixture 哈希

```
f2a8a36c74c59cfbe7a73d441cfd180ca6e6a9942a74ef9b240191d1c6056a59  out-4.5.45.js（88737 B）
92844e6b1ad5890a9e5e4b9dfb7abdb37dca64e8ca7365052c9d2fc8103c349d  inner.html（930 B）
495eb6229865241b1cad8f660b1236a1bbe037273968861c24f870c6d1681840  v3_plain.js（1215003 B）
7ba9321a9c746fbf2793592bfec322f8f6b3a21e2fb0b30f2b4d6842c78b17c3  controller.js
8f9620436689c5720e1e649e83c018bf79b08e19ed6b5f5b3e948842cb90c675  shared.js
176e70877336802a521faf116038542cdffc397d23c256326f586b8d20f50770  live5-macos-on-747474.json（172859 B，含响应与 156 B）
0a0f6c9b6e72ffd99282874ebd2f3a6a2790d6112d256166d7354bb5cd9222fb  p6-macos-on-747474-1.txt
06bf75a21eddfa0d9c98cc6ada7c730936b77ec893a9c72b85e6221944c6462b  p6-macos-on-747474-2.txt
21e92301a89a10a735bdf1747f8b623a108207a1808a32b5b16dec08cbaf92e8  p6-off-828282-1.txt
9f34391409c9d0b3de0554e2e634eb32edc193dfd8f3fd41e339a59735e53e62  p6-off-828282-2.txt
29f86471513fee57a4bba8871be8e2229862676ef8247bbd2de9cfab127c40be  p6-on-828282-1.txt
eb523bd504369d1ad5142ee3058135939752f293bba9182b3f715a5d5f88db7c  p6-on-828282-2.txt
c9847f5403636bcb2cd40b3805c2ac893000c4cd21b3a0901817286a6364a6bb  p6-windows-off-737373-1.txt
51f230996a85f6992f48e42b6fc1c9d4ea2d5e736dfd80e22a4caee04323f54f  p6-windows-off-737373-2.txt
6115f970c220240890332074ae21686d3c5f437330c3db909e1cf3936b88ef2a  p6-windows-on-737373-1.txt
d41061ce2da401f9dafcb8f2fe1fd0618da95bdc7e12887c7eefbb61709cc147  p6-windows-on-737373-2.txt
```

固定样例同时补充：`work2/checksum-uuid-1.body`、`checksum-uuid-2.body`、`checksum-nonuuid.body`、`seed-before-navigation.txt`、`session-restore-iframe.txt`、`font-seed-probe.txt`、`object-keys-probe.txt`、`probe/chrome158-headed-screen.json`；42 采纳反例 `work/x_b_upper.body`、`work/x_b_v1.body`、`work/x_b_var.body`；FPJS 证据 `acs3ds.md:56-70,184-188`。
