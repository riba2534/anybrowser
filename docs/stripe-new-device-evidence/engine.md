# 引擎能力与硬缺口（二进制取证）— AnyBrowser Fingerprint Chromium 148.0.7778.215

对象：`/Applications/AnyBrowser.app/Contents/Frameworks/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework`
（250,125,008 B，arm64 Mach-O dylib，`__TEXT` fileoff=0/vmaddr=0 → **文件偏移 == 虚拟地址**；`__text` 0x4000–0xCFE51C4）

方法：`grep -a -o -b` 取偏移 → `dd|xxd` 看上下文 → `llvm-objdump --macho -d --stop-address` 反汇编 → 实机探针（headless/窗口化，本地自报页面）。**未执行目标 JS**。探针产物 `/tmp/stripe-plan-v2/out/report_*.json`，脚本 `/tmp/stripe-plan-v2/{run.sh,run2.sh,run3.sh,server.py,site/}`。

> 结论一句话：**引擎 148 把“能改的”做得相当扎实（UA/UA-CH/平台/CPU/时区/语言/WebGL/Canvas/Audio 全部是真 C++ patch、seed 稳定），但屏幕/DPR/colorDepth 与 location 的四个开关是死字符串；字体系统有平台表却因“宽度合成”缺陷让 Segoe UI/Calibri 永远测不出来；默认品牌还会让 UA 与 UA-CH 自相矛盾。前者必须改引擎，后者可先靠启动参数与预设规避。**

---

## 1. 全部 `--fingerprint-*` / `--disable-spoofing` 开关（含证据与消费者）

开关名以 NUL 分隔集中在 **文件偏移 226,227,277 – 226,227,661**（字面量池前缀垃圾字节 `j7f`，见 `226227277` 的 `xxd`）。逐项核对“是否被代码引用”：全量反汇编里对所有 `adrp …, 0xd7bf000` 的下一跳 `add` 偏移做统计（`LC_ALL=C grep -A1 'adrp.*0xd7bf000' /tmp/fontfn.txt`）。

| 开关 | 偏移（hex / dec） | 引用次数 | 结论 |
|---|---|---|---|
| `fingerprinting-client-rects-noise` | 0xD7BF34D / 226227277 | 0（作为字符串；gate 比较常量在 0x93A9360） | Blink feature 名 |
| `fingerprinting-canvas-measuretext-noise` | 0xD7BF36D / 226227309 | 0 | Blink feature 名 |
| `fingerprinting-canvas-image-data-noise` | 0xD7BF391 / 226227345 | 0 | Blink feature 名 |
| **`fingerprint`** | 0xD7BF4C1 / 226227393 | **30** | seed，`base::StringToInt` |
| **`fingerprint-brand`** | 0xD7BF4CD / 226227405 | **6** | 品牌，值 `chrome/edge/opera/vivaldi` |
| **`fingerprint-brand-version`** | 0xD7BF4DF / 226227423 | **6** | 品牌完整版本 |
| **`disable-spoofing`** | 0xD7BF4F9 / 226227449 | **26** | 逗号列表，子串匹配 |
| `fingerprint-screen-width` | 0xD7BF50A / 226227466 | **0** | **死开关** |
| `fingerprint-screen-height` | 0xD7BF523 / 226227491 | **0** | **死开关** |
| `fingerprint-device-scale-factor` | 0xD7BF53D / 226227517 | **0** | **死开关** |
| **`fingerprint-hardware-concurrency`** | 0xD7BF55D / 226227549 | **2** | 生效 |
| **`fingerprint-platform`** | 0xD7BF57E / 226227582 | **13** | 生效（`windows`/`linux`/`macos`） |
| **`fingerprint-platform-version`** | 0xD7BF593 / 226227603 | **2** | 生效 |
| `fingerprint-location` | 0xD7BF5B0 / 226227632 | **0** | **死开关** |
| **`timezone`** | 0xD7BF5CD / 226227661 | **6** | 生效 |

