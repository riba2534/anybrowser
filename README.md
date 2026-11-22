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
| **多身份并行** | 每个 Profile 是一套独立身份：浏览器资料、指纹和代理各自独立，可同时运行，单独停止或重启。Passkey Box 全局账号里的通行密钥对所有使用它的 Profile 可见，需要彻底分开时给 Profile 单独设置账号。 |
| **指纹配置** | 可编辑平台、浏览器品牌及其版本、逻辑 CPU 数、语言、时区和种子。字体、音频、Canvas、元素坐标和 WebGL 参数可按项控制。 |
| **身份模板与一致性检查** | 一键套用「Windows 11 · Chrome」「macOS 26 · Chrome」等自洽组合。编辑时提示品牌版本超过内核、平台版本不匹配、时区或语言与代理出口不一致等问题。 |
| **按字段随机生成** | 勾选需要变化的字段并预览结果。平台与平台版本、品牌与品牌版本会一起保持匹配。保存后，每次启动使用同一份配置。 |
| **独立代理** | 每个 Profile 可设置 HTTP、HTTPS 或 SOCKS5 代理，默认使用本机的 `127.0.0.1:7890`。三种代理都可以带账号密码，无痕窗口和自动化新建的上下文同样经过代理。启动前检查代理能否连通，可一键检测出口 IP 并按出口填写时区和语言。 |
| **通行密钥** | 每个 Profile 默认加载 Passkey Box 并自动登录，使用全局账号或 Profile 自己的账号，不用通行密钥的 Profile 可以关闭。网站请求通行密钥时直接完成注册或登录，不需要点击确认；登录只自动使用本 Profile 注册或用过的通行密钥，其他情况出现选择框。 |
| **Profile 管理** | 搜索（支持 `tag:`、`status:`、`group:`）、分组、标签、按最近启动排序；多选后批量启动、停止、设置代理、分组、标签和状态，平铺窗口；批量新建时每个 Profile 从代理库取自己的代理；移除先进回收站；完整备份和恢复登录状态。 |
| **启动选项** | 每个 Profile 可设置启动网址、窗口大小与位置，以及额外加载的扩展目录。 |
| **Cookie 迁移** | 运行中的 Profile 可导出或导入 Cookie。导出为 Cookie-Editor 和 EditThisCookie 能导入的 JSON，含分区 Cookie；导入还接受 DevTools、Playwright 的 JSON（包括 `{"cookies": [...]}` 包装）和 Netscape cookies.txt。 |
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

在「代理」卡片里填写地址。默认的 `127.0.0.1:7890` 按 HTTP 代理连接，适用于开放相应端口的 Mihomo 设置。也可填入完整的代理地址，例如 `socks5://127.0.0.1:7891`（`socks5h://` 相同，域名都交给代理解析），或带账号密码的 `http://user:pass@proxy.example.com:8080`（账号密码中的特殊字符用百分号编码）。代理商常用的 `主机:端口:用户名:密码` 可以直接粘贴。留空时使用系统网络设置。

- HTTP、HTTPS 和 SOCKS5 代理都可以带账号密码。内核的 `--proxy-server` 不支持账号密码，AnyBrowser 为这样的 Profile 启动一个本机代理中继（`AnyBrowserRelay`）：它只监听 `127.0.0.1` 的随机端口，浏览器经它联网，由它登录代理，账号密码不出现在任何进程的启动参数里。普通窗口、无痕窗口，以及 Playwright `newContext()`、Puppeteer `createBrowserContext()` 新建的上下文都经过中继。中继随浏览器一起退出；AnyBrowser 退出后浏览器照常联网，重新打开 AnyBrowser 会接管它们。
- 中继端口和调试端口一样没有认证，本机任何程序都能经它使用这个代理。
- 启动时 AnyBrowser 先检查代理能否连通；带账号密码时还经中继确认代理接受这组账号密码。有问题会提示，浏览器照常启动。
- 「检测」经该 Profile 的代理查询出口 IP、所在地和时区，依次使用 ipinfo.io、ipapi.co、ipwho.is 和 get.geojs.io，前一个失败时换下一个；请求只带通用的请求头，不含 AnyBrowser 的名字、系统语言和 macOS 版本。「按出口 IP 填写时区和语言」把查到的时区和常用语言填进指纹。新建 Profile、批量新建和重新生成身份时也会自动查询一次出口。

