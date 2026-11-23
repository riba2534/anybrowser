## 更新

0.6.0 的主题是「新设备」：让新建的 Profile 在 Stripe / Link 眼里像一台新设备，而不是同一台 Mac 上的另一个配置。

### 设备身份

- **每个 Profile 有自己的设备标识**：新建、整套重新生成、复制、导入、从备份恢复都会得到一个新的 UUIDv4；重启不变。编辑器里能看到它的前 8 位，悬停显示完整值。
- **首访前先种下标识**：启动后、打开启动网址前，把 `__stripe_mid` / `__stripe_sid` 写到启动域名（最多 20 个主机，写后回读）。已有的合法值会被采纳，同一 Profile 重启仍是同一台设备。
- **恢复浏览器的三方 Cookie 姿态**：内置引擎默认拦截三方 Cookie，而原版 Chrome 不会。启动前把 Profile 偏好设为允许，`.m.stripe.com` 的设备锚点才能像真实 Chrome 一样存在。
- **重置清得更干净**：新增清除 FingerprintJS 的访问者标识与 Chromium 的会话目录。重置会登出该 Profile 的所有网站（含 Link），扩展、书签、历史与 Profile 配置保留。

### 屏幕与设备面

- **屏幕、DPR、色深、设备内存、触控由页面层注入**：引擎的屏幕开关是死字符串，此前所有 Profile 都报本机屏幕。现在按 Profile 配置覆写 `Screen`、`devicePixelRatio`、`deviceMemory`、`maxTouchPoints`、`ontouchstart` 与相关媒体查询。
- **不碰 `Object.keys`**：只改既有访问器，不向 `navigator` / `document` 增加自有可枚举属性，检测脚本看到的键列表与真实 Chrome 一致。
- **字体与品牌**：有平台时一律启用字体改写，UA-CH 不再缺 `Google Chrome`；色深按真实 Chrome 统一为 24 位。

### 一致性提示

- 新增提示：选了字体表却没开字体改写、没有屏幕配置（所有 Profile 共用本机屏幕）。
- 兼容性修复：导入、复制、备份恢复不再因设备标识重复被拒；新身份会关掉「恢复上次会话」，避免恢复出已被清掉的会话记录。

### 已知限制

- 伪屏幕由页面脚本注入，headless 下窗口与屏幕仍可能对不上，Stripe 场景建议用有头模式首访。
- 内置引擎仍是 Chromium 148，所有 Profile 共享同一版本与网络栈；WebGPU、语音列表、本地字体枚举仍暴露这台 Mac。
- 新设备只降低关联度，不等于免检；3DS 挑战率常见上升。

### 升级说明

- 升级后，建议停止并重新启动正在运行的 Profile。
- 想把已有 Profile 当作新设备，用「整套重新生成」，并给它一个独立的代理出口。

下载 ARM64 ZIP，解压后把 `AnyBrowser.app` 移到「应用程序」文件夹再打开，并用 `SHA256SUMS` 校验文件。首次打开如被系统拦下，在「系统设置 → 隐私与安全性」中选择「仍要打开」，或执行 `xattr -dr com.apple.quarantine /Applications/AnyBrowser.app`。