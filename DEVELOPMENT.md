# 神仙云 Apple 客户端 · 开发说明

本仓库 fork 自 [TokenPLS/Hako-Client](https://github.com/TokenPLS/Hako-Client)，
是神仙云项目族的 **Apple 线**（iOS / iPadOS / macOS / tvOS），内核为
[Hako](https://github.com/TokenPLS/Hako)（基于 mihomo 的 Apple 内核）。

上游原始说明见 [README.md](README.md)。本文件只写**神仙云特有**的部分。

## 仓库分层（重要）

```
abxian/Hako            内核 fork，只同步不改代码
abxian/Hako-Adapter    Swift NE 桥接 fork，只同步不改代码
abxian/shenxianyun-apple  ← 本仓库。神仙云的代码只放这里
```

**上游 Hako 用「快照式」重写历史发布**：每隔一段时间换一个全新的根提交，
fork 与上游没有共同祖先。所以两个内核 fork 的 `main` 必须保持随时可被强制覆盖：

```sh
gh repo sync abxian/Hako --source TokenPLS/Hako --force
git -C <本地路径> fetch origin && git -C <本地路径> reset --hard origin/main

# ⚠ gh repo sync 只同步默认分支，不同步标签。而 Hako 的构建要读标签
#   （Makefile 用 git describe，build_libbox 要找 v*-hako.N 标签定 SDK 版本），
#   标签缺失会直接报 "git describe: exit status 128"。同步后必须补：
git -C <本地路径> fetch upstream --tags
for t in $(git -C <本地路径> tag -l 'v*-hako.*'); do
  git -C <本地路径> push origin "refs/tags/$t"
done
```

**不要在那两个 fork 上提交自己的改动**，下次同步必被冲掉。

## 品牌与身份

所有编译期身份集中在根目录 [`site-profile.properties`](site-profile.properties)。
改完跑：

```sh
python3 scripts/brand-apply.py            # 注入 + 重新生成 Xcode 工程
python3 scripts/brand-apply.py --check    # 只报告差异，不落盘（可当 CI 门禁）
```

脚本是**幂等**的：旧家族名从 `project.yml` 现读，重复跑或换 `bundle.base` 再跑都正确。

### 为什么不直接用上游的 configure.py

上游 `scripts/configure.py --bundle-base` 只改 `project.yml` 的 `HAKO_BUNDLE_BASE`
和两个 `*Identifiers.swift`。但另有 **12 个 Swift 文件把 `org.example.hako` 硬编码**进了
Darwin 通知名、`DispatchQueue` 标签、`Logger` subsystem 和 Control Center 的 `controlKind`。

前两类里，**Darwin 通知名和 controlKind 是系统级命名空间**——不改的话，本应用会与真正的
Clash、以及将来同族的 52nm 版**互相串扰**。`brand-apply.py` 先补上这一段，再调上游脚本。

### 不由本脚本管的

| 东西 | 在哪改 |
|---|---|
| 权限说明文案 | 上游已做本地化，改 `**/zh-Hans.lproj/InfoPlist.strings`。`project.yml` 里那份英文只是兜底 |
| 应用图标 | `apple/HakoClient/Resources/Branding/` 下的 xcassets |
| `Info.plist` / `entitlements` | **不要改**，它们是 XcodeGen 从 `project.yml` 生成的产物，已 gitignore |

## 本机构建

前置：Xcode 26.6（含 iOS/macOS/tvOS SDK）、XcodeGen、Python3 + PyYAML、
Go（能取得 1.26.6 工具链）。

```sh
python3 scripts/bootstrap.py    # 拉钉住的内核/Adapter，编五切片 Hako.xcframework
python3 scripts/configure.py    # 或 brand-apply.py，生成 Xcode 工程
xcodebuild -project apple/HakoClient/HakoClient.xcodeproj \
  -scheme HakoClient -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

一键脚本：`rc/ops/hako-apple-sdk-20260905/bootstrap-shenxianyun-apple.sh`。

### 已知坑

1. **Go 工具链必须「真装」**。`bind/hako/go.mod` 钉死 `toolchain go1.26.6`；
   若本机只有 `GOTOOLCHAIN=auto` 下到 GOMODCACHE 里的那份，`go build` 拒绝在只读的
   模块缓存下做 overlay，**五个切片一个都编不出来**。
   官方建议的 `go1.26.6 download` 走 `dl.google.com`，国内网络不通。
   解法：把模块缓存里那份（已按校验数据库验过哈希）铺成 `~/sdk/go1.26.6` 布局：
   ```sh
   cp -R "$(go env GOMODCACHE)/golang.org/toolchain@v0.0.1-go1.26.6.darwin-arm64" ~/sdk/go1.26.6
   chmod -R u+w ~/sdk/go1.26.6 && touch ~/sdk/go1.26.6/.unpacked-success
   ```
2. **换 `Dependencies.lock.json` 的 repository 后要清 `.build/dependencies`**，
   否则 `bootstrap.py` 会因 origin URL 不匹配报 `Unexpected dependency origin`。
3. **SDK 版本目前是 `dev-<短SHA>`**：`Dependencies.lock.json` 钉的 kernel revision
   比最近的 `v*-hako.N` 标签新，所以 `build_libbox` 不打正式 SDK。这是上游自己的选法
   （其源码分发本就是 pre-release）。正式发版前若要正式 SDK，需把 pin 移到带标签的 revision。

## 后端对接

后端是 vpn-web（sxnn 线 `api.sxnn.de:5443`）。**订阅走 `/sub/<提取码>` 的 Clash 原文**，
与 PC / Android 完全同源，不要用 `/singbox/<code>`（那是给旧 sing-box 线的有损转换）。

完整接口契约（含旧线踩过的 4 个坑）见 Trilium 项目 `Nsaq2BSNBc4O` → 02 · 技术与决策 → 02.1，
以及 `rc/ops/hako-apple-sdk-20260905/HAKO-API-AND-CONTRACT.md`。

`target=shenxianyun` 是官方客户端的**兼容协议键，不是展示品牌**，改品牌时不能动它。

## 发布状态口径

按族内规范，以下是互相独立的状态，任何一步都不代表下一步：
本地能编 → Git 已提交 → GitHub 已推送 → Actions 编译通过 → 签名归档 →
进入分发入口（才叫「客户端已发布」）→ 真机验收。
