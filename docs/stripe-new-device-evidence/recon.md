# Stripe 真实注册抓包与外部资料复核

- 分析日期：2026-11-23
- 对象：`/tmp/stripe-recon/signup-capture.json`（真实 app.link.com → Stripe Link 注册流）、`/tmp/stripe-recon/font-off.json`（探针输出），外加本轮自建的 Stripe 实测复现
- 方法：JSON/CDP 抓包逐字段解析；用仓库内置 Chromium 148.0.7778.215 以 CDP 在 app.link.com 与 `m.stripe.network/inner*.html` 上复跑；WebFetch 核对 Stripe 官方文档/源码。**下载的 JS 全程只读，未 require/eval。**
- 证据分级沿用同项目约定：**A｜官方**（Stripe 文档、官方源码、官方 cookie 表）、**B｜可复现测量**（本轮抓包/引擎实测、监管或公开扫描）、**C｜社区逆向**（可复核的 GitHub/HAR/博客）、**D｜传闻/营销**。**推断**单独标注。

---

## 0. 一页结论

1. `signup-capture.json` **不是完整网络日志**：只有 1 条 `api.stripe.com/v1/consumers/accounts/sign_up`（两次尝试中的第一次，400）、5 条 `r.stripe.com/b` 分析上报、14 条 console，**没有任何 cookie/set-cookie、没有 m.stripe.\* 链路、没有文档请求**。它证明的是一次 Link 消费者注册尝试的字段与失败形态，不能单独证明 cookie 行为。
2. 抓包里的注册尝试：`email_address=d2@huawei.green`、`phone_number=+15126691515`、`country=US`（由手机号推断）、**`locale=ko-KR`**、`legal_name=aili`、携带 4,908 B hCaptcha `P1_` token 与 295 B `E1_` key；`400 "Signup is not available at this time (target_service: consumer-auth-grpc)"`。语言/号码/区域/姓名大小写本身就是一组需要治理的一致性问题。
3. 自建复现补上了抓包缺失的关键事实：Stripe.js v3 在**商家域**写 `__stripe_mid`（42 字符 = UUID+6hex，**365 天**）与 `__stripe_sid`（42 字符，**1800 秒**），`Secure; SameSite=Strict; Path=/;` **非 HttpOnly**；`m.stripe.com` 的 `/6` 报文里 `b.d/b.e` 就是这两个值，响应 `{"muid","guid","sid"}` 写回 `window.StripeM.__sid` 并由 iframe 逐层 postMessage 回商家页。**B（本机 CDP 抓包）**
4. `muid` 是**服务端签发**的：在 URL hash 里强行带 `muid=AAAA…`，`/6` 仍返回全新 muid；只有商家域 `__stripe_mid` + 该次会话的服务端识别才使它保持稳定。**要“新设备”，清 cookie 必须按“所有访问过的商家域”清，只清 `.stripe.com`/`.m.stripe.com` 是假刷新。** **B**
5. 本引擎 **`m` cookie 实测根本没有落地**：`/4`、`/6` 响应都没有 `Set-Cookie`（`sec-fetch-storage-access: none`），`Storage.getCookies` 无 `m`。这意味着此环境下跨商户的 `m` 锚点缺失（其 HttpOnly/Partitioned 属性本轮无可观测的 Set-Cookie，未验证），身份连续性只剩商家域的一方 `__stripe_mid`。**B**
6. **屏幕是真缺口**：headless 固定 `800×600@1`（而窗口/视口可以是 1400×779，甚至 2560×1289，`innerWidth > screen.width` 不可能组合）；headed 才返回宿主真实 2560×1440@2。`--fingerprint-screen-width/height` 与 `--fingerprint-device-scale-factor` 二进制里有字符串，但 headless/headed 实测**都不生效**；UI 侧 `IdentitySampler.screenSpoofingSupported = false`（`Sources/AnyBrowserCore/IdentitySampler.swift:131`）。**B/A（源码）**
7. **字体位串是平台自相矛盾的**：macOS 身份下 `a.j` 恒为宿主 macOS 的 23/55 位串（font 开/关几乎一样，开只是按 seed 抖 1–2 位）；Windows 身份下 font-off 直接报 macOS 位串，font-on 只报 9/55 的稀疏伪 Windows 位串，缺 Segoe UI/Calibri/Consolas/Tahoma/Times New Roman。**B**
8. **Canvas 改写顺带打坏了 `measureText`**：开着 canvas 改写时，`measureText` 只返回宽度的小数部分（如 `-0.0016` / `-3.4e-5`），任何**页面加载后**再做字体探测的第三方脚本都会得到“55 个字体全命中”的不可能结果；`--disable-spoofing=canvas` 才恢复真实 `647.75390625`。**B**
9. 公开官方口径确认：Stripe 用 `m.stripe.com` 周期上报设备特征+活动指标；3DS2 会向发卡行发 **IP、UA、语言、时区、屏幕尺寸/色深**；设备指纹+IP+邮箱域名可跨商户做多账号判定；“高级风险因子”对模型贡献 36%、IP 12%、邮箱 11%。**A**
10. 对“新设备”的含义：**新指纹 ≠ 新设备**。真正决定“是不是同一台设备”的是服务端 muid/guid/sid + 商家域 `__stripe_mid` +（在支持的浏览器上）httpOnly `m`；指纹只决定“这台设备可不可信”。AnyBrowser 需要同时做：per-Profile 的完整 Stripe 状态隔离/轮换、可靠且可配的屏幕/DPR、平台正确的字体表、以及 IP/时区/语言/邮箱的一致性。

