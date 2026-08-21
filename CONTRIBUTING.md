# 贡献指南

感谢参与。这个项目优先接受可复现、可审计、不会泄露用户数据的改进。

## 本地开发

```bash
xcode-select --install
./build.sh
./dist/微信多开助手.app/Contents/MacOS/WeChatMultiOpener --selftest
```

提交前至少运行 `./build.sh` 和 `--selftest`。如果改动登录项、通知、清理或重建逻辑，请在 Pull Request 中说明手动验证结果。

## 报告兼容性问题

请提供：

- macOS 版本和机器架构（Intel 或 Apple Silicon）；
- 微信版本和 build 号；
- 使用的是原版、刚创建的副本还是重建后的副本；
- “日志”页中的相关输出和复现步骤。

请先删除账号、聊天内容、路径中的个人姓名和其他敏感信息。不要上传 `~/Library/Containers`、`~/Library/Group Containers` 或微信 App 包。

## 不接受的改动

- 上传、保存或收集用户微信数据、登录凭据、二维码或远程控制凭据；
- 把“无需扫码”“安全无风险”“支持所有最新版本”等未经验证的表述加入 UI、README 或宣传材料；
- 修改原版微信或删除不属于本工具的文件；
- 为了绕过 macOS 安全机制而加入不可审计的下载器、提权脚本或关闭系统保护的命令。
