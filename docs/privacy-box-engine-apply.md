# 引擎补丁：落地步骤

补丁清单见 `privacy-box-engine.md`。这里写怎么把清单变成可发布的内核，以及本机缺什么。

## 本机现状

- 只有 Command Line Tools，没有 Xcode：Chromium 官方要求 Xcode 16+，`autoninja` 与 SDK 都不在。
- 没有 `depot_tools`，也没有源码树。
- 磁盘剩余约 1.6 T，够一次完整 sync 与构建。

## 一次性准备

```bash
mkdir -p ~/engine && cd ~/engine
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"
fetch --nohooks --no-history fingerprint-chromium   # 或按上游 README
cd src && git checkout <与 versions.env 一致的 tag>
gclient sync
./build/install-build-deps.sh                         # 非 Linux 可跳过
gn gen out/arm64 --args='is_debug=false target_cpu="arm64" is_component_build=false'
```

## 打补丁

补丁按 `privacy-box-engine.md` 的 E1–E12 逐项落成 `privacy-box-engine/patches/00NN-*.patch`，每个补丁只碰一个文件族的少量函数。该目录尚未提交，第一次落地时自建：

```bash
mkdir -p ~/anybrowser/docs/privacy-box-engine/patches   # 放 E1–E12 的补丁
shopt -s nullglob
cd ~/engine/src
for p in ~/anybrowser/docs/privacy-box-engine/patches/*.patch; do git apply --3way "$p"; done
autoninja -C out/arm64 chrome
```

目录为空时 `nullglob` 让循环空转，不会传进去一个字面量通配符。

产物：`out/arm64/Chromium.app`，按上游打包成 dmg，替换 `scripts/versions.env` 的 `engine_version`、`engine_revision`、`engine_sha256`。

## 每次上游升级

1. `git checkout <新 tag>` 后重新 `git apply --3way` 全部补丁；
2. 冲突按「读取点仍由 `--fingerprint-*` 决定」的原则解决；
3. 跑 `docs/privacy-box-plan.md` §8 的引擎 golden：CSS 与 JS 同问同答、Worker 与首帧同值、字体向量逐位一致；
4. 换 `versions.env` 三元组，跑全量套件与打包产物套件。

## 验收门槛

- `outer ≤ screen`、`inner ≤ avail` 在 headed 与 headless 都成立。
- `(resolution: Xdppx)` 的 CSS 与 JS 一致。
- `Segoe UI`、`Calibri` 在 40 次采样中可测率 100%。
- Linux 身份的 WebGL 不再报 Apple。
- `Object.keys(navigator/document)` 不变。

## 未完成项

- 补丁文件本身尚未编写（需要源码树逐文件定位）。
- 本机缺 Xcode，首次构建需安装。