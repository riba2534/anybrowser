# 伪装盒改造方案：完全伪装、强隔离、可推敲的随机身份

- 目标仓库：`/Users/riba2534/airepo/anybrowser`
- 对手：Stripe `m.stripe.com` 采集器、Anthropic `s-cdn/s.js`（Sift + fpjs v3 + detectIncognito）、FPJS Pro、3DS ACS
- 依据：`docs/stripe-new-device-plan.md`、`docs/stripe-new-device-evidence/`、`/tmp/anthropic-sjs/out/REPORT.md`
- 原则：能做的全部做；做不到的显式标注；每个决定可被同一份门禁验证

---

## 0. 目标与判定

### 0.1 三条硬目标

1. **特征完全伪装**：所有被读取的字段都由 Profile 决定，跨 Profile 不共享，且在页面内、跨帧、CSS 与 JS、Worker 与主线程之间自洽。
2. **隔离**：任意两个 Profile 在磁盘、内存、网络、身份标识上互不渗透；同一 Profile 生命周期内稳定。
3. **随机可推敲**：随机生成的是「一台真实存在、组合合理、常见程度可接受」的设备，而不是独立字段掷骰子。

### 0.2 判定方式

- 服务端一行可判的矛盾为零：`outer ≤ screen`、`inner ≤ avail`、CSS/JS 媒体一致、`device-*` 与 `screen` 一致、`toString` 为 native 形制。
- 同一份 fingerprint 在两次独立启动、跨 origin、跨 iframe、Worker 内取值完全一致。
- 任意两 Profile 的 `deviceIdentity`、`seed`、屏幕、字体向量、canvas md5、WebGL、locale 组合互不相同。
- `SelfCheck` 全 pass，除「只能接受」项外无 info。

### 0.3 可做 / 近似 / 不可做

| 类别 | 内容 |
|---|---|
| 可做（引擎或 App 层） | 屏幕、avail*、DPR、媒体求值、窗口、字体向量、UA-CH、deviceMemory、touch、连接信息、无痕配额、通知权限、形制伪装 |
| 近似 | 非 macOS 的字体像素（靠合成向量）、语音列表、WebGPU 适配器 |
| 不可做 | TLS/JA3、HTTP/2 特性、引擎版本、真实 GPU 家族、宿主显示器物理上限 |

---

## 1. 伪装盒分层

```
L0 网络    代理、DNS、WebRTC、时区/语言与出口对齐
L1 引擎    screen/DPR/media、字体表、UA-CH、deviceMemory、touch、无痕配额
L2 身份    deviceIdentity、seed、locale、屏幕、字体、canvas、WebGL、audio
L3 形制    toString、WebIDL 抛错、receiver 校验、Proxy 去自有属性、栈清理
L4 验证    payload 复算、golden、CSS/JS 双基准、SelfCheck、E2E、门禁
```

L1 是根因层；L3 只负责让注入不可辨；L2 由采样器保证唯一与自洽；L4 保证前三条不被回退。

---

## 2. 引擎补丁清单（L1，最高优先）

> 这些都是 `--fingerprint-*` 死字符串或完全缺失的能力，注入只能补偿，不能替代。

| # | 能力 | 落点 | 验收 |
|---|---|---|---|
| E1 | 接活 `--fingerprint-screen-width/height`、`-device-scale-factor` | `third_party/blink/renderer/core/frame/screen.cc`、`window.cc`、`media_query_evaluator` | CSS `@media`、`srcset`、`-webkit-device-pixel-ratio`、Worker、首帧与 JS 同值 |
| E2 | `availTop/availLeft/availWidth/availHeight` 由配置驱动 | `screen.cc` | Windows/Linux `availTop=0`；macOS 按菜单栏 |
| E3 | `colorDepth/pixelDepth` 配置化 | `screen.cc` | 24 恒定，macOS 可选 30 |
| E4 | 字体表按平台返回参考向量，`measureText` 不再把 `Segoe UI/Calibri` 抹成 0 | `platform/fonts/font_cache.cc`、`canvas_rendering_context_2d.cc` | 55 位串与参考机逐位一致；`measureText` 返回真实像素 |
| E5 | 非 macOS 的 emoji 渲染路径与字体族一致 | 字体回退链 | Windows 身份 canvas 的 😃 不吃 Apple Color Emoji |
| E6 | `deviceMemory` 开关 | `navigator_device_memory.cc` | 2/4/8/16/32 按机型集合 |
| E7 | `maxTouchPoints` 与 `ontouchstart` 随平台 | `navigator.cc`、window | 桌面 0；触屏 Windows 1–10 且两者同源 |
| E8 | Linux GPU 值池 | WebGL 伪造表 | Linux 身份不再报 Apple |
| E9 | WebGPU adapter 按平台或固定表 | `navigator_gpu` | 至少与 WebGL 家族不冲突 |
| E10 | 语音列表按平台合成 | `speech_synthesis` | 非 macOS 不再列宿主语音 |
| E11 | `navigator.connection` 由出口类型推导 | `navigator_connection.cc` | `effectiveType/rtt/downlink` 与代理类型一致 |
| E12 | 无痕模式下 `queryUsageAndQuota` 配额按 heap 压缩 | `StorageManager` | `quota < 2×heap`，`inc=true` |