### 使用 Passkey Box

点击左下角的「Passkey Box」或菜单「Passkey Box 账号…」（⌘,），填写服务器地址（默认 `https://password.riba2534.cn`）、用户名和密码，保存前会向服务器验证账号。之后启动的每个 Profile 都会用这个账号自动登录内置扩展，这个账号里的通行密钥对所有使用它的 Profile 可见。需要让某个 Profile 使用别的身份时，在它的「Passkey Box 身份」卡片里选择「此 Profile 单独使用账号」并填写账号。

网站发起通行密钥注册或登录时，扩展直接用服务器上的密钥完成，不弹出设备验证或确认窗口。登录时扩展只自动使用在本 Profile 注册或用过的通行密钥。本 Profile 没用过这个网站的通行密钥（例如它是另一个 Profile 注册的），或用过多个时，页面右上角会出现账号选择框，选过一次后下次自动使用。这样共用账号的 Profile 打开登录页时，不会静默登录成另一个 Profile 的网站账号。

修改账号后，正在运行的 Profile 重启后生效。移除全局账号后，之后启动的 Profile 不再自动登录，扩展保留它上次登录的账号，自动登录的规则不变。扩展经该 Profile 的代理访问服务器，连不上时会在页面上提示。

不用通行密钥的 Profile 可以在「启动选项」里关闭「加载 Passkey Box」。之后启动时不加载这个扩展，网页里也就没有它改写过的 WebAuthn 接口；该 Profile 的扩展副本和其中的账号配置随之删除。重新打开后，下次启动时重新复制扩展并写入账号。

AnyBrowser 把内置扩展复制到每个 Profile 的 `Extensions/<UUID>/PasskeyBox/`，账号和自动登录规则写在其中的 `managed-config.json`（仅当前用户可读）。Passkey Box 的账号密码是使用这些通行密钥的唯一凭据，请妥善保管。

### 管理 Profile

- 侧栏顶部可以搜索名称、分组、备注、标签或端口，并按创建顺序、名称或最近启动排序。设置了分组后按分组显示。搜索框里可以写 `tag:标签`、`status:状态`（如 `status:受限`）和 `group:分组`，多个条件同时满足，值含空格时加引号；右侧的筛选按钮可以直接插入这些条件。⌘F 跳到搜索框。
- 侧栏里用 ↑ ↓ 切换 Profile。⌘-点击加入或移出批量选择，⇧-点击连选，⌘A 选中当前列表里的全部 Profile（输入框里的 ⌘A 仍是全选文字）。
- 选中后底部出现批量操作：启动、停止、平铺窗口，「更多」里有设置代理、设为分组、设置标签、账号状态、导出所选（含或不含密码）、完整备份所选和移到回收站。批量启动和停止显示进度，可以取消：正在启动或停止的会完成，其余跳过。设置分组、标签、状态和代理时所选 Profile 一起保存，有一个不合法就都不改。
- 曾经检测过出口的 Profile，侧栏右侧显示出口所在的国家；与其他 Profile 用同一个出口 IP 时出现双人图标，悬停可以看到是哪些 Profile。
- 菜单「Profile」里有启动或重启（⌘R）、停止（⌘.）、复制为新 Profile（⌘D）、平铺窗口、代理库（⇧⌘P）、回收站和资料库检查。
- 标题栏的「…」菜单可以「复制为新 Profile」（新端口、新种子，不复制浏览器资料），以及导出或导入运行中 Profile 的 Cookie。
- 菜单「导入 Profile…」「导出 Profile…」使用 JSON 文件。默认导出不含代理账号密码和 Profile 自己的 Passkey Box 账号；需要完整迁移时用「导出 Profile（含密码）…」。导入时冲突的端口和种子会重新分配，浏览器资料不随之迁移。
- 移除 Profile 默认移到回收站：浏览器资料、端口和身份都保留，30 天内可以在回收站恢复，之后启动 AnyBrowser 时自动永久删除。也可以直接选「永久删除（含浏览器资料）」，立即删除配置和 Chromium 资料，不可恢复。运行中的 Profile 不能移除。
- 数据库里有当前版本读不了的配置（例如由更新版本写入），或 `Profiles/` 下有没有 Profile 使用的资料目录时，侧栏会提示。在「资料库检查」里可以导出那份配置的原始 JSON 或删除它；未关联的资料目录可以沿用它新建一个 Profile（保留目录里的登录状态，端口和身份重新生成），也可以删除。
- 批量新建时，代理来源可以是一个地址，也可以从代理库按顺序或随机不重复地分配，每个 Profile 一条。新建前逐个检测出口（同时最多 4 个），语言和时区与各自的出口对齐；检测失败的会列出来，可以重试，或确认后仍然新建，这些 Profile 的语言和时区为随机值。