解析函数（全部在浏览器进程，读 `base::CommandLine` 单例 `[0xECAB000+0x48]`）：

- `0x14D85A0`–`0x14D8904`：`fingerprint-platform-version` → `fingerprint(seed)` → `windows` 时强写 platformVersion `"19.0.0"`；`linux`/`macos` 时用 seed 选内核/系统版本（`seed&1` 查 2 项表 `0xE758CF0`；`seed%25` 查 25 项表 `0xE758D00`，字符串池 `0xDAA2160`–`0xDAA22F6`）。
- `0x14D8908`–`0x14D8B1C`：`fingerprint`、默认品牌 `"Google Chrome"`（`0xDAA22B7`）、`fingerprint-brand`、`fingerprint-brand-version`。
- `0x14D9270` 段 / `0x14DA694` 段：平台与品牌的二次校验；`0x14D848C` 是按 `.` 截断版本号的 helper。
- `0x14D8B20` 段：`fingerprint`→品牌默认版本表（4 项，`0xE758CD0` → `148.0.7778.{97,168,179,217}`），再解析 `fingerprint-hardware-concurrency`。

`--disable-spoofing` 的解析是**对整串做子串搜索**（`memchr` + 11 字节比较 `"clientrects"` 于 `0x93A9340-0x93A9384`；4 字节 `"font"` 比较于 `0xA12806C`），合法值 `font,audio,canvas,clientrects,gpu`。

四种 gate 语义均为“**列到就关**”，默认**全开**（只要带 `--fingerprint`）：

| 能力 | 关闭判定点 | 关闭后运行时结果 |
|---|---|---|
| clientrects | `0x93A92EC`/`0x93A9340` | 无可见差异（见 §7） |
| font | `0xA127FD4`/`0xA12806C` | 返回真实 macOS 字体表 |
| canvas | `0xB00B178`、`0xBBEAA68`（比较 `"canvas"`，`0xDC4E0EB6`） | 各 seed 得到同一真实 canvas |
| audio | 同型 gate（`0x4F9` 消费者之一） | 与 seed 无关的基线值 |

`--disable-non-proxied-udp` 在 148 **不存在**（`grep -a -o -F` = 0）；只有 `--webrtc-ip-handling-policy`（2 次）与策略值 `disable_non_proxied_udp`（3 次）。

---

## 2. 屏幕 / DPR / colorDepth

**屏幕三项开关是死字符串**，已双重证明：

1. 全量反汇编中 `0xD7BF000` 页只被引用这些偏移：`0x4C1 0x4CD 0x4DF 0x4F9 0x55D 0x57E 0x593 0x5C5 …`，**没有 0x50A/0x523/0x53D/0x5B0**。
2. 实机（同一 seed 66666、Windows 身份）：

| 场景 | 参数 | `screen` 实测 |
|---|---|---|
| headless=new | `--fingerprint-screen-width=1920 --fingerprint-screen-height=1080 --fingerprint-device-scale-factor=1.25` | **800×600, avail 800×600, colorDepth 24, DPR 1**（`out/report_winA.json`） |
| headless=new | 同上但 3840×2160、DPR 2 | 仍 **800×600@1**（`out/report_winB.json`） |
| 窗口化 | 1920×1080、DPR 1.25 | **2560×1440, avail 2560×1410, colorDepth 24, DPR 2**（真实屏，`out/report_winC.json`） |
| headless=old | 1920×1080、DPR 1 | 仍 **800×600@1**（`out/report_oldh.json`） |
| 参数放到 `--fingerprint` 之前 | 同上 | 仍 800×600@1（`out/report_ordem.json`） |

结论：**`screen.width/height/availWidth/availHeight/colorDepth/devicePixelRatio` 完全由宿主与 headless 默认值决定**：