---

## 1. 样本清单与限制

| 文件 | 大小 | 内容 | 对本任务的价值 |
|---|---|---|---|
| `/tmp/stripe-recon/signup-capture.json` | 49,637 B | `started/signup/responses/console/analytics`；1 条 400 注册请求、5 条 `r.stripe.com/b`、14 条 console | 真实字段、真实失败、真实时序 |
| `/tmp/stripe-recon/font-off.json` | 1,740 B | 探针输出（ua/uaData/screen/fontBits/fontDetected/canvas `fnv`/loadedTime…），非 Stripe 抓包 | 字体关闭态的一组具体值 |
| 本轮新增 `/tmp/stripe-recon/live-stripe-capture{,2,3}.json`、`live5-*.json`、`headed-capture.json`、`direct-*.json` | — | 自建 CDP 复现：cookie 属性、`/6` 请求与响应、iframe 内部状态、payload | 补抓包空缺 |
| 本轮新增 `/tmp/stripe-recon/p6-*.txt` | 3 份特征帧 + 3 份 `a:null` ping 帧 | 可直接 base64→percent-decode 的 `/6` 请求体 | 逐字段真值 |
| `/tmp/stripe-recon/inner-preview.html`、`inner-preview.headers` | 930 B / 有 CSP | 预览版 inner，与 `inner.html` 字节相同，仅托管在 CloudFront | 加载链证据 |

**已知限制（必须带进结论）**：

1. `signup-capture.json` 的采集脚本（`/tmp/stripe-tools/capture-signup.js:8-12`）只匹配 `sign_up` 与 `r.stripe.com/b` 两类 URL，且 `analytics` 每条被 `slice(0,6000)` 截断；`responses` 是 `signup` 的同一对象副本。
2. 采集未开 `Network.getCookies`/`Network.getAllCookies`，也没有 `requestWillBeSentExtraInfo`，所以 `Origin`、`Cookie`、`Sec-Fetch-*`、`Accept-Language` 都不在样本里。
3. 采集在第一个 400 的 `loadingFinished` 就 `finish()`（`capture-signup.js:30-31`）；console 里第二次 400（重复提交）没有 body。
4. `font-off.json` 只有一份，没有同环境的 font-on 对照；其 `platform=MacIntel`、`languages=[en-US,en]`、`screen=800,600`、`tz=-8/Los_Angeles` 与引擎探针 `mac-seed66666-*.json` 同构。它是**探针**，`canvas.fnv` 是自写 FNV-1a，不是 Stripe 的 md5。

---

## 2. 真实注册流还原

### 2.1 时序（相对 `started=2026-11-21T19:13:34.859Z`）

| 相对时间 | 事件（`analytics` 的 `event_name`，UTC `created`） |
|---|---|
| +25.78 s | `link_app_loaded`；`link_app_rtk_query_request_initiated`；`link_app_rtk_query_get_app_config_start`；`link_app_page_viewed` |
| +26.57 s | `link_app_rtk_query_successful_request_duration_ms`；`link_app_rtk_query_get_app_config_success` |
| +27.34 s | `link_app_web_vitals_lcp` |
| +45.02 s | `link_app_execute_hcaptcha_success` |
| +45.50 s | `link_app_network_lookup_consumer_account_success` |
| +52.44 s | `link_app_login_or_signup_action` ×2；`link_app_user_clear_data_state`；`link_app_rtk_query_request_initiated`；`link_app_rtk_query_sign_up_start` |
| +52.44 s | `POST https://api.stripe.com/v1/consumers/accounts/sign_up`（`ts=2026-11-21T19:14:27.303Z`） |
| +53.77 s | `link_app_rtk_query_request_failed`（同条事件尾部 `status_class:"4xx","duration":1338`） |

- 页面是 `https://app.link.com/login`（console 的 `url` 字段）；`Referer: https://app.link.com/`。
- 所有 analytics 上报都是 `POST https://r.stripe.com/b`，`client_id=link-app`、`num_requests=5`，事件公共字段：`cid/lsid=30c473ec-…`、`sid=58a4e9f2-…`、`page=/login`、`domain=app.link.com`、`viewport_width=2560`、`viewport_height=1289`、`analytics_session_id=a7718574-…`、`page_view_id=f5e22e67-…`、`privacy_consent_*=true`、`ua_*=Chrome/Mac OS/10.15.7/Macintosh/Apple/Blink/148.0.0.0`。每条上报的事件数被截断，末条 `events` 原文可见 5 条中的 2–3 条。
- **时序含义**：hCaptcha 在 45.0 s 结束、注册在 52.4 s 才发出，中间有 7.4 s 人类停顿；注册失败后 `user_clear_data_state` 被触发。对“像人”的判断，这一段没有任何问题；真正可疑的是字段组合（§2.2）与屏幕（§5）。

### 2.2 `sign_up` 请求解剖

`POST https://api.stripe.com/v1/consumers/accounts/sign_up`，`Content-Type: application/x-www-form-urlencoded;charset=UTF-8`，5,581 B：