引擎版本升级到上游最新（150+）与 E1–E12 同批做；升级前后重打 keys/plugins/GREASE 基线。

---

## 3. 形制伪装（L3）

| # | 破绽 | 做法 |
|---|---|---|
| F1 | 被换函数 `toString` 是 JS | `Function.prototype.toString` 换成 Proxy，用 `WeakSet` 登记所有替换物，命中返回与 V8 同形 `function get width() { [native code] }`；`eval` 原样转发保长度 |
| F2 | `matchMedia()` 0 参不抛 | 用对象字面量方法（无 `prototype`、不可 `new`），0 参抛 WebIDL 同文 `TypeError` |
| F3 | `matchMedia.call({})` 不抛 | 校验 receiver，非 Window 抛 `Illegal invocation` |
| F4 | `Symbol` 入参不抛 | 抛 `Cannot convert a Symbol value to a string` |
| F5 | MQL 多出自有属性 | 返回原生 MQL 的 Proxy，只在 `get` 陷阱覆盖 `matches/media/query`，不落自有键 |
| F6 | 栈里有 `chrome-extension://` | 手写 `Error` 时裁栈；扩展路径不进 message |
| F7 | PasskeyBox 替换物同样非 native | 纳入 F1 的 WeakSet |
| F8 | 注入脚本全局符号 | 保持 IIFE、无全局；`Object.keys(navigator/document)` 不变式由测试守住 |

---

## 4. 屏幕、窗口与媒体自洽

### 4.1 派生规则

- `screen.width/height` 从屏幕目录取。
- `availTop = 0`（Windows/Linux）或菜单栏高度（macOS）；`availHeight = height - availTop - dock`；`availWidth = width`。
- 窗口：宽 72–88%、高 68–82%，`outer ≤ avail`，居中偏移 `x ∈ [0, screen.w - outer.w]`。
- `outer - inner`：macOS 0 宽差 / 88 高差；Windows 16 / 40；Linux 0 / 32。
- headless 同样传 `--window-size` 与偏移。
- `WindowArrangement` 以该 Profile 伪屏为区域；恢复会话后重新夹取。

### 4.2 媒体求值

- `width/height`：视口。
- `device-width/device-height`：`screen.*`。
- `resolution` 与 `-webkit(-min|-max)-device-pixel-ratio`：dpr。
- `orientation`：`width ≥ height`。
- `color-gamut/dynamic-range/monochrome/contrast/forced-colors/inverted-colors/prefers-*`：按平台目录。
- 组合 query 逐子句求值，未知子句才回落原生。

### 4.3 验收

`SelfCheck` 增 `outer ≤ screen`、`inner ≤ avail`、`outer-inner` 合理、CSS/JS 同问同答、`device-*` 等于 `screen`。

---

## 5. 隔离模型

| # | 面 | 措施 |
|---|---|---|
| I1 | 目录 | 每 Profile 独立 `user-data-dir` 与独立缓存目录（已有）；路径规范化校验，拒绝符号链接逃逸 |
| I2 | 存储 | 重置整库删 Cookie/Storage/IDB/SW/缓存/会话；保留扩展与配置 |
| I3 | 标识 | `deviceIdentity`、`seed`、`screen`、`fontProfile`、`canvas`、`audio`、`webgl` 全部唯一；`checkForConflicts` 同时校验身份四元组 |
| I4 | 扩展 | PasskeyBox 默认共享但不共享凭据；Profile 扩展目录独立 |
| I5 | 代理 | 每 Profile 独立出口；批量新建强制分配；共用出口给 `exit-shared` |
| I6 | 端口 | 唯一端口 + 占用预检（已有） |
| I7 | 进程 | 文件锁、PID/stamp 校验（已有） |
| I8 | 自动化 | 每 Profile 独立 DevTools 端口；无痕上下文继承代理与注入 |
| I9 | 并发 | 启动/重置按 Profile 串行；批量重置排队并显示进度 |

---

## 6. 随机生成引擎

### 6.1 结构