- headless 恒 `800×600@1, cd=24`；
- 窗口化 = 本机 2560×1440@2，`availHeight` 比 `height` 少 30（macOS 菜单栏）；
- `colorDepth` 恒 24（本机面板就是 24；30 位屏的 Mac 会漏 30 给 Windows 身份）；
- 窗口 `--window-size` 只改 `outer/innerWidth`，不改 `screen.*`。

对一个“新设备”：所有 Profile 的 Stripe `ScreenSizeExtractor`（复用 `availWidth+availHeight+colorDepth+devicePixelRatio`）**在当前机器上完全同值**，Windows 身份拿到 Retina DPR 2 与 1410 的可用高度。这是本任务里最大的**身份级**缺口。

---

## 3. 字体系统：有平台表，但合成宽度有缺陷

实现（全部在 `blink::FontCache::GetFontPlatformData` 的 fork 版，**0xA127F00–0xA1332D8**）：

- 入口先查 `--fingerprint`，再查 `--disable-spoofing` 是否含 `font`（`0xA127FD4` / `0xA12806C`，常量 `0x746E6F66`）。
- 命中后读 `--fingerprint-platform`，在 `0xA128A10`（表构造器）里按 `windows` / `macos` / `linux` 三分支内联拼串：
  - **Windows**：`0xA128AC4` 起，63 项。首项 `"Arial"`（`0xDC8C2A9`）+ 别名前缀块 `0xDEA6CD2`–`0xDEA6D2C`（`Helvetica Neue`…`Segoe UI`、`BlinkMacSystemFont`）+ 表 `0xDEA6D2D`（`Arial Black`、`Bahnschrift`、…、`Segoe UI Variable`、`SimSun`、`Tahoma`、`Times New Roman`、`Verdana`、`Webdings`、`Wingdings`、`Yu Gothic`）。关键项：`Segoe UI` 在 0xDEA6D11，`Calibri` 在 0xDC9D4AD，`Tahoma` 在 0xDEA6EC5。
  - **macOS**：`0xA129B68` 起，543 项，表首 `0xDEA6F84`（`Academy Engraved LET`…`Zapfino`）。**无 Segoe/Calibri/Consolas**（`grep -c = 0`）；`Helvetica`/`Monaco` 在自身段内，`Tahoma`/`Verdana` 复用前缀块（`0xDEA6EC5` / `0xDEA6C1A`）。
  - **Linux**：`0xA1329C0` 起，35 项，表首 `0xDEA8C4D`（`Ubuntu`…`FreeMono`）。
- 另有 25 项“通用/别名”数组（`-webkit-standard`,`system-ui`,`Arial`,`Calibri`,`Courier New`,`Courier`,`Helvetica`,`Helvetica Neue`,`Lucida Grande`,`Microsoft Sans Serif`,`MS Sans Serif`,`MS Serif`,`MS UI Gothic`,`Roboto`,`Sans`,`Segoe UI`,`Times New Roman`,`Times`,generic 族,`BlinkMacSystemFont`）在 `0xA1287B4-0xA128944` 静态构造。

**运行时缺陷**（40 个 seed、Windows 身份、字体伪装全开，`out/report_u*.json` + `out/report_raw*.json`）：

| 字体 | 40 次中出现 | 说明 |
|---|---|---|
| Arial / Courier / Courier New / Helvetica / Helvetica Neue / Microsoft Sans Serif | **40/40** | 恒定“存在” |
| Trebuchet MS 17、Segoe UI Symbol 16、Lucida Sans Unicode 15、Verdana 14 | 随机 | |
| Tahoma 12、Consolas 11、Times New Roman **4** | 随机 | |
| **Segoe UI** | **0/40** | 表格里有，却永远测不出 |
| **Calibri** | **0/40** | 同上 |

机制证据（`out/report_raw*.json`）：引擎把 `measureText` 返回值整体替换成 seed 相关的微小值（本机 Chrome 基线是 563–759 **px**，引擎是 `-0.003…+0.003` 量级）。Stripe 用“候选字体宽度 vs 三个 generic 基线”比较，而：

