# AnyBrowser

AnyBrowser 是面向 Apple Silicon 的本地 Profile 启动器，内置 Fingerprint Chromium。一个窗口可以管理多份 Profile，每份都有独立的浏览器资料、指纹配置和本机调试端口。

## 构建

需要 Apple Silicon Mac、macOS 12 或更新版本，以及带 Swift 5.9 或更新版本的 Xcode 或 Command Line Tools。

```sh
./scripts/build-app.sh
open dist/AnyBrowser.app
```

构建脚本下载并校验上游 DMG，将完整浏览器嵌入生成的 ARM64 应用。首次构建需要联网，随后使用已校验的缓存。可以用 `ANYBROWSER_ENGINE_CACHE` 指定缓存目录。当前内置版本为 [Fingerprint Chromium 148.0.7778.215](https://github.com/adryfish/fingerprint-chromium/releases/tag/148.0.7778.215)，这是实现时最新发布的 macOS ARM64 包。产物采用本机 ad-hoc 签名。

## Profile

在左侧新建 Profile，配置端口和指纹，再点「保存并启动」。默认端口从 9222 开始。同一份 Profile 的调试地址在启动后可复制，只接受本机回环访问。已经启动的 Profile 通过重启应用新配置。

「随机生成」可以仅生成选中的字段。保存后使用具体生成值。平台、版本、品牌、CPU、语言、时区和指纹种子支持编辑。字体、音频、Canvas、元素坐标和 WebGL 参数提供单独开关。内存和 WebGL 档位由该版本引擎根据种子等条件处理，实际可见值受内核和平台能力约束。

本机配置保存在 `~/Library/Application Support/AnyBrowser/profiles.sqlite3`，Chromium 资料位于同目录的 `Profiles/<UUID>`。移除 Profile 条目保留其浏览器资料目录。

## 验证

```sh
swift test --arch arm64
ANYBROWSER_TEST_APP="$PWD/dist/AnyBrowser.app" swift test --arch arm64
```

完整测试需登录 macOS 图形会话并预留本机端口 9222 和 9223。它使用临时资料目录和回环测试页，验证两个浏览器进程、DevTools 端点归属、网页读取值、站点存储隔离、端口冲突、停止及重启后恢复。