### 代理库

菜单「代理库…」或侧栏底部的「代理库」里可以粘贴代理，每行一个，或从文本文件导入；写法与「代理」卡片相同，`主机:端口:用户名:密码` 也可以，无法识别的行会列出来并留在输入框里。每条代理可以设置名称、标签和备注。「检测全部」或「检测所选」经每条代理查询出口，每次 6 条，显示出口所在国家、时区、IP 和耗时，失败时显示原因，并标出有几个 Profile 在用这条代理。

Profile 里保存的仍是代理地址，代理库只是批量新建和批量设置代理时的来源。按顺序分配时优先使用还没有 Profile 用的代理，代理不够时从头重复使用，这些 Profile 会共用出口；随机不重复时代理必须够每个 Profile 一条。代理库和 Profile 配置一起存放在 `profiles.sqlite3`，含代理账号密码。

### 备份与恢复

- 菜单「导出完整备份…」把所选的 Profile（没有选择时为全部）写进一个 `.anybrowser` 文件：配置（含代理和 Passkey Box 账号密码）、全部 Cookie 和浏览器资料（不含缓存），用于换一台 Mac 后保留登录状态。已停止的 Profile 会以无窗口方式短暂启动，读出 Cookie 后停止，再复制浏览器资料；正在运行的 Profile 只备份 Cookie。文件没有加密，请妥善保管。
- 菜单「从完整备份恢复…」可以把 Profile 作为新 Profile 恢复，或保留原来的 ID（已被占用时换新 ID 或跳过）。备份和恢复期间，相关 Profile 不能启动、停止或修改，结束后列出每个 Profile 的结果。
- AnyBrowser 每天和每次升级前自动把 Profile 数据库备份到 `Backups/`，保留最近 10 份。菜单「资料库备份…」列出这些备份，可以立即备份一份、在 Finder 中显示，或恢复其中一份：AnyBrowser 退出，用备份替换数据库后重新打开，替换前的数据库另存为一份备份。恢复前需要先停止所有浏览器并保存或放弃当前编辑；数据库打不开时也可以从这里恢复。

### 启动选项

「启动选项」卡片里可以设置启动网址（每行一个，只支持 http 和 https）、窗口大小与位置，以及额外加载的未打包扩展目录。扩展目录在启动时检查，被删除或移动后会在卡片里标红，启动会提示。

### 共享扩展库

同一个扩展要给多个 Profile 用时，可以把它加进扩展库，再在各个 Profile 里勾选，不必逐个填写扩展目录。扩展库支持两种来源：未打包的扩展文件夹（顶层有 `manifest.json`），以及 CRX3 格式的 `.crx` 文件。文件夹会被复制，CRX 会被解包，放到 `Extensions/Shared/<名称>/`。名称取自扩展自己的名字，只保留英文字母、数字、空格、点、下划线和连字符，重名时加序号。

- Profile 按勾选的顺序加载这些扩展，排在 Profile 自己的扩展目录之前。两处是同一个扩展时，以 Profile 自己的目录为准。
- 扩展库只存放扩展文件。登录状态、钱包等扩展数据保存在各个 Profile 自己的浏览器资料里，Profile 之间不共享。
- 从 CRX 添加时，AnyBrowser 把 CRX 里的公钥写进 `manifest.json`，扩展 ID 与 Chrome 应用商店一致。从文件夹添加的扩展，ID 由它在扩展库里的名称决定。AnyBrowser 不校验 CRX 的签名。
- 扩展库里的扩展不会自动更新。更新时先删除旧版本，再添加新版本。CRX 扩展的 ID 始终不变；文件夹扩展只要名称没变，ID 就不变，各 Profile 里的扩展数据可以继续使用。
- 删除扩展后，仍勾选它的 Profile 启动时会提示，取消勾选或重新添加后才能启动。