- 三个基线（monospace/sans-serif/serif）在引擎里**恒等**（`out/report_mm1.json`：`base` 六次采样全为同一值）；
- `Segoe UI`/`Calibri` 的合成宽度**每次都等于基线**（seed 100003/100004/100005/100006 均相等，`out/report_raw*.json`），因此位串永远是 0；
- `Tahoma`/`Verdana` 只因 seed 偶尔给出不同宽度才偶尔为 1。

即：**Windows 身份的字体位串必然缺 Segoe UI 与 Calibri，且大多数 Windows 字体随机缺失**。这是 Stripe `FontsExtractor` 一眼能看出的“假 Windows”。

关闭字体伪装（`--disable-spoofing=font`）时：返回真实 macOS 可测字体 23 项（`out/report_nofont.json`），与官方 Chrome 158 在本机的结果**逐项相同**（`out/report_chromebase.json`）。所以字体开关本身是对的，坏的是合成算法。

---

## 4. UA / UA-CH / 品牌

- 平台映射真实存在于 `0x95BA1E0-0x95BA350`：`windows→Win32`（`0xDE79342`）、`linux→Linux x86_64`（`0xDE79348`）、`macos→MacIntel`（`0xDE79355`）；同时驱动 `navigator.platform`、UA 串与 `Sec-CH-UA-Platform`。
- 品牌表 `0xDAA2176-0xDAA22F6`：`Microsoft Edge`/` Edg/`/` OPR/`/` Vivaldi/`/`Google Chrome`，配完整版本池。实测 `--fingerprint-brand=Edge --fingerprint-brand-version=148.0.3967.83`：UA 追加 ` Edg/148.0.3967.83`，UA-CH `brands` 含 `Microsoft Edge`，`fullVersionList` 同时给 `Chromium 148.0.7778.217` 与 `Microsoft Edge 148.0.3967.83`（`out/report_edged.json`）——**多品牌合成正确**。
- `architecture` 随平台 `x86`/`arm`，`bitness` 恒 64，`model` 恒空（桌面 Chrome 也空）。
- **默认品牌缺陷**：不传 `--fingerprint-brand` 时 UA 串仍是 `Chrome/148.0.0.0`，但 UA-CH 只有 `Not/A)Brand;v=99` + `Chromium;v=148`，**没有 Google Chrome**（`out/report_headwin.json`、`headmac.json`）。真实 Chrome 必有 `Google Chrome`。修法只需默认 `Google Chrome`。
- GREASE 值 `Not/A)Brand;v=99` 与 148 真机一致；本机 Chrome 158 已换成 `Not.A/Brand;v=24`（`out/report_chromebase.json`）——跟版本走是对的，但升到 150+ 时必须同步。
- `Sec-CH-UA-Platform-Version` 在 JS 侧是 `19.0.0`（Win11 24H2）/`10.0.0`/`15.0.0–26.4.1`/`6.8.0`/`6.14.0`，与平台版本一致。

---

## 5. hardwareConcurrency / deviceMemory

- `--fingerprint-hardware-concurrency=4` 实测生效（`out/report_hw.json` cores=4）。
- 不传时由 seed 派生：seed 12345→24、23456→16、34567→8、66666→12（`out/report_nf*.json`、`headwin`），宿主是 18 核。池为 `{8,12,16,24}` 一类合理值，非宿主值。
- `navigator.deviceMemory` = `[8,16,32][seed % 3]`：66666%3=0→8、55555/66667→16、77777→32（`out/report_wins*.json`、`audio2.json`）。**注意旧结论“32 不可能”已过时**：本机 Chrome 158 在 128 GiB 机器上就报 32（`out/report_chromebase.json`），所以 8/16/32 是合规值，只缺显式开关。

---

## 6. WebRTC / 时区 / 语言 / 插件 / 其他