| 参数 | 值 | 备注 |
|---|---|---|
| `request_surface` | `web_link_app` | Link 自有前端 |
| `key` | `pk_live_51NWD1VCPi23tj6BC5UBwDgzKKF9ti0BMqa0C2ecj6PuHoA5mSUmzq5D1O6h37CRmqW5vhDphv1gHTVBWHlaAtXta00Up1GjGgG` | Link 的 live key |
| `email_address` | `d2@huawei.green` | 非主流邮箱，域名年龄/信誉会被 Radar 用到 |
| `phone_number` | `+15126691515` | US |
| `country` | `US` | `country_inferring_method=PHONE_NUMBER` |
| `locale` | **`ko-KR`** | 与 US 号码、`en-US` 浏览器语言都不同轴 |
| `consent_action` | `entered_phone_number` | |
| `managed_payments_enabled` | `false` | |
| `hcaptcha_response` | 4,908 B，`P1_` + JWT | claims：`pd:0`、`kr:4b004cce`、`shard_id:221996073`、`exp` = 请求后 +112 s |
| `hcaptcha_key` | 295 B，`E1_` + 自定义 base64 | |
| `legal_name` | `aili` | 全小写 |

### 2.3 响应

- `400`，body：`{"error":{"message":"Signup is not available at this time (target_service: consumer-auth-grpc)","type":"invalid_request_error"}}`（149 B）。
- 响应头：`request-id: req_DNZ7g1wn5nVke3`、`original-request` 同值、`idempotency-key: cf57abec-3013-485e-bfa7-57bbee9071af`、`stripe-version: 2022-11-15`、`stripe-should-retry: false`、`x-wc: 3c3`、CSP `report-to q.stripe.com`。**没有 `Set-Cookie`**。
- `target_service: consumer-auth-grpc` 说明失败点在 Stripe 内部的 consumer-auth 服务，而不是本端字段校验；同一会话重复提交再次 400（console 第二条 error），与请求本身无关。
- 该 400 不是“被识别为指纹浏览器”的证据，只是一次服务端暂不可用；但字段与环境值仍被完整接收，可用于后续判断。

### 2.4 请求头与自洽性

已抓到的头：`sec-ch-ua-platform:"macOS"`、`sec-ch-ua:"Chromium";v="148", "Google Chrome";v="148", "Not/A)Brand";v="99"`、`sec-ch-ua-mobile:"?0"`、`User-Agent: …Macintosh…Chrome/148.0.0.0…`、`accept: application/json`、`Referer: https://app.link.com/`。

- UA/UA-CH/平台三条互相一致（macOS + Chrome 148 + 非移动）。
- `Origin`、`Accept-Language`、`Sec-Fetch-*` 缺失是采集限制，不能据此说请求没带。
- 真实 `/6` 的完整头（本轮实测，`direct-headless.json`）包含 `origin: https://m.stripe.network`、`referer: https://m.stripe.network/`、`sec-fetch-site: cross-site`、`sec-fetch-mode: cors`、`sec-fetch-storage-access: none`。注意 **`--lang` 不改 `Accept-Language`**：只传 `--lang=en-US` 时实际头是系统 `zh-CN,zh;q=0.9`；仓库二者都传（`Profile.swift:371-373`）才自洽。

### 2.5 该抓包里的标识符

- `cid=lsid=30c473ec-650f-42e3-b5d6-5f0a507c8b56`（Link 自己的匿名客户端 ID），`sid=58a4e9f2-…`（Link 会话），`page_view_id/event_id` 均为独立 UUID。
- `cid` 通过 analytics 上报；第二轮复现确认这些来自 `cid` cookie（`.app.link.com`，91 天）与 `lsid` localStorage。它们不进 `__stripe_*`，但能把“同一浏览器里的多次 Link 访问”串起来。

### 2.6 页面形态

`viewport_width=2560, viewport_height=1289`。headless 下宿主同样是 2560 宽，但 `screen` 会是 `800×600`（§5）；headed 下 `screen=2560×1440@2`。单凭样本无法断定当时是 headed 还是 headless；两种情况的结论见 §5。

---

## 3. 断链补全：本机 CDP 复现

### 3.1 方法

- 可执行文件：`/Users/riba2534/airepo/anybrowser/dist/AnyBrowser.app/Contents/Frameworks/Chromium.app/Contents/MacOS/Chromium`（`--version` → `Chromium 148.0.7778.215`）。
- 每次全新 `--user-data-dir`，`--fingerprint=<seed> --fingerprint-platform=macos|windows --fingerprint-brand=Chrome --fingerprint-brand-version=148.0.0.0 --fingerprint-hardware-concurrency=8 --lang=en-US --accept-lang=en-US,en --timezone=America/Los_Angeles`；headless 用 `--headless=new`，headed 用 `--window-size/--window-position`。
- CDP `Target.setAutoAttach(flatten)` + `Network.enable`，对 `m.stripe.network` OOPIF 单独 attach；重载 inner-preview 以捕获迟到的 `/6`。
- 脚本在 `/tmp/stripe-plan-v2-tools/`（`capture-live*.py`、`reload-sticky.py`、`direct-inner.py`、`measure-test.py`、`screen-test.py`）。

### 3.2 Cookie 实测（同一页面，`live5-*` 与 `headed-capture.json`）