### 自动化接口

菜单「自动化接口…」里打开开关后，AnyBrowser 在 `127.0.0.1:50330`（可修改）提供 HTTP API。每个请求都要带 `Authorization: Bearer <访问令牌>`；带 `Origin` 头的请求（来自网页）和 Host 不是本机的请求一律拒绝。访问令牌能读写全部 Profile 配置（加 `?secrets=1` 时包括代理和 Passkey Box 的密码）、删除 Profile 和代理，并启动浏览器。浏览器运行后，它的调试端口本身没有认证，本机任何程序都能通过它完全控制该 Profile（读取 Cookie、执行脚本），请只把令牌和调试地址交给受信的程序。

```bash
TOKEN=<在设置里复制的访问令牌>
API=http://127.0.0.1:50330/api/v1
curl -s -H "Authorization: Bearer $TOKEN" $API/profiles
curl -s -X POST -H "Authorization: Bearer $TOKEN" -d '{"name":"店铺 1","preset":"win11-chrome","proxyFromLibrary":"unused"}' $API/profiles
curl -s -X POST -H "Authorization: Bearer $TOKEN" -d '{"headless":true}' $API/profiles/<id>/start
curl -s -X POST -H "Authorization: Bearer $TOKEN" $API/profiles/<id>/stop
```

#### 命令行工具 anybrowserctl

`anybrowserctl` 封装了上面的接口，随应用打包在 `AnyBrowser.app/Contents/MacOS/anybrowserctl`，可以软链接到 PATH：

```bash
ln -s /Applications/AnyBrowser.app/Contents/MacOS/anybrowserctl /usr/local/bin/anybrowserctl
anybrowserctl list --status running
anybrowserctl create --name 店铺 --preset win11-chrome --proxy-from-library unused
anybrowserctl create --count 5 --prefix 店铺 --group 电商 --proxy-from-library unused
anybrowserctl update 店铺 --tag 美区 --json '{"fingerprint":{"timeZone":"America/New_York"}}'
anybrowserctl start 店铺 --headless --url https://example.com --arg --mute-audio
anybrowserctl cookies export 店铺 --output cookies.json
anybrowserctl cookies import 店铺 cookies.txt
anybrowserctl selfcheck 店铺 --pretty
anybrowserctl proxies add --file proxies.txt
anybrowserctl delete 店铺
```

Profile 可以用 id 或名称指定，重名时须用 id。访问令牌和端口依次取自 `--token`、`--port`，环境变量 `ANYBROWSER_TOKEN`、`ANYBROWSER_PORT`，都没有时只读读取 AnyBrowser 保存的自动化接口设置（数据目录可用 `--data-dir` 或 `ANYBROWSER_DATA_DIR` 指定），所以在本机打开接口后可以直接使用。输出是接口返回的 JSON，加 `--pretty` 缩进显示。出错时在 stderr 输出原因，退出状态为 1（接口返回错误）、2（用法错误）或 3（无法连接或读取设置）。`anybrowserctl help` 列出全部命令和选项。

#### 端点