```
seed → 机型族（GPU+内存+CPU 联合） → 屏幕档 → 字体向量 → locale → 隐私姿态
     → 拒绝采样校验 → 自洽评分 → 落库
```

- 先抽**机型族**，其余字段从该族派生，而不是各字段独立抽。
- 每个字段带权重；常见值权重高，边缘值低。
- 生成后跑一遍 `ConsistencyIssue`，有 `critical` 就重抽（最多 N 次），失败回落目录默认项。

### 6.2 规则

- 平台与平台版本、品牌与品牌版本、CPU 与 GPU、内存与机型、屏幕与平台、字体与平台、locale 与出口，全部成对约束。
- 跨 Profile 去重：`seed`、`deviceIdentity`、`(screen,font,canvas)` 三元组任一相同即重抽。
- 只改单字段时（字段随机化器）沿用族内约束，不破坏其余字段。

### 6.3 验收

- 1000 次生成：0 条 `critical` issue；三元组重复率 0；常见组合占比符合权重。
- 生成值全部通过 `validated()`。

---

## 7. `重置且随机指纹` 按钮

### 7.1 语义

一次点击完成：停止 → 清空该 Profile 全部环境与数据 → 生成全新自洽身份 → 保存 → 启动。

### 7.2 时序

```
确认对话框（列出将删除的内容）
→ 若运行中：优雅停止（超时强制）
→ 清站点数据 + 会话目录 + 缓存
→ 新 seed / deviceIdentity / 平台 / 屏幕 / 字体 / locale / 隐私姿态
→ 校验并保存
→ 以新身份启动
```

- 任一步失败：保留已完成的状态，报告失败点，不自动回滚身份。
- 运行中点击时先确认；按钮旁显示进度与当前阶段。

### 7.3 UI

- 位置：Profile 编辑器指纹卡片顶部，主操作按钮。
- 文案：`重置且随机指纹`；副文案说明会清空所有网站登录与数据。
- 快捷键区不与「整套重新生成」混淆；后者只换身份不清数据。

### 7.4 实现

- 新增 `LaunchCoordinator.resetAndRandomize(_:)`，复用 `clearSiteData` 与 `IdentitySampler`。
- 新增 `ProfileStore.resetIdentity(...)` 返回完整新 Profile。
- 自动化 API 增 `POST /profiles/:id/reset-identity`。

---

## 8. 验证与门禁

| 层 | 内容 |
|---|---|
| 单测 | 派生规则、自洽规则、形制（0 参/Symbol/receiver/自有键）、隔离唯一性 |
| 引擎 golden | 每个预设一份 CSS/JS 同问同答、窗口与屏幕、字体向量、keys |
| payload 复算 | Stripe `/6` 报文逐字节复算 `id`、`b.w`、`b.u`、`b.v` |
| 端到端 | 真实测试页抓 Sift GIF、Stripe `/6`、3DS 指纹帧 |
| 门禁 | 任一 `critical` issue、任一 CSS/JS 不一致、任一 `outer > screen` 阻断发布 |

---

## 9. 分阶段

| 阶段 | 内容 | 出口 |
|---|---|---|
| A | 窗口派生与夹取、SelfCheck 新规则、`availTop/Left` | 无 `outer > screen` |
| B | E1–E3 引擎屏幕/DPR/媒体 | CSS/JS 一致 |
| C | F1–F8 形制 | `toString` 与 0 参检测通过 |
| D | 隔离 I1–I9 与并发 | 两 Profile 互不渗透 |
| E | 随机引擎约束化 + 拒绝采样 | 1000 次 0 critical |
| F | `重置且随机指纹` 按钮与 API | 端到端一键完成 |
| G | E4–E12 字体/内存/触控/GPU/WebGPU/语音/连接/无痕 | 非 macOS 身份可用 |

A–C 解决「自证矛盾」，D 解决隔离，E–F 解决可用性，G 解决平台真实性。

---

## 10. 风险

| 风险 | 缓解 |
|---|---|
| 引擎补丁维护成本 | 只补 6 个文件，跟上游 rebase；注入保留为兜底 |
| 注入形制仍被识破 | 形制层单测 + 与真机 toString 对照 |
| 随机组合边缘化 | 权重 + 自洽评分 + 少见组合降权 |
| 重置中断留下半套状态 | 分步状态记录，失败可重试 |
| headless 与窗口冲突 | 首访强制有头；headless 也传窗口尺寸 |

---

## 11. 不做

- 不改写上报 body、不伪造服务端 cookie。
- 不引入 JS polyfill 式全局符号。
- 不为伪装牺牲真实渲染（canvas 仍走引擎）。
- 不做每站策略切换（先全局一致）。