| Cookie | 域 | 值形态 | 期限（相对现在） | 属性 | 写入者 |
|---|---|---|---|---|---|
| `__stripe_mid` | `.app.link.com` | `31b78dec-4d1f-413d-99bc-e5330140438643bab2`（UUID+6hex=42） | **365 天**（`1826911927-1795375927=31536000`） | `Secure; SameSite=Strict; Path=/;` HttpOnly=**false**，priority Medium | Stripe.js v3 MidSidManager（商家页 JS） |
| `__stripe_sid` | `.app.link.com` | `551626ba-…`（42） | **1800 s** | 同上 | 同上 |
| `cid` | `.app.link.com` | UUID | 91 天 | `Secure; SameSite=Lax` | Link 前端 |
| `__Secure-sid` | `.link.com` | UUID | 30 min | `Secure; SameSite=Lax` | Link 前端 |
| `__cf_bm` | `.hcaptcha.com` | CF bot 值 | 30 min | `HttpOnly; Secure; SameSite=None` + **`partitionKey:{topLevelSite:"https://link.com",hasCrossSiteAncestor:true}`（CHIPS）** | hCaptcha |
| `m` | `.m.stripe.com` | **未出现** | 官方表称 2 年（A） | 未观测 | 服务端（推断） |

其余存储：`localStorage["lsid"]=cid`、`link_app_color_scheme_preference`、`link_app_theme`；inner iframe 的 `sessionStorage`：`1=1`、`_ab=false`、`_mf=<55 位字体串>`、`id=<md5>`。`document.cookie` 在 `m.stripe.network` 为空（跨站），在 `app.link.com` 可见两个 `__stripe_*`。

**`m` 缺失的复核**：直接顶层加载 `https://m.stripe.network/inner.html#version=6`（headed 与 headless 各一次），`/4` 与 `/6` 响应均为 `200` 且**无 `Set-Cookie`**，`content-length` 156/36，`Storage.getCookies` 为空。当前 Chromium 148 默认把这次请求当三方且 `sec-fetch-storage-access: none`；因此官方 cookie 表里的 `m` 在这套引擎上**很可能根本不会落地**（推断：与服务端/3P 策略相关，换 Chrome 版本或开 3P 可能不同）。

### 3.3 muid 是服务端签发，不是本地生成

- 在 inner 的 hash 里显式带 `muid=AAAA…(42)&sid=BBBB…(42)`：`/6` payload 的 `b.d/b.e` 如实带上 AAAA/BBBB，但 **200 响应里的 `window.StripeM.__sid` 仍是全新 muid**：`{"muid":"15614d2d-85ad-4353-b130-4fe0dd21a091d63dbb","guid":"a5f9ff73-…","sid":"043fdc64-…"}`。
- 同一 profile 同一 tab 内 `Page.reload`：`__stripe_mid/__stripe_sid` 值不变，inner 状态返回**同一 muid**。
- 新进程启动（同一 user-data-dir）：`__stripe_mid` 若还在，会继续用；若被清/未落盘，则新 muid。**结论：muid 的连续性 = 商家域 cookie 的连续性；`m` 只是服务端侧的额外锚点。**
- `guid` 与 `__stripe_mid`/`muid` 不同，长度更长（UUID + 18 hex），是响应里的第二标识；`__stripe_sid` 与 `sid` 相同。

### 3.4 `/6` 报文真值

三组 seed 各抓到两帧：**先**一帧含 15 特征（~3.2 KB，`b.n`≈1056–1090，`t`=175–290 ms），**后**一帧 `a:null`（~1096 B，`b.n`≈196–198，`t`≈3.4 ms）。两帧字面 `v2` 都是 `1`，社区所称 “v2:1/v2:2” 是按形态而不是按字面值；`h` 每次不同。编码为 **`base64(percentEncode(JSON))`**（`mod-29.js:20-31` 只负责 POST）。特征帧的 `a` 逐字段真值（`p6-macos-on-828282-1.txt` 解码）：

```
a.a="true" a.b="false" a.c="en-US,en" a.d="MacIntel"
a.e="PDF Viewer,internal-pdf-viewer,application/pdf,pdf++text/pdf,pdf, … WebKit built-in PDF,…" (368 B)
a.f="800w_600h_24d_1r" a.g="-8" a.h="false"
a.i="sessionStorage-enabled, localStorage-enabled"
a.j="1100111100000000100110111100000000000011001000010111111"
a.k="" a.l="Mozilla/5.0 (Macintosh; …) Chrome/148.0.0.0 Safari/537.36"
a.m="" a.n="false" a.o="c3945196869473aa61b650db333dad3e"
t: a/b/c/f/g/k/l/m=0–0.1 ms, a.j=33.1 (at 7.2), a.n=21.9 (at 0.3), **a.e=244.5 ms**, a.o=9.4
b: a="" b=<加盐哈希 URL 分区> c=<加盐 sha256 title> d="NA"/muid e="NA"/sid f=false g=true h=true i=["location"] j=[] n=<performance.now>
w="<epoch-ms>:<sha256(random+now+1)>" h="<20 hex>"
```

- `t` 是逐特征耗时；**`a.e`（plugins 枚举）在本机耗时 174–252 ms**，而真实 Chrome 通常亚毫秒。三组样本都出现同一量级，是可直接探测的引擎性能特征。
- `b.i=["location"]`、`b.j=[]` 表示 `Object.keys(document/navigator)` 干净，没有页面注入痕迹。
- 响应体 156 B，下次填充 `__sid`；**首帧 `b.d/b.e` 是 `NA`**，说明无 muid 时由服务端发新。
- `a.f` 直接来自 `screen.width/height/colorDepth/devicePixelRatio`；`a.g` 来自时区偏移。

