## 更新

0.8.0 补完上一版留下的余项，并把「能做的」收口。

### 无痕表现

- **无痕开关**：启动选项新增「无痕启动」。网页读到的存储配额会压到 JS 堆上限的 1.5 倍，自检按无痕值校验。
- 说明：不叠加 `--incognito`（未打包扩展在真无痕窗口不启用），资料仍写在这个 Profile 自己的目录里；要真正的无痕语义请配合「重置且随机指纹」。

### 连接类型

- 按代理推导 `navigator.connection`：无代理跟随宿主；SOCKS5、带凭据或域名主机报 3g；纯 HTTP(S) 直连报 4g。
- 新增 `connection-proxy` 一致性提示。

### 自检

- **CSS 与 JS 双基准**：宽、高三种问法同时问 `matchMedia` 与真实样式表，两侧不一致即失败；分辨率单列（内核仍按真实 DPR 求值）。
- **可用区越界**：`availTop + availHeight` 不得越过屏幕；多显示器下的 `availLeft` 按全局坐标处理。
- 打包产物冒烟脚本 `scripts/privacy-smoke.sh`：一次检查窗口不超屏、CSS/JS 一致、`toString` 原生形制、`navigator` 零自有键、`eval` 长度。

### 引擎

- `docs/privacy-box-engine-apply.md`：准备、打补丁、验收与升级流程。补丁文件仍需在源码树上落地，本机缺 Xcode 与 depot_tools。

### 已知限制

- 无痕是表现层面的模拟，数据不自动清除。
- 分辨率的一侧仍由内核真实 DPR 求值，两侧可能不同，属已知项。
- 引擎 148，TLS、WebGPU、语音仍不可消除。

下载 ARM64 ZIP，解压后把 `AnyBrowser.app` 移到「应用程序」文件夹再打开，并用 `SHA256SUMS` 校验文件。首次打开如被系统拦下，在「系统设置 → 隐私与安全性」中选择「仍要打开」，或执行 `xattr -dr com.apple.quarantine /Applications/AnyBrowser.app`。