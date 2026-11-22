<p align="center">
  <img src="Resources/AnyBrowser.png" alt="AnyBrowser 标志" width="128" />
</p>

<h1 align="center">AnyBrowser</h1>

<p align="center">
  <strong>面向 Apple Silicon 的 Chromium 多 Profile 工作台</strong><br />
  在一个 macOS 窗口里管理独立浏览器资料、可复现的指纹配置和本机 DevTools 端口。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-12%2B-24292f?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 12 或更新版本" />
  <img src="https://img.shields.io/badge/Apple_Silicon-ARM64-315bdd?style=for-the-badge" alt="Apple Silicon ARM64" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9 或更新版本" />
</p>

<p align="center">
  <a href="#核心能力">核心能力</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#日常使用">日常使用</a> ·
  <a href="#本机数据">本机数据</a> ·
  <a href="#开发与测试">开发与测试</a> ·
  <a href="https://github.com/riba2534/anybrowser/issues">问题反馈</a>
</p>

---

AnyBrowser 是一个原生 macOS 应用。每个 Profile 对应一份 Chromium 资料目录和一组启动参数，可以同时运行。项目将经过校验的 [Fingerprint Chromium](https://github.com/adryfish/fingerprint-chromium) 打进应用包，启动时由 AnyBrowser 选择对应的资料目录和配置。

## 核心能力

| 功能 | 说明 |
| --- | --- |
| **多身份并行** | 每个 Profile 是一套独立身份：浏览器资料、指纹、代理和 Passkey Box 账号各自独立，可同时运行，单独停止或重启。 |
| **指纹配置** | 可编辑平台、浏览器品牌及其版本、逻辑 CPU 数、语言、时区和种子。字体、音频、Canvas、元素坐标和 WebGL 参数可按项控制。 |
| **身份模板与一致性检查** | 一键套用「Windows 11 · Chrome」「macOS 26 · Chrome」等自洽组合。编辑时提示品牌版本超过内核、平台版本不匹配、时区或语言与代理出口不一致等问题。 |
| **按字段随机生成** | 勾选需要变化的字段并预览结果。平台与平台版本、品牌与品牌版本会一起保持匹配。保存后，每次启动使用同一份配置。 |
| **独立代理** | 每个 Profile 可设置 HTTP、HTTPS 或 SOCKS5 代理，默认使用本机的 `127.0.0.1:7890`。HTTP/HTTPS 代理支持账号密码。启动前检查代理能否连通，可一键检测出口 IP 并按出口填写时区和语言。 |
| **通行密钥** | 每个 Profile 默认加载 Passkey Box 并自动登录，使用全局账号或 Profile 自己的账号。网站请求通行密钥时直接完成注册或登录，不需要点击确认。 |
| **Profile 管理** | 搜索、分组、备注、按最近启动排序；⌘-点击多选后批量启动、停止或设置分组；批量新建、复制、导入导出；移除时可选择一并删除浏览器资料。 |
| **启动选项** | 每个 Profile 可设置启动网址、窗口大小与位置，以及额外加载的扩展目录。 |
| **Cookie 迁移** | 运行中的 Profile 可导出或导入 Cookie（JSON，兼容 Cookie-Editor 的导出格式）。 |
| **自动化接口** | 本机 HTTP API 列出、启动、停止 Profile，并返回 DevTools 地址，便于 Playwright 或 Puppeteer 连接。默认关闭，需要访问令牌。 |
| **本机调试** | 每个 Profile 分配一个独立的回环端口，建议从 9222 开始，也可自行修改。端口就绪后可以复制连接地址。 |

## 快速开始

需要 **Apple Silicon Mac 和 macOS 12+**。可以下载 [GitHub Release](https://github.com/riba2534/anybrowser/releases/latest) 的 ARM64 安装包。安装包只有 ad-hoc 签名，没有经过 Apple 公证，首次打开时：

1. 解压后先把 `AnyBrowser.app` 移到「应用程序」文件夹（`/Applications`）再打开。在「下载」等位置直接打开时，macOS 会把它放到随机的只读路径运行。
2. 被 macOS 拦下时，到「系统设置 → 隐私与安全性」点击「仍要打开」。macOS 15 起，右键「打开」已不能放行。
3. 也可以在终端去掉下载带来的隔离属性，之后正常打开：`xattr -dr com.apple.quarantine /Applications/AnyBrowser.app`。

自行构建需要 Swift 5.9+。只装了 Command Line Tools 时，构建脚本会自动选择能编译 SwiftUI 的 SDK。

```bash
git clone https://github.com/riba2534/anybrowser.git
cd anybrowser
./scripts/build-app.sh
open dist/AnyBrowser.app
```

首次构建会下载并校验固定版本的引擎和扩展，随后复用本地缓存。构建产物 `dist/AnyBrowser.app` 内置 [Fingerprint Chromium 148.0.7778.215](https://github.com/adryfish/fingerprint-chromium/releases/tag/148.0.7778.215) 和 [Passkey Box v0.4.0](https://github.com/riba2534/passkey-box/releases/tag/v0.4.0)，采用本机 ad-hoc 签名。自己构建的应用没有隔离属性，可以直接打开。

## 日常使用

1. 点击左侧「新建 Profile」，输入名称和端口。也可以用菜单「批量新建 Profile…」（⇧⌘N）一次建多个。
2. 套用「身份模板」，或手动编辑指纹，或通过「随机生成」勾选要变化的字段，再查看预览。
3. 点击「保存并启动」。调试就绪后，可复制类似 `http://127.0.0.1:9222` 的 DevTools 地址。
4. 编辑正在运行的 Profile 后，重启该实例应用新配置，界面会显示「等待重启」。

网页实际读到的内存和 WebGL 参数由内置引擎根据平台与种子决定。未选平台和 Windows、macOS 平台下引擎会改写 WebGL；选 Linux 平台时这版内核不改写 WebGL，网页会读到本机真实显卡，编辑器会对 Linux 身份给出提示。调试端口只监听本机，启动器会校验监听进程和具体的 Profile；端口本身没有认证，本机任何程序都能通过它控制该 Profile，请仅交给受信的本机程序使用。

### 代理

在「代理」卡片里填写地址。默认的 `127.0.0.1:7890` 按 HTTP 代理连接，适用于开放相应端口的 Mihomo 设置。也可填入完整的代理地址，例如 `socks5://127.0.0.1:7891`，或带账号密码的 `http://user:pass@proxy.example.com:8080`（账号密码中的特殊字符用百分号编码）。留空时使用系统网络设置。

- 内核的 `--proxy-server` 不支持账号密码。AnyBrowser 为带账号密码的 HTTP/HTTPS 代理生成一个只属于该 Profile 的小扩展，由它应答代理的认证请求；SOCKS5 代理不支持账号密码。
- 启动时 AnyBrowser 先检查代理能否连通，连不上会提示，浏览器照常启动。
- 「检测」经该 Profile 的代理查询出口 IP、所在地和时区（使用 ipinfo.io，失败时用 ipapi.co）；「按出口 IP 填写时区和语言」把查到的时区和常用语言填进指纹。检测带账号密码的代理和 HTTPS 代理需要 macOS 14 或更新版本。

### 使用 Passkey Box

点击左下角的「Passkey Box」或菜单「Passkey Box 账号…」（⌘,），填写服务器地址（默认 `https://password.riba2534.cn`）、用户名和密码，保存前会向服务器验证账号。之后启动的每个 Profile 都会用这个账号自动登录内置扩展。需要让某个 Profile 使用别的身份时，在它的「Passkey Box 身份」卡片里选择「此 Profile 单独使用账号」并填写账号。

网站发起通行密钥注册或登录时，扩展直接用服务器上的密钥完成，不弹出设备验证或确认窗口。同一网站在这个账号下有多个通行密钥时，扩展优先使用在本 Profile 注册或用过的那个；本 Profile 没用过、或用过多个时，页面右上角会出现账号选择框，选过一次后下次自动使用。

修改账号后，正在运行的 Profile 重启后生效。移除全局账号后，之后启动的 Profile 不再自动登录，扩展保留它上次登录的账号。扩展经该 Profile 的代理访问服务器，连不上时会在页面上提示。

AnyBrowser 把内置扩展复制到每个 Profile 的 `Extensions/<UUID>/PasskeyBox/`，账号写在其中的 `managed-config.json`（仅当前用户可读）。Passkey Box 的账号密码是使用这些通行密钥的唯一凭据，请妥善保管。

### 管理 Profile

- 侧栏顶部可以搜索名称、分组、备注或端口，并按创建顺序、名称或最近启动排序。设置了分组后按分组显示。
- ⌘-点击可以多选，底部出现「启动所选」「停止所选」「设为分组…」。批量启动逐个进行，结束后汇总结果。
- 标题栏的「…」菜单可以「复制为新 Profile」（新端口、新种子，不复制浏览器资料），以及导出或导入运行中 Profile 的 Cookie。
- 菜单「导入 Profile…」「导出 Profile…」使用 JSON 文件。默认导出不含代理账号密码和 Profile 自己的 Passkey Box 账号；需要完整迁移时用「导出 Profile（含密码）…」。导入时冲突的端口和种子会重新分配，浏览器资料不随之迁移。
- 移除 Profile 时可以选「仅移除记录」或「移除并删除浏览器资料」，后者删除该 Profile 的 Chromium 资料和扩展目录，不可恢复。运行中的 Profile 不能移除。

### 启动选项

「启动选项」卡片里可以设置启动网址（每行一个，只支持 http 和 https）、窗口大小与位置，以及额外加载的未打包扩展目录。扩展目录在启动时检查，被删除或移动后会在卡片里标红，启动会提示。

### 自动化接口

菜单「自动化接口…」里打开开关后，AnyBrowser 在 `127.0.0.1:50330`（可修改）提供 HTTP API。每个请求都要带 `Authorization: Bearer <访问令牌>`；带 `Origin` 头的请求（来自网页）和 Host 不是本机的请求一律拒绝。

```bash
TOKEN=<在设置里复制的访问令牌>
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:50330/api/v1/profiles
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:50330/api/v1/profiles/<id>/start
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:50330/api/v1/profiles/<id>/stop
```

| 端点 | 返回 |
| --- | --- |
| `GET /api/v1/profiles` | `{"profiles":[Profile]}` |
| `GET /api/v1/profiles/{id}` | `{"profile":Profile}` |
| `POST /api/v1/profiles/{id}/start` | `{"profile":Profile,"debug":{"http":"http://127.0.0.1:9222","webSocket":"ws://127.0.0.1:9222/devtools/browser/…"}}`，已在运行时同样返回 |
| `POST /api/v1/profiles/{id}/stop` | `{"profile":Profile}` |

访问令牌只控制启动和停止。浏览器运行后，它的本机调试端口本身没有认证，本机任何程序都能通过它完全控制该 Profile（读取 Cookie、执行脚本），请只在受信的电脑上使用，并只把调试地址交给受信的程序。

Profile 对象为 `{"id","name","group","port","status","debugReady"}`，`status` 取值 `stopped`、`starting`、`stopping`、`running`、`failed`。错误返回 `{"error":{"code","message"}}`。启动使用已保存的配置。拿到 `webSocket` 后可以用 Playwright 的 `chromium.connectOverCDP` 或 Puppeteer 的 `connect` 接管浏览器。

## 本机数据

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/AnyBrowser/profiles.sqlite3` | Profile 配置（含代理和 Profile 自己的 Passkey Box 账号）、全局 Passkey Box 账号、自动化接口设置、最近启动时间 |
| `~/Library/Application Support/AnyBrowser/Profiles/<UUID>/` | 对应 Profile 的 Chromium 用户资料 |
| `~/Library/Application Support/AnyBrowser/Extensions/<UUID>/` | 对应 Profile 加载的 Passkey Box 副本及账号配置，以及代理登录扩展 |

以上文件和目录仅当前用户可读。移除 Profile 时选择「仅移除记录」，浏览器资料仍可在上述目录找到。

## 开发与测试

| 目录 | 内容 |
| --- | --- |
| [Sources/AnyBrowser/](Sources/AnyBrowser/) | SwiftUI 界面 |
| [Sources/AnyBrowserCore/](Sources/AnyBrowserCore/) | Profile 存储、参数、浏览器进程管理、代理、Cookie 和自动化接口 |
| [Resources/](Resources/) | Logo、应用元数据和引擎许可 |
| [Tests/](Tests/) | 单元测试和真实浏览器集成测试 |

测试使用 swift-testing，需要 Swift 6 工具链（Xcode 16 或更新版本，或同等版本的 Command Line Tools）。推荐用 `scripts/test.sh` 运行：它执行 `swift test --arch arm64` 并原样传入其余参数（例如 `--filter LibraryTests`）。只装了 Command Line Tools 时，脚本会自动选择能编译 SwiftUI 的 SDK，并为编译器指明 swift-testing 的宏插件目录，否则编译会随机报 `plugin for module 'TestingMacros' not found`。

```bash
./scripts/test.sh
./scripts/test.sh --engine dist/AnyBrowser.app
```

第二条命令把 `ANYBROWSER_TEST_APP` 设为指定的应用，对它运行真实浏览器测试。需要先用 `./scripts/build-app.sh` 构建应用、登录 macOS 图形会话，并预留本机端口 9222、9223 和 9301–9313。它用临时资料目录启动真实浏览器，验证调试端点、代理与代理账号密码、站点存储隔离、Passkey Box 预填地址与 Profile 级账号、启动网址与窗口、额外扩展、Cookie 导入导出，以及通过自动化接口启停，还有重启恢复。

这些端口被占用时（例如自己的 Profile 正开着 9222），或要在多个工作目录里同时运行时，设置 `ANYBROWSER_TEST_PORT_OFFSET`，测试使用的调试端口整体加上这个偏移。例如 `ANYBROWSER_TEST_PORT_OFFSET=1000 ./scripts/test.sh --engine dist/AnyBrowser.app` 改用 10222、10223 和 10301–10313。

若只验证合成指纹的校验流程，可在第二条命令后加 `--filter VerificationFixtureTests`（使用端口 9307、9308）。该用例通过 `127.0.0.1` 上的测试页验证指纹不变、变化、重试和 Profile 隔离；只传入合成值，不读取或修改实际浏览器指纹，也不调用外部校验服务。

再设置 `ANYBROWSER_TEST_PASSKEY_SERVER`、`ANYBROWSER_TEST_PASSKEY_USERNAME`、`ANYBROWSER_TEST_PASSKEY_PASSWORD` 和 `ANYBROWSER_TEST_PASSKEY_RP`（[passkey-box](https://github.com/riba2534/passkey-box) 的 `e2e/rp` 测试网站，例如 `http://localhost:18422`），会额外启动一个带账号的 Profile，在要求用户验证的网站上完成注册和登录，并确认全程没有打开其他窗口。

内置引擎和 Passkey Box 的版本与 SHA-256 统一写在 `scripts/versions.env`，构建脚本从这里读取，单元测试检查 `BundledVersions` 与它一致。`scripts/check-updates.sh` 把它们与上游最新发布对比，并列出 Chrome 稳定版和内核相差几个大版本；已是最新时以 0 退出，有可用更新或内核落后 2 个及以上大版本时以 10 退出，并给出新版本的 SHA-256 和需要修改的文件。CI 在每次推送和 PR 上打包应用，再对这个包跑全部测试（含真实浏览器测试）；推送 `v*` tag 时对即将发布的包跑同样的测试，通过后发布 ZIP 和 `SHA256SUMS`。每周一次的定时任务运行 `check-updates.sh`，有更新时开一个 issue，已有未关闭的同名 issue 时追加评论。

## 贡献

欢迎提交 [Issue](https://github.com/riba2534/anybrowser/issues) 或 Pull Request。反馈运行问题时，请附上 macOS 版本、内置引擎版本、复现步骤和错误信息。

## 致谢与许可

内置引擎来自 [Fingerprint Chromium](https://github.com/adryfish/fingerprint-chromium)，基于 Ungoogled Chromium。BSD 3-Clause 许可随应用包分发，见 [第三方许可](Resources/FingerprintChromium.LICENSE.txt)。[Passkey Box](https://github.com/riba2534/passkey-box) 的 MIT 许可及依赖许可也随包分发。AnyBrowser 源码许可尚未在本仓库声明。