---

## 4. `font-off.json` 与字体开关差异

### 4.1 它是什么

`font-off.json` 是探针页用与 Stripe `FontsExtractor` 相同的算法（55 个 `<name, category>`、`72px`、`mmmmmmmmmmlli`、mono 用 `sans-serif` 对比、其余用 `monospace`，见 `mod-18.js:54-110,129-166`）算出的结果。字段与 `/tmp/stripe-re-20261122/engine-probe/*` 一致。**它不是一次 Stripe 抓包，也不含 md5**（`canvas.fnv` 是自写 FNV-1a）。

### 4.2 解码

- `fontBits` 55 位，23 个 `1`，逐一对应列表后与 `fontDetected` **完全相等**（无缺无多）：Andale Mono、Arial Black、Arial Narrow、Arial Rounded MT Bold、Arial Unicode MS、Arial、Comic Sans MS、Courier New、Courier、Georgia、Helvetica Neue、Helvetica、Impact、Microsoft Sans Serif、Monaco、Palatino、Tahoma、Times New Roman、Times、Trebuchet MS、Verdana、Wingdings 3、Wingdings。
- 这就是本机 macOS 的原生命中集。`platform=MacIntel`、`languages=[en-US,en]`、`screen=800×600@1`、`intlTz=America/Los_Angeles`、`canvas={len:21050, fnv:8beeefc}`、`loadedTime=42.7`。

### 4.3 三组真实 `/6` 的 `a.j`

| 身份 / 字体 | `a.j`（55 位） | 命中数 | 命中集特征 |
|---|---|---|---|
| macOS / font-on（seed 828282） | `11001111 00000000 10011011 11000000 …` = 宿主原生 | 23 | 有 Helvetica/Monaco，正常 |
| macOS / font-off（seed 828282） | 与上者**完全相同** | 23 | macOS 身份下开关无差异 |
| macOS / font-on（seed 939393 二次加载） | `…10011001…`（1 位变化） | 23 | 同一 seed 跨加载可抖 1 位（sessionStorage 缓存后稳定） |
| Windows / font-off（seed 737373） | `11001111 00000000 10011011 11000000 …`（宿主 macOS） | 23 | 有 Helvetica Neue/Helvetica/Monaco → 与 `Win32` 矛盾 |
| Windows / font-on（seed 737373） | `00000001 00000000 00011001 10000000 …00000110` | **9** | Arial、Courier、Courier New、Helvetica Neue、Helvetica、Microsoft Sans Serif、Palatino Linotype、Verdana、Wingdings 3；**缺 Segoe UI/Segoe UI Semibold/Segoe UI Symbol/Calibri/Cambria/Consolas/Tahoma/Times New Roman/MS Gothic**，真实 Windows 不会缺这些 |

### 4.4 canvas 改写的 `measureText` 副作用（重要新发现）

开着 canvas 改写时，独立复算（`measure-test.py`，`--fingerprint=123321`）：

```
首次调用：Arial 72px -> 0.0016065086995094052    （正常应为 647.75390625）
monospace       -> 0.0013975971747319542
toDataURL 后再测、换新 canvas 再测 -> 仍是小数部分，且同串稳定
```

即引擎把宽度换成了**带 seed 的小数尾数**。后果：任何一个字体检测里 `base !== measured` 都成立，**55 个字体全部被判定为存在**。Stripe 自己因为是脚本早期测量（拿到的是真实值），`_mf`/`a.j` 仍是 23 位；但页面加载后第三方再测就得到 `111…111`。关闭 canvas 改写后恢复 `647.75390625` 真值。

- 同一个 seed 在不同 profile 里产生**完全相同的 15 特征与 `id`**（例如两套 profile 均为 `id=016a48e7e5056afc8a99fc73674f8ba5`）；`a.o` 也相同。**新 Profile 必须换 seed**，否则服务端看到的是同一台设备。
- `_mf`、`id` 的缓存都在 `m.stripe.network` 的 sessionStorage，新 Profile 天然为空。

---

## 5. 屏幕 / DPR 实测

| 场景 | `screen` | `devicePixelRatio` | `innerWidth×innerHeight` | 自洽？ |
|---|---|---|---|---|
| headless 默认 | `800×600`（avail 同） | 1 | `756×435`（默认窗口） | 是，但 800×600 极罕见 |
| headless `--window-size=1400,900` | `800×600` | 1 | `1400×779` | **否：内容比屏幕宽 600 px** |
| 真实抓包 | 未知 | 未知 | `2560×1289` | 若 headless 则否 |
| headed 默认 | **`2560×1440`**（avail `2560×1410`） | **2** | `1200×1245`（默认窗口） | 是 |
| headed + `--fingerprint-screen-width=1280 --fingerprint-screen-height=720` | `2560×1440` | 2 | `1200×1245` | **参数不生效** |
| headless + `--fingerprint-device-scale-factor=2` | 仍然 800×600 | **1** | — | 参数不生效 |
| `--force-device-scale-factor=2` | `400×300` | 2 | `500×254` | DPR 变，但 screen 只是 800÷2 |
| `--force-device-scale-factor=1.25` | `640×480` | 1.25 | `596×315` | 同上 |