- **WebRTC**：`webrtc-ip-handling-policy` 存在，`disable_non_proxied_udp` 值存在；仓库已在 `Profile.swift` 传该策略。探针环境下 **ICE 一个 candidate 都没有**（`out/report_ice*.json`，连 stock Chrome 也一样），所以本机无法用运行时验证泄漏，只能标“策略已接线、需在开启本地网络权限后复测”。
- **时区**：`--timezone=Asia/Tokyo` → `Intl` 与 `Date.getTimezoneOffset()` 均 +9（`out/report_ja.json`），与宿主无关。
- **语言**：`--lang` + `--accept-lang` 正确产出 `navigator.language(s)=ja-JP,[ja-JP,ja,en-US,en]`；但 ICU 默认 locale 仍是宿主 `zh-CN`，`Date` 串显示中文区名。补 `-AppleLanguages <array><string>ja-JP</string></array>` 后 **窗口化** 得到 `locale=ja`、区名 `日本標準時`（`out/report_jaw.json`）。**headless 下 `-AppleLanguages` 会触发 “Multiple targets are not supported in headless mode”**（`out/ja2.log`）——所以自检不能用 headless 跑带语言的 Profile。
- **插件/MIME/DNT/cookie/Object.keys**：与官方 Chrome 158 完全一致——5 个 `internal-pdf-viewer` PDF 插件、mimeTypes=2、DNT=null、cookieEnabled=true、`Object.keys(navigator)=[]`、`Object.keys(document)=["location"]`（`out/report_plugE.json` vs `plugC.json`）。这是 C++ patch 的强项，不要改成 JS 注入。
- **canvas**：同 seed 跨 2 次独立加载 SHA-256 完全相同、不同 seed 不同；`--disable-spoofing=canvas` 后跨 seed 又恒等（`out/report_h66666-*.json`、`cvoff*.json`）。符合“seed 稳定”的要求。
- **audio**：同位 seed 稳定、跨 seed 微变（317.01567609 vs 317.01547896），关闭后回到与 seed 无关的基线；与 Chrome 基线 317.01548156 相差 ~6e-7（`out/report_audio*.json`）。
- **clientRects**：`100.3px` 元素返回 `100.296875`，与 Chrome 逐位相同，关闭开关也无可见差异（`out/report_ggpu*.json`、`grect.json`）。Stripe 不采此项。
- **WebGL**：`gpu` 开→`ANGLE (NVIDIA, … RTX 3060 Laptop …, D3D11)`；`gpu` 关→真实 `ANGLE Metal Renderer: Apple M5 Max`；macOS 身份→伪造 `Apple M4`（`out/report_ggpu*.json`）。Linux 身份在仓库里被强制 `--disable-spoofing=gpu`，即 **Linux Profile 永远露真实 Apple GPU**（`Profile.swift:387-389`）。

---

## 7. 版本可疑点（148 vs 150 vs Stable 159）

| 项 | 事实 |
|---|---|
| 引擎 | 148.0.7778.215（2026-06-21） |
| 上游 fork 最新 | 150.0.7871.186（2026-10-02） |
| 本机 Chrome | 158.0.8127.37 |
| 当前 Mac Stable | **159.0.8154.13**（chromiumdash，2026-11-18） |

- 差 11 个大版本；`Sec-CH-UA` 与 `navigator.userAgentData` 会自报 148。Stripe 可按流量分布直接算版本年龄。
- 两端已有差异：Chrome 158 的 GREASE 是 `Not.A/Brand;v=24`，148 是 `Not/A)Brand;v=99`；150+ 的 `--disable-non-proxied-udp`、新 CH（`formFactors` 等）148 没有。
- 148 的 `--disable-spoofing` 语义（只关不调、无逐项参数）在 150 可能变化，升级必须重测 §1 全部开关。
- `Object.keys` 基线当前与 Chrome 158 一致，但 11 个版本间新增 API 随时可能打破，升级前后都要做官方同版本 diff。