| 方法与路径 | 说明 |
| --- | --- |
| `GET /api/v1/profiles` | 列出 Profile：`{"profiles":[Profile]}`。`q` 是侧栏搜索（支持 `tag:`、`group:` 和按账号状态筛选的 `status:`），`group` 按完整分组名（空值为未分组），`tag` 按完整标签（可重复，须全部符合），`status` 按运行状态，`accountStatus` 按账号状态（`none` 为未设置） |
| `GET /api/v1/profiles/{id}` | `{"profile":Profile,"config":配置}`；`?secrets=1` 时配置含密码 |
| `POST /api/v1/profiles` | 新建，返回 201 和 `{"profile","config","warnings"}` |
| `POST /api/v1/profiles/batch` | 批量新建 1–50 个，返回 201 和 `{"profiles","warnings"}` |
| `POST /api/v1/profiles/{id}/clone` | 复制（新 id、名称、端口和种子，不复制浏览器资料），请求体可带要改的字段 |
| `PATCH /api/v1/profiles/{id}` | 修改任意字段，返回 `{"profile","config","pendingRestart"}` |
| `DELETE /api/v1/profiles/{id}` | 移到回收站；`?purge=1` 永久删除记录（回收站里的也可以），再加 `&deleteData=1` 同时删除浏览器资料 |
| `GET /api/v1/trash` | 回收站：`{"profiles":[Profile]}`，每项多一个 `deletedAt` |
| `POST /api/v1/profiles/{id}/restore` | 从回收站恢复 |
| `POST /api/v1/profiles/{id}/start` | 启动，请求体可选 `{"headless","urls","args"}`；返回 `{"profile","debug":{"http","webSocket"},"startedFresh","warnings"}`，已在运行时同样返回 |
| `POST /api/v1/profiles/{id}/restart` | 停止后按保存的配置重新启动，请求体同 start |
| `POST /api/v1/profiles/{id}/stop` | 停止，`?force=1` 强制结束；返回 `{"profile"}` |
| `GET /api/v1/profiles/{id}/log` | 本次运行 AnyBrowser 启动它时的浏览器输出：`{"log"}`，没有时为 `null` |
| `GET /api/v1/profiles/{id}/cookies` | 导出 Cookie：`{"cookies":[…],"count","skipped","format","startedHeadless","warnings"}`；`?format=devTools` 改用 DevTools 格式 |
| `POST /api/v1/profiles/{id}/cookies` | 导入 Cookie，请求体是 Cookie 文件本身；返回 `{"imported","skipped","evicted","displaced","summary","startedHeadless","warnings"}` |
| `GET /api/v1/profiles/{id}/selfcheck` | 运行时自检，Profile 须正在运行；返回自检报告 |
| `POST /api/v1/windows/arrange` | 平铺窗口，请求体可选 `{"ids","columns"}`；返回 `{"windows":[{"id","frame","error"}]}` |
| `GET /api/v1/proxies` | 代理库：`{"proxies":[Proxy]}`；`?secrets=1` 时地址含账号密码 |
| `POST /api/v1/proxies` | 添加 `{"text"}`（每行一个，写法同界面里粘贴）或 `{"urls":[…]}`，可带 `label`；返回 `{"added","duplicates","rejected"}` |
| `GET`、`PATCH`、`DELETE /api/v1/proxies/{id}` | 查看、修改（`url`、`label`、`tags`、`note`）或删除一条代理 |
| `POST /api/v1/proxies/check` | 经代理查询出口并记录，请求体可选 `{"ids"}`，默认全部；返回 `{"results":[{"proxy","error"}]}` |

Profile 对象为 `{"id","name","group","port","status","debugReady","tags","accountStatus","pendingRestart"}`。`status` 是浏览器状态，取值 `stopped`、`starting`、`stopping`、`running`、`failed`；`accountStatus` 是记录的账号状态，取值 `active`、`verifying`、`limited`、`banned` 或 `null`；`pendingRestart` 表示浏览器还在用修改前的配置运行。运行中的浏览器报告它启动时用的端口。

`config` 是完整配置，字段与「导出 Profile…」文件里的 Profile 相同：`name`、`port`、`proxy`、`group`、`notes`、`tags`、`accountStatus`、`fingerprint`（`seed`、`platform`、`platformVersion`、`brand`、`brandVersion`、`cpuCount`、`language`、`languages`、`timeZone`、`adjustments` 等）、`launch`（`startURLs`、`window`、`extensionDirectories`、`loadPasskeyBox`、`restoreSession`、`sharedExtensions`）和 `passkeyBox`。默认不含密码：代理只保留 `scheme://主机:端口`，没有 Profile 自己的 Passkey Box 账号。

Proxy 对象为 `{"id","url","hasCredentials","label","tags","note","createdAt","lastExit","lastCheckedAt","profiles"}`，`profiles` 是使用这个代理的 Profile（含回收站中的），时间为 ISO 8601。

错误返回 `{"error":{"code","message"}}`，`message` 是中文原因：