- 开关字符串确实在二进制里（offset 226227466/491/517），但消费逻辑没生效（推断：该 fork 把 screen 仿真留在未完成的 feature 后面）。
- 宿主是 5120×2880、UI 2560×1440@2（`system_profiler`）。headed 的值是**宿主真实值**，会随显示器/缩放/合盖变化；headless 是**固定值**。
- `IdentitySampler.screenSpoofingSupported = false`（`IdentitySampler.swift:131`），采样生成的 Profile 根本不带屏幕字段；`Profile.swift:377-384` 即使有值也会传参，但引擎不认。
- `colorDepth` 恒 24；sRGB 真实设备可能 24，这点不矛盾；`a.f` 会把它当 `24d` 上报。

**对“新设备”的含义**：`a.f` 是 15 个特征之一并参与 `id`，且 3DS2 明确把屏幕尺寸/色深发给发卡行（A）。800×600 或“视口比屏幕大”都是极低概率组合；同一 Profile 换显示器还会让 `a.f`（进而 `id`）漂移。

---

## 6. 外部资料复核

### 6.1 官方：采集什么、怎么发

`docs.stripe.com/disputes/prevention/advanced-fraud-detection`（A）：

> “Stripe.js and the mobile SDKs provide advanced fraud detection by looking at risk factors about device characteristics and user activity … The risk factors are transmitted to Stripe’s back end by periodically making requests to the `m.stripe.com` endpoint.”

> “Device characteristics are risk factors about a customer’s browser, screen, or device. … Combinations of these parameters that are rare or unlikely to reflect a real user’s computing environment can expose fraudulent transactions.”

> “On each page where you load Stripe.js, it can load hCaptcha.”

> “Risk factors corresponding to user activity are scoped to a single shopping session on a single site or app and aren’t linked across different shopping sessions, sites, or apps.”

> “disabling advanced fraud detection doesn’t affect … basic device information collected during 3D Secure 2 authentication (we’re required to send this information to the issuing bank for their risk analysis).”

对应的 3DS2 明细（A，`support.stripe.com/questions/3d-secure-2-device-information`）：网页端是 **IP、UA、浏览器语言、时区、屏幕尺寸与色深**；只采集“核心 ID 与环境信息”，不采广告 ID/定位。

- 与本文实测吻合：`a.c/a.d/a.f/a.g/a.l` 正是语言/平台/屏幕/时区/UA；`b` 里是 URL/标题哈希与 muid/sid。
- 注意：官方说的是“浏览器、屏幕或设备”，本版本没有 WebGL/Audio/字体外的硬件读取（§6.4）。

### 6.2 Cookie / 标识生命周期（A）

`stripe.com/cookie-settings` 表格原文：

| Cookie | 域 | 期限 | 用途 |
|---|---|---|---|
| `m` | `.m.stripe.com` | **2 年** | “For fraud detection. Helps Stripe assess the risk associated with an attempted transaction…” |
| `__stripe_mid` | `.checkout.stripe.com, .onelink.com, request` | **1 年** | 反欺诈设备标识 |
| `__stripe_sid` | 同上 | **30 min** | 反欺诈会话标识 |
| `machine_identifier` / `private_machine_identifier` | `.stripe.com` | 1 年 | Dashboard 设备识别（另一个域族） |

官方 iOS 源码（A）：`SIDLifetime: TimeInterval = 30 * 60`，过期即 `sid = nil`；`muid`、`guid` 持久化在 `UserDefaults`、`reset()` 时一并清空。Android（A）请求体 `b.d=muid`、`b.e=sid`，`a.c/a.d/a.f/a.g` 与本文件同构。

- 实测值（42 字符、365 天、1800 秒、Strict）与官方 1 年/30 min 完全一致；官方表列的是 `checkout.stripe.com/onelink.com`，实测在 `app.link.com` 同样成立（域由当前商家决定）。**推断**：`__stripe_mid/__stripe_sid` 是 v3 在“当前商家域”写的，任何商家域都会有。
- `m` 在官方表里是跨商户锚点，但在本引擎上是三方且不落地（§3.2）。

### 6.3 Radar 如何用这些信号（A）

- 多账号滥用博客（2026-05-27，`stripe.com/blog/expanding-stripe-radar-to-protect-more-of-your-business`）：新账号实时评估，信号来自“**设备指纹、IP 地址、邮箱域名**等 Stripe 网络全域历史”；一处欺诈会把**同一 IP 与设备指纹**在其它支付方式上标记。
- ML 指南（A）：明确举“设备时间与 UTC 的差”作为有效特征；用发卡国、支付 IP、卡历史上出现过的 IP、卡在多少国家成功过等。
- Radar Session（A）：`createRadarSession()` 快照包含 IP、browser、screen/device 信息，用于服务端 tokenization 场景关联设备。
- 风险因子贡献（A，`docs.stripe.com/radar/optimize-risk-factors`）：**高级风险因子 36%**、IP 12%、邮箱 11%、姓名 3%、账单地址 1%。这是“优先级排序”的官方依据：设备特征最重要，但 IP+邮箱合计 23%，且卡/账户历史无法靠单次指纹伪造。

### 6.4 第三方说法 vs 本文实测

