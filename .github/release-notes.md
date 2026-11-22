## 更新

0.5.0 的重点是 Profile 之间的隔离和日常使用的可靠性。

### Profile 隔离

- **通行密钥不再跨 Profile 自动登录**：内置 Passkey Box 升级到 0.5.0。多个 Profile 共用同一个账号时，扩展只自动使用本 Profile 注册或用过的通行密钥；其他 Profile 的通行密钥先弹出选择框，选过一次后才会自动使用。每个 Profile 可以单独关闭「加载 Passkey Box」。
- **页面上不再有 AnyBrowser 的痕迹**：去掉了每个页面都带的全局标记。Canvas 文本度量改为在 TextMetrics 上修正，`measureText` 本身保持原生。
- **语言不再泄漏本机设置**：Profile 语言改由 `-AppleLanguages` 交给引擎。日期字符串、Worker、iframe 和浏览器界面都跟随 Profile 语言，不再露出这台 Mac 的中文。
- **硬件组合真实存在**：CPU 数按种子对应的显卡和内存选取，不再生成现实中没有的机型。复制、导入 Profile 换种子时，硬件保持不变。
- **版本号真实**：Chrome 和 Edge 的版本由引擎从已发布的版本里选取，Edge 发送精简后的 UA。Windows、Edge、Opera、Vivaldi 身份标为实验性。新增提示：显卡与 CPU 组合不存在、与其他 Profile 共用出口 IP、内核落后稳定版、WebGPU 和语音列表暴露本机等。
- **「整套重新生成」真正换一台设备**：点击后先确认，保存后才清理。清理范围包括全部网站的 Cookie、Storage、HTTP 缓存和 `~/Library/Caches` 下的缓存；运行中的 Profile 在重启时清理。放弃修改则什么都不删。
- **每个 Profile 一个出口**：
  - 新增代理库，可以粘贴或导入代理列表，识别 `host:port:user:pass`、`user:pass@host:port`、`socks5h://` 等写法，并能批量检测出口。
  - 批量新建、批量设置代理时，可以从代理库按顺序或随机分配。
  - 启动时在后台复核出口与时区、语言是否一致，并提示与其他 Profile 共用出口。
- **带密码的代理在所有窗口都可用**：带账号密码的 HTTP、HTTPS、SOCKS5 代理改经本机中继。无痕窗口、Playwright 的 `newContext()` 等所有上下文都能正常认证，SOCKS5 账号密码也已支持。

### 可靠性

- **启动更稳**：先启动浏览器，调试端口就绪后再打开启动网址，修改启动网址不再需要重启。在浏览器里执行 chrome://restart 或从设置页重启后，AnyBrowser 能重新接管这个 Profile。
- **停止与排查**：卡住的浏览器可以强制停止。启动失败时附上退出码和启动日志，可以在界面上查看。端口冲突时指出占用端口的程序。
- **数据更安全**：
  - 数据库有了 schema 版本：升级前自动备份，此后每天再备份一次。
  - 读不懂的配置原样保留，单独列出，可以导出或删除。
  - 由更新版本写入的数据库只读打开，不会被覆盖。
  - 只允许运行一个 AnyBrowser。
- **回收站与备份**：
  - 移除 Profile 默认先进回收站，30 天后自动清理；之前「仅移除记录」留下的资料目录可以重新挂接。
  - 新增完整备份：包含配置、Cookie 和浏览器资料，恢复后可以补回登录态，跨机器也能用。
  - 新增资料库备份的恢复入口。
- **日常操作**：
  - 批量启停可以并发、可以取消，并显示进度。
  - 新增标签和账号状态，搜索支持 `tag:`、`status:`、`group:`。
  - 支持窗口平铺、共享扩展库（文件夹或 CRX），以及恢复上次会话。
  - 窗口菜单显示 Profile 名称。
  - 提示横幅不再随页面滚走。退出前提醒保存未保存的修改；可以还原修改；自动化接口改动了正在编辑的 Profile 时会提示。

### 自动化

- **自动化接口补齐**：新增新建、批量新建、复制、修改、删除（进回收站）、恢复 Profile，带参数启动（无头、指定网址、额外开关）、强制停止、重启、启动日志、Cookie 导入导出、运行时自检、窗口平铺和代理库等端点。
- **命令行**：新增命令行工具 `anybrowserctl`，位于 `AnyBrowser.app/Contents/MacOS/`。README 补充了 Playwright、Puppeteer、Selenium 的接入示例。

### 升级说明

- 首次启动 0.5.0 会升级 Profile 数据库，升级前自动备份到 `~/Library/Application Support/AnyBrowser/Backups/`。
- 升级后，请停止并重新启动正在运行的 Profile，以载入新的启动方式、中继和 Passkey Box 0.5.0。
- **已知限制**：
  - 浏览器自行重启后会丢失语言参数，界面会显示「等待重启」，从 AnyBrowser 重启该 Profile 即可恢复。
  - 同一台 Mac 上的 Profile 仍共享屏幕、字体、语音列表和 WebGPU 等特征，需要等引擎补丁。
  - 内置引擎仍是 Chromium 148，上游没有更新的 macOS 构建。

下载 ARM64 ZIP，解压后把 `AnyBrowser.app` 移到「应用程序」文件夹再打开，并用 `SHA256SUMS` 校验文件。首次打开如被系统拦下，在「系统设置 → 隐私与安全性」中选择「仍要打开」，或执行 `xattr -dr com.apple.quarantine /Applications/AnyBrowser.app`。
