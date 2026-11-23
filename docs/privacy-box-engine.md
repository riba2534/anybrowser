# 引擎补丁清单（未编译，供后续 fork）

内置引擎 148 的屏幕/DPR/媒体开关是死字符串（二进制零引用）。页面注入只能补偿 JS 读取，**CSS `@media`、`srcset`、`-webkit-device-pixel-ratio`、Worker 与首帧仍在宿主**，与注入值互相矛盾。以下补丁是根治项。

## 前置

1. 从上游取源码，版本锁到 `versions.env` 的 `engine_version`，建立可重复的 patch 序列。
2. 每项补丁独立文件，便于 rebase；合并到一次构建里出 dmg，`scripts/versions.env` 换三元组。
3. 全部开关沿用 `--fingerprint-*`，不新增 App 侧协议。

## 补丁

| # | 文件 | 改动 | 验收 |
|---|---|---|---|
| E1 | `third_party/blink/renderer/core/frame/screen.cc`、`window.cc`、`media_query_evaluator.cc` | 读取 `--fingerprint-screen-width/height`、`-device-scale-factor`，覆盖 `screen.*`、`devicePixelRatio`、媒体求值 | CSS 与 JS 同问同答；Worker/首帧同值 |
| E2 | `screen.cc` | `availTop/availLeft/availWidth/availHeight` 由配置驱动；平台缺省 Windows/Linux 0 | `availTop` 符合平台 |
| E3 | `screen.cc` | `colorDepth/pixelDepth` 配置化 | 24 恒定 |
| E4 | `platform/fonts/font_cache.cc`、`canvas_rendering_context_2d.cc` | 按平台返回参考向量；`measureText` 返回真实像素而非小数 | `Segoe UI/Calibri` 不再恒 0 |
| E5 | 字体回退链 | 非 macOS 使用平台 emoji 字体 | canvas 的 😃 不吃 Apple Color Emoji |
| E6 | `navigator_device_memory.cc` | `--fingerprint-device-memory` | 2/4/8/16/32 按机型 |
| E7 | `navigator.cc`、window | `maxTouchPoints` 与 `ontouchstart` 同源 | 桌面 0；触屏 1–10 |
| E8 | WebGL 伪造表 | Linux GPU 值池 | Linux 身份不报 Apple |
| E9 | `navigator_gpu` | 平台适配器表 | 与 WebGL 家族不冲突 |
| E10 | `speech_synthesis` | 平台语音合成 | 非 macOS 不列宿主语音 |
| E11 | `navigator_connection.cc` | 由 `--fingerprint-connection` 推导 | 与出口类型一致 |
| E12 | `StorageManager` | 无痕配额按 heap 压缩 | `quota < 2×heap` |

## 与 App 的衔接

- 引擎修好后，`IdentityShim` 的屏幕/deviceMemory/touch 分支按 capability 关闭，只保留 `toString` 形制与 measureText 兜底。
- `FingerprintConsistency` 的 `screen-platform`、`font-spoof-missing` 等「内核不支持」提示改为按 capability 判定。

## 风险

- 补丁面虽小，但 `screen.cc` 与媒体求值在渲染主路径，需真机回归滚动、缩放与多显示器。
- 每次上游升级重打补丁；`scripts/check-updates.sh` 的版本告警同时提示补丁需复核。