- `abroad-hub.net/.../stripe-adyen-browser-fingerprinting-deep-dive-gpu-entropy`（D，无数据）：称 Stripe 用 Canvas、OffscreenCanvas、WebGL、`Math.tan(-1e300)`、AudioContext、事件循环时序、HTTP/2 头推断 OS 等。
  - 与本版本白盒/实测冲突：`out-4.5.45.js` 的 15 特征里**没有 WebGL/OffscreenCanvas/Math 精度/AudioContext/事件循环**；`k`（GraphicsConfiguration）恒空。它是“Stripe 整体面”而非单文件结论，直接照它调 WebGL/Audio 对本文件无用；但 3DS2/其它 Stripe 面确实会读屏幕、语言、时区（§6.1），所以方向不完全错。
  - 其“anti-detect 浏览器模拟不了 C++ 层”的判断值得保留：本机实测的 screen/字体/`measureText` 问题正是引擎层，不是 JS 注入层。
- `multiaccountops.com/.../2026-multi-account-playbook...`（D，但可操作）：数据中心代理被 Stripe 风控“heavily flagged”；建议住宅/ISP 代理、粘性会话、fraud score < 30（> 75 很可能触发）；账号/IP/设备/Profile 1:1；Gmail 别名被视为同一邮箱；同 IP 的 Dashboard 登录会被视为关联。适用于卖家账号，消费者支付同理。
- `Probabilities/Stripe-Reverse`（C）：证实 `base64(percent(JSON))`、`v2/tag/src/a/b/h` 与 `a` 下 15 项；未给 cookie/生命周期。`crhywun` HAR 文档（C）：一单 4 次注册 + 2 次心跳，`v2:1`（`a=null`）/`v2:2`/`mouse-timings-10` 变体，`Cookie: m=<guid>`、`Origin: https://m.stripe.network`、42 字符服务端 ID 写回。本文的三组实测与这些形态一致。

---

## 7. “新设备要成功”的外部约束

> 这一节只写有来源或实测支撑的约束；未验证的写“推断”。

### 7.1 IP（官方权重 12%，多账号信号之一）

- 住宅 > ISP > 数据中心；数据中心段被重点标记（多账号文章）。要“新设备”，**一个 Profile 至少一个粘性出口 IP**，不能多 Profile 共享；同一 Profile 也不要频繁换国。
- IP 国、时区、语言必须同轴：ML 指南把“设备时间与 UTC 差”列为特征；3DS2 直接把时区/语言发卡行。IP 在美国而 `intlTz=America/Los_Angeles` 是自洽的；IP 在德国而 tz 在 LA 会被看见。
- 优先与卡 BIN 国一致；官方模型用“发卡国 / 卡历史 IP / 卡在多少国家用过”。

### 7.2 邮箱

- 官方权重 11%，多账号判定直接用“邮箱域名”。同一域名的批量新号、一次性邮箱、`+alias` 都被合并（多账号文章：Gmail 别名被当同一邮箱）。
- 抓包用 `d2@huawei.green`：注意 `huawei.green` 不是常见消费邮箱域，注册时的信誉与后续可达性都要单独评估（推断：可能看起来像自建域）。

### 7.3 卡与 BIN

- `card.fingerprint` 只在商户账户内可比（A，Cards API），跨商户的复用由 Radar 网络特征处理；卡国与 IP 国不一致、卡在多个国家成功过都是特征（A）。
- 同一张卡给多个“新设备”付款，会把这些设备通过卡历史捆在一起；要“全新”，卡也应是新卡/新 BIN（推断）。

### 7.4 时序与活动

- 活动指标只限单站单会话（A），包含鼠标轨迹、每页停留、卡号是粘贴还是键入（A）。抓包的 25.8 s 加载→45.0 s hCaptcha→52.4 s 提交，节奏正常；注册失败 1.3 s 返回。
- 机器人特征：直线/瞬移鼠标、零停留、`paste` 卡号。**逐字键入、在表单停 5–20 s、有滚动/焦点切换**更稳（推断）。
- hCaptcha 出现在 Link 流程里（实测 `link_app_execute_hcaptcha_success` + `js.hcaptcha.com`），token 112 s 过期；hCaptcha 自身的风险分会并入。

### 7.5 语言 / 时区 / 区域

- 抓包是 `locale=ko-KR` + US 号码 + `en-US` 浏览器。三种可能：(a) 用户界面确实是韩语；(b) Link 记忆了旧 locale；(c) 随机。无论哪种，**时区要跟着 IP**，语言至少与 `Accept-Language`、`navigator.languages` 一致。
- 本引擎 `--lang`/`--accept-lang` 只影响浏览器与请求头，`locale` 是 Link 自己的字段；`ko-KR` 不会自动带出韩语 tz。

### 7.6 会话/账号 1:1

- 同一浏览器标签里先登 A 再登 B 会把 `cid/lsid`、`__stripe_mid` 串起来；要新设备就新 Profile。新 Profile 还要同时换 seed（否则指纹 id 相同）、换 IP、换邮箱、换卡。

---

## 8. 对 AnyBrowser 的硬含义（按优先级）