---

## 8. 结论矩阵：必须改引擎 vs 可先绕过

| 缺口 | Stripe 可见 | 能否用启动参数绕过 | 最小补丁面 |
|---|---|---|---|
| screen.width/height/avail/colorDepth | 是（payload f） | **否**（开关是死的） | 给已解析的 settings 结构加 4 字段 + 渲染进程 `Screen` getter（`core/frame/screen.cc`）与 `Window::devicePixelRatio`；并在 headless 语义下不要回落到 800×600 |
| devicePixelRatio | 是（payload f） | **否** | 同上（`core/frame/window.cc`） |
| Segoe UI/Calibri 永不可测 | 是（payload j 位串） | 部分：只能整体关字体 | `platform/fonts/font_cache.cc` 的合成宽度：让表中每一项都产生与三 generic 均不同的稳定宽度，而不是回落基线 |
| Windows 字体大量随机缺失 | 是 | 同上 | 同上；建议“表内全量 + seed 只扰动宽度” |
| 默认品牌无 Google Chrome | 是（UA-CH + 头） | 是（预设/参数写 `Chrome`） | `components/embedder_support/user_agent_utils.cc` 默认值；或 App 层强制非 nil |
| deviceMemory 无开关 | 次要 | 否 | `navigator_device_memory.cc` 加 `--fingerprint-device-memory` |
| screen 与窗口物理矛盾 | 次要 | 否 | 见上；另做上限校验 |
| WebRTC 真实 IP（UDP） | 是（其他 SDK） | 是（仓库已在传策略） | 默认值改为 `disable_non_proxied_udp` |
| Linux 露真实 GPU | 是 | 否（引擎无 Linux WebGL 值） | 补 Linux GPU 池 |
| 148 版本年龄 | 是 | 只能升级 | 升级管线 |
| 长语言列表/ICU | 间接 | 是（`-AppleLanguages`，仅窗口化） | headless 解析单破折号参数 |

**对“看起来像一台新设备”的含义**：当前引擎能让两个 Profile 的 canvas/audio/WebGL/CPU/时区/语言互不相同且各自稳定；但**屏幕与 DPR 在所有 Profile 上同一个值、Windows 身份的字体位串必缺 Segoe UI/Calibri**。Stripe 只要把 `f`（屏幕）与 `j`（字体）与平台交叉比对，就能把“Windows 设备”认成“同一台 Mac 上的伪装”。在这两项修好之前，Windows/Linux 预设只能算“实验性”，macOS 身份则最接近真实。

---

## 9. 可复跑证据

```bash
B="/Applications/AnyBrowser.app/Contents/Frameworks/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework"

# 开关簇（含死开关）
grep -a -o -b -E '[A-Za-z0-9_-]*fingerprint[A-Za-z0-9_-]*' "$B"
dd if="$B" bs=1 skip=226227150 count=900 2>/dev/null | xxd -c 32

# 死开关证明（应无 0x50a/0x523/0x53d）
xcrun llvm-objdump --macho -d --no-show-raw-insn "$B" > /tmp/text.txt   # 约 1.5 GB
LC_ALL=C grep -A1 'adrp.*0xd7bf000' /tmp/text.txt | grep -oE '#0x[0-9a-f]+' | sort | uniq -c

# 字体 gate 与平台表
xcrun llvm-objdump --macho -d --no-show-raw-insn --stop-address=0xa133300 "$B" | grep -A2 -E 'a127fd4:|a128ac4:|a129b68:|a1329c0:'

# 运行时复现
/tmp/stripe-plan-v2/run3.sh win 18081 --headless=new --fingerprint=66666 --fingerprint-platform=windows --disable-spoofing=
python3 -c 'import json;d=json.load(open("/tmp/stripe-plan-v2/out/report_win.json"));print(d["screen"],d["fontDetected"],d["uaData"])'
```
