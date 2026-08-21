# 微信多开助手

一个原生 SwiftUI macOS 工具：基于本机已安装的官方微信 App，创建带有不同 Bundle ID 的本地副本，用于在同一台 Mac 上启动多个微信实例。

> 这是开源自用工具，不是腾讯官方软件，也不包含远程控制、账号托管或登录凭据迁移功能。请先阅读[使用边界与风险](#使用边界与风险)。

![主界面](docs/assets/01-main.png)

## 能做什么

- 支持 Intel 和 Apple Silicon：构建产物为 Universal `arm64 + x86_64`。
- 通过 GUI 创建、打开、重建和移除微信副本，不需要用户在日常使用时打开终端。
- 使用独立的副本 Bundle ID（例如 `com.tencent.xinWeChat2`），副本放在 `~/Applications`。
- 微信版本更新后检测过期副本，并按原 Bundle ID 重建。
- 环境体检：检查 macOS、系统工具、微信、磁盘空间和副本目录。
- 开机登录项检查和系统通知提醒。
- 清理副本 App 与副本数据；清理操作优先移到废纸篓，原版微信不在清理范围内。
- 提供操作日志、命令行自检和可选 DMG 打包脚本。

## 使用边界与风险

1. 本工具会复制微信 App、修改 `CFBundleIdentifier` 并使用本机 ad-hoc 签名。它不保留腾讯的原始签名身份，也不代表得到腾讯授权。
2. 新副本通常需要独立登录，不能承诺“一键登录”或“无需重新扫码”。重建、微信升级、系统权限和微信自身策略都可能使登录状态失效。
3. 摄像头、麦克风、屏幕录制和通知权限可能需要按副本分别授权；当前项目没有把这些权限视为已验证能力。
4. 微信版本兼容性必须按具体 build 验证。当前本地验证的是官方微信 `4.1.11 (269136)` 的检测、复制和签名流程，不代表所有 4.1.x 都兼容。
5. 请不要把本工具用于批量营销、绕过平台限制、账号共享或其他违反微信规则的行为。账号、数据和合规风险由使用者自行承担。

## 快速开始

### 方式一：源码构建（推荐）

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。用户运行已经构建好的 App 时不需要安装开发环境。

```bash
git clone https://github.com/unilei/wechat-multi-opener.git
cd wechat-multi-opener
./build.sh
open "dist/微信多开助手.app"
```

把 App 移到“应用程序”文件夹后再开启“开机自动检查”，可避免登录项因路径变化失效：

```bash
cp -R "dist/微信多开助手.app" "/Applications/"
open "/Applications/微信多开助手.app"
```

### 方式二：下载 Release

从 [GitHub Releases](https://github.com/unilei/wechat-multi-opener/releases) 下载 ZIP 或 DMG，解压/拖入“应用程序”后启动。未使用 Developer ID 公证时，macOS 可能显示“无法验证开发者”；确认源码和校验值可信后，可在 Finder 中右键 App，选择“打开”，或到“系统设置 → 隐私与安全性”点击“仍要打开”。

每次下载后可校验 SHA-256：

```bash
shasum -a 256 "微信多开助手.zip"
```

### 创建第一个副本

1. 确认官方微信位于 `/Applications/WeChat.app`、`/Applications/微信.app` 或用户的 `~/Applications`。
2. 打开“微信多开助手”，在“多开”页确认原版微信版本。
3. 点击“创建新的微信副本”。副本默认生成在 `~/Applications`，例如 `WeChat2.app`。
4. 首次启动副本时按微信界面要求登录；不同副本的登录状态请分别确认。

## 更新微信后的流程

微信升级后，副本版本可能落后。打开助手，在“多开”页确认过期数量并点击“一键重建”。重建会先请求退出运行中的副本，在临时目录生成并签名新副本，再替换旧 App。完成后请手动检查每个副本的登录状态和系统权限。

不要直接覆盖副本的 Bundle ID，也不要在副本运行时手动删除其 App 包；这会让容器、签名或版本检测进入不可预测状态。

## 构建与校验

```bash
./build.sh
./dist/微信多开助手.app/Contents/MacOS/WeChatMultiOpener --selftest
./dist/微信多开助手.app/Contents/MacOS/WeChatMultiOpener --login-test
./package_dmg.sh
```

`build.sh` 会生成：

- `dist/微信多开助手.app`
- `dist/微信多开助手.zip`
- `dist/微信多开助手.zip.sha256`

`package_dmg.sh` 是可选的本地打包脚本，会额外生成 DMG 和 SHA-256。DMG 只是安装体验更好，不代表代码已经 Developer ID 签名或 Apple 公证。当前不提供 PKG：本项目只写入用户目录，不需要管理员权限，PKG 会增加安装和卸载复杂度。

## 常见问题

### “无法验证开发者”

这是未使用 Developer ID/notarization 的预期提示。确认你下载的是项目 Release，并核对 SHA-256 后，用 Finder 右键 App →“打开”。不要对来源不明的副本绕过 Gatekeeper。

### 创建失败或提示空间不足

微信副本是完整 App 复制，单个副本通常需要约 1.2 GB。关闭正在运行的复制/重建任务，清理磁盘后重试。终端构建时确认 Xcode Command Line Tools 可用：

```bash
xcode-select -p
```

### 副本无法登录或通知不显示

副本是新的 Bundle ID 和容器，首次登录可能需要扫码。通知还受微信设置、系统通知、专注模式和每个副本的授权影响；当前项目不承诺免扫码或通知一定可用。

### 怎么彻底移除副本

在“清理卸载”页扫描并确认清理。副本 App 和识别到的副本容器会移到废纸篓；原版微信和原版聊天数据不在扫描范围内。确认不再需要后，再删除“微信多开助手”本身。

## 项目结构

```text
main.swift       SwiftUI 界面、环境检查、复制/重建/清理逻辑
Info.plist       App 元数据和最低 macOS 版本
build.sh         Universal 构建、签名、校验、ZIP 和 SHA-256
package_dmg.sh   可选 DMG 打包
make_icon.py     从 1024px PNG 生成 AppIcon.icns
docs/            安装、故障排查、兼容性和宣传文案
```

## 贡献

请先阅读 [贡献指南](CONTRIBUTING.md)。涉及微信版本兼容性时，请提供 macOS 版本、机器架构、微信完整版本/build、操作日志和是否新建副本后扫码登录等信息；不要提交聊天记录、账号信息或容器数据。

## 许可证

代码使用 [MIT License](LICENSE)。微信名称、图标和相关商标归其各自权利人所有。