| # | 事实 | 对“像一台新设备”的意义 | AnyBrowser 应该做 |
|---|---|---|---|
| 1 | muid 服务端签发、存在**商家域** `__stripe_mid`；`m` 本环境不落地 | 只换 seed 不清状态：服务端原样返还旧 muid，新 Profile 也是老设备 | 新建/重置时对**所有访问过的商家域**（不只 stripe.com）清 `__stripe_mid/__stripe_sid`；同时清 `m.stripe.com`、`m.stripe.network`、`.link.com`、hCaptcha 分区 cookie 与 storage；`__stripe_mid` 非 HttpOnly，可用 CDP `Network.deleteCookies` 按名字全域/带 `partitionKey` 删 |
| 2 | headless screen=800×600、headed=宿主；两个指纹开关失效 | `a.f` 不可控；`innerWidth>screen.width` 是低概率组合；换显示器会漂移 | 先修引擎 screen/DPR（或至少禁止 headless 用于 Stripe，并把窗口限制在 screen 内）；`a.f` 纳入自检 |
| 3 | Windows 身份字体矛盾（font-off=mac 集；font-on=9/55 伪集，缺 Segoe UI） | 字体是 `id` 与 3DS2 环境的一部分；`Win32`+Helvetica/Monaco 是可命中的矛盾 | 给引擎补 per-platform 字体表；未补前 Windows 身份默认开 font 并把"缺 Segoe UI"列为已知风险；macOS 身份开/关均可 |
| 4 | canvas 改写使 `measureText` 只返回小数 | 第三方字体探测得到 55/55；与 Stripe 自己的 23/55 不一致 | 修 `measureText` 返回真值+微扰；或对 `canvas` 改写做开关并按 site 策略决定 |
| 5 | 同一 seed 跨 Profile 产生相同 15 特征 | 复制 Profile/复用 seed = 同一指纹设备 | 每个新 Profile 生成唯一 seed；克隆时强制换 seed；轮换 seed 时同步清 `_mf/_ab/id` |
| 6 | `a.e` plugins 枚举 174–252 ms | 亚毫秒级探针可命中，且参与 `t` 序列 | 记录基线；必要时在引擎侧预热或缓存 plugins 枚举 |
| 7 | 抓包字段组合（US 号码 + ko-KR + 全小写名 + 自建域邮箱） | 各自不致命，叠加降低可信度 | 新建身份时用同一 geo 的号码/地址/语言/时区；姓名按正常大小写；locale 跟随 IP 国 |
| 8 | `b.i=[location]/b.j=[]` | 引擎 C++ 改写未留 JS 痕迹，是优势 | 继续避免页面注入；任何注入都会改变 `b.j` |
| 9 | 3DS2 一定发屏幕/语言/时区/UA/IP | 即使关闭 advancedFraudSignals，3DS 仍会暴露 | 把 3DS 也纳入一致性测试；不要以为关掉指纹就完事 |

---

## 9. 未验证 / 开放问题

1. **`m` cookie 为什么完全没有**：可能是 Chromium 148 的三方 cookie 策略、`sec-fetch-storage-access: none`，也可能服务端只对特定客户端下发。需要在真实 macOS Chrome（非本引擎）上复测，确认 AnyBrowser 是否天然缺这一环、以及开 3P/Storage Access 后是否会补上。
2. **推**：`__stripe_mid` 是否真的按“当前商家域”写入而非固定 `.checkout.stripe.com`。本机 app.link.com 已证实；其他商家域只有 v3 源码里的域参数证据，缺一个真实商家页抓包。
3. `m` 的 HttpOnly/Partitioned 属性：本轮无 Set-Cookie，未观测。
4. 15 特征的 `t` 分布（含 `a.e` 200 ms）在真实 Chrome 上的基线，需要一台真机采集对照，才能把“慢”量化成判定阈值。
5. `a.j` 在 macOS 上跨 seed 的 1–2 位抖动是否稳定可重现（同 seed 同 profile 缓存在 sessionStorage 后稳定；跨加载未测）。
6. 抓包 400 的 `consumer-auth-grpc` 是否与设备有关：单次无法区分“全局故障”与“风控降级”；需要多次跨设备复现。
7. 屏幕能否用 `--force-device-scale-factor` 拼出常见分辨率（如 2560×1440@1 需要 factor 0.3125；未验证非整数 factor 的渲染副作用）。

---

## 10. 证据索引

- 抓包：`/tmp/stripe-recon/signup-capture.json`（`signup`/`responses`/`analytics`）、`/tmp/stripe-recon/font-off.json`
- 本轮实测：`/tmp/stripe-recon/live-stripe-capture3.json`、`live5-on-828282.json`、`live5-off-828282.json`、`live5-windows-{on,off}-737373.json`、`live5-macos-on-747474.json`、`headed-capture.json`、`direct-headless.json`、`direct-headed.json`、`p6-*.txt`（特征帧/ping 帧成对）
- 复现脚本：`/tmp/stripe-plan-v2-tools/*.py`
- 代码：`mod-18.js:54-110,129-166`（字体）、`mod-29.js:20-31`（POST/withCredentials）、`mod-06.js:85-100,142-149`（b.d/e 取 hash muid/sid）、`mod-16.js:15-17`（cookieEnabled）
- 源码：`Sources/AnyBrowserCore/IdentitySampler.swift:131`、`Sources/AnyBrowserCore/Profile.swift:377-384`
- 官方：advanced-fraud-detection、cookie-settings、3d-secure-2-device-information、radar-session、optimize-risk-factors、radar 多账号博客、ML 指南、stripe-ios `FraudDetectionData.swift`、stripe-android `FraudDetectionDataRequestParamsFactory.kt`
- 第三方：`github.com/Probabilities/Stripe-Reverse`、`github.com/crhywun/gpt-subscribe-studio-1/blob/main/docs/plus-har-protocol.md`、`abroad-hub.net/.../gpu-entropy`、`multiaccountops.com/.../2026-multi-account-playbook...`