| 状态码 | `code` | 含义 |
| --- | --- | --- |
| 400 | `bad_request`、`invalid_json`、`invalid` | 无法解析的请求、请求体不是 JSON 对象、字段或取值无效（包括拼错的字段名） |
| 401、403 | `unauthorized`、`forbidden_host`、`forbidden_origin` | 令牌错误，或请求不是来自本机程序 |
| 404、405 | `not_found`、`method_not_allowed` | 没有这个接口、Profile 或代理；方法不对时 `Allow` 头列出可用的方法 |
| 409 | `busy`、`running`、`trashed`、`not_running`、`conflict`、`read_only` | 正在执行另一个操作、需要先停止、已在回收站、需要先启动、端口种子或代理地址已被占用、数据库由更新版本写入 |
| 413 | `payload_too_large` | 请求头和请求体合计超过 64 KB |
| 500、503 | `start_failed`、`stop_failed`、`cookies_failed`、`selfcheck_failed` 等；`unavailable` | 操作失败；浏览器在运行但调试端口尚未就绪 |

#### 新建与修改

`POST /api/v1/profiles` 的请求体可以只写要指定的字段，其余按「新建 Profile」的方式生成：名称 `Profile N`、空闲端口、新种子和一套自洽的身份，再按代理出口填写语言和时区（不用代理时按本机），出口查询失败时保持随机并在 `warnings` 里说明。另有三个选项：

- `preset`：身份模板 id，`win11-chrome`、`win11-edge`、`win10-chrome`、`macos27-chrome`、`macos26-chrome`、`macos15-chrome`。
- `proxyFromLibrary`：代理库条目的 id，或 `"unused"`（取第一条没有 Profile 使用的代理）；不能与 `proxy` 同时填写。
- `localeFromExit`：设为 `false` 时不查询出口。`fingerprint` 里写了 `language`、`timeZone` 或 `languages` 时同样不查询。

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" $API/profiles -d '{
  "name": "店铺 1", "group": "电商", "tags": ["美区"], "preset": "win11-chrome",
  "proxy": "us.example.com:8000:user:pass", "launch": {"startURLs": ["https://example.com"]}
}'
```

`POST /api/v1/profiles/batch` 需要 `count`（1–50），可选 `prefix`（默认 `Profile`，名称为 `<前缀> <序号>`）、`preset`、`proxy`、`localeFromExit` 和 `proxyFromLibrary`。批量时 `proxyFromLibrary` 为 `"unused"` 时每个 Profile 分到一条不同的未使用代理，也可以是与 `count` 等长的 id 数组；每个 Profile 按自己代理的出口填写语言和时区，同一个地址只查询一次。请求体里的其他 Profile 字段（如 `group`、`tags`、`notes`、`launch`）应用到每一个，`name`、`port` 和 `fingerprint.seed` 除外。全部成功才保存。

`PATCH` 按 JSON Merge Patch（RFC 7386）合并：对象逐层合并，`null` 删除字段（恢复默认值），其他值直接替换，数组整体替换。所有字段都可以改，包括 `passkeyBox`、`launch.extensionDirectories` 和 `fingerprint`；不认识的字段返回 400。运行中照样保存，浏览器在重启前继续用原来的配置，这时 `pendingRestart` 为 `true`。把不含密码的 `config` 原样改了发回时，与它相同的 `proxy` 视为未修改，已保存的账号密码保留；不用代理请写 `"proxy": ""`。

```bash
curl -s -X PATCH -H "Authorization: Bearer $TOKEN" $API/profiles/<id> -d '{"fingerprint": {"timeZone": "Asia/Tokyo"}, "accountStatus": null}'
```

#### 启动、Cookie 与自检

`start` 和 `restart` 的请求体只对这一次启动生效，不保存，也不算配置修改：`headless` 为 `true` 时不打开窗口（`--headless=new`；内核只把 UA 里的 HeadlessChrome 换成 Chrome，其他无头特征仍在，网站可能识别出来），`urls` 替换这次打开的启动网址（空数组表示不打开），`args` 追加以 `--` 开头的 Chromium 开关（不能包含 `--user-data-dir` 和 `--remote-debugging-*`）。浏览器已在运行时 `start` 不会再次启动，返回的 `warnings` 会说明参数没有生效，需要时用 `restart`。所有启动都经过与界面相同的排队（默认同时启动 3 个），正在启动、停止或删除的 Profile 返回 409。

Cookie 接口在 Profile 未运行时，自动以无头方式启动它，完成后再停止，返回里 `startedHeadless` 为 `true`；这期间对该 Profile 的其他请求返回 409。导出默认是 Cookie-Editor 和 EditThisCookie 能导入的格式，含分区 Cookie；导入接受 Cookie-Editor、EditThisCookie、DevTools、Playwright 的 JSON（包括 `{"cookies": [...]}` 包装）和 Netscape cookies.txt。`evicted` 和 `displaced` 是浏览器因数量上限丢弃的新旧 Cookie 数。一次导入的文件不能超过 64 KB 的请求上限，更大的文件请分批导入。

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$API/profiles/<id>/cookies?format=devTools"
curl -s -X POST -H "Authorization: Bearer $TOKEN" --data-binary @cookies.txt $API/profiles/<id>/cookies
```

