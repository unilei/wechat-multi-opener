# v1.4.0

这是第一个公开的开源自用版。

## Included

- Universal macOS App：`arm64 + x86_64`
- SwiftUI 四 Tab 界面：多开、体检、清理卸载、日志
- 微信版本过期检测和按 Bundle ID 重建
- 开机登录项检查和系统通知提醒
- 可复现构建、命令行自检、ZIP/DMG SHA-256
- 中文 README、使用教程、兼容性说明和贡献指南

## Verification environment

- macOS 26.7
- Apple Silicon
- Official WeChat 4.1.11 (269136)
- `--selftest` passed
- `--login-test` passed
- `codesign --verify --deep --strict` passed

## Important limitations

- 当前使用 ad-hoc 签名，没有 Developer ID 或 Apple notarization。
- 首次使用副本可能需要独立扫码登录。
- 不承诺所有微信 4.1.x 版本、消息通知、音视频和系统权限行为。
- 这是非腾讯官方工具，仅供个人学习和自用；请自行评估账号和合规风险。