自检在运行中的浏览器里开一个后台标签，访问本机回环地址上的测试页，读取平台、品牌与版本、CPU、内存、WebGL、语言、时区、屏幕、Canvas 文本宽度和页面上的 AnyBrowser 标记，与保存的配置和最近一次出口逐项比对，再关闭标签，不访问外部网站。返回 `{"profileID","checkedAt","passed","items":[{"id","title","expected","observed","status","note"}],"observation"}`，`status` 为 `pass`、`fail` 或 `info`（没有可比的值，或内核暂时改不了的项）。

`windows/arrange` 把所选 Profile（默认全部运行中的）的窗口按网格排在主显示器上，`columns` 默认取接近正方形的列数。无窗口运行或未运行的 Profile 不占格子，`error` 说明原因。

#### 接入 Playwright、Puppeteer 与 Selenium

`start` 返回的 `debug.http` 和 `debug.webSocket` 就是内置 Chromium 148 的 DevTools 地址；`GET <debug.http>/json/version` 返回内核版本。[examples/](examples/) 里有三个完整示例：先经接口启动 Profile，再连接并打开一个网页。连接时注意：

- 使用 Profile 自带的默认上下文（Playwright 的 `browser.contexts()[0]`），它带着该 Profile 的 Cookie 和登录状态。Playwright 的 `browser.newContext()`、Puppeteer 的 `browser.createBrowserContext()` 新建的是空白上下文，相当于无痕窗口。
- 断开连接（Playwright 的 `browser.close()`、Puppeteer 的 `browser.disconnect()`、Selenium 的 `driver.quit()`）不会关闭浏览器，Profile 继续运行，需要时调用 `stop`。
- 带账号密码的代理（HTTP、HTTPS、SOCKS5）经 AnyBrowser 的本机代理中继登录，新建的上下文和无痕窗口同样经过它，脚本里不需要再设置代理。

```js
// Playwright（Node.js）
const browser = await chromium.connectOverCDP(started.debug.http);
const context = browser.contexts()[0];
```

```js
// Puppeteer（Node.js）；defaultViewport: null 保持窗口本来的大小，不模拟 800×600 的屏幕
const browser = await puppeteer.connect({ browserWSEndpoint: started.debug.webSocket, defaultViewport: null });
```

```python
# Selenium（Python），需要与内核同为 148 版的 chromedriver，例如 npx @puppeteer/browsers install chromedriver@148
options = webdriver.ChromeOptions()
options.debugger_address = started["debug"]["http"].removeprefix("http://")
driver = webdriver.Chrome(service=Service("/path/to/chromedriver"), options=options)
```

AI Agent 可以先用 `anybrowserctl start <Profile>` 拿到 `debug.http`，再交给 Playwright MCP 的 `--cdp-endpoint` 或 chrome-devtools-mcp 的 `--browserUrl` 接管浏览器。

## 本机数据

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/AnyBrowser/profiles.sqlite3` | Profile 配置（含代理和 Profile 自己的 Passkey Box 账号）、全局 Passkey Box 账号、自动化接口设置、最近启动时间 |
| `~/Library/Application Support/AnyBrowser/Profiles/<UUID>/` | 对应 Profile 的 Chromium 用户资料 |
| `~/Library/Application Support/AnyBrowser/Extensions/<UUID>/` | 对应 Profile 加载的 Passkey Box 副本及账号配置 |

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
