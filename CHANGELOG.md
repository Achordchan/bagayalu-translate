# 更新日志

## 1.2.3 - 2026-07-31

- OpenAI 通用接口改用 MacPaw/OpenAI SDK，移除原有手写请求与响应解析主路径。
- Responses 支持真实 SSE 流式译文，主窗口和 Mini 翻译气泡会随服务端增量实时更新。
- Responses 标准参数被拒绝时自动使用精简参数重试，并统一处理限流与不兼容错误。
- 增加常见第三方 Responses 响应结构的兼容解析，保留 Chat Completions 模式。
- 修复接口验证成功但 API Key 写入失败时仍保存部分配置的问题。
- 修复 Mini 窗口关闭后残留悬停状态，导致后续结果不再自动关闭的问题。
- 发布包改为无 sandbox 权限的完整 ad-hoc bundle 签名，确保 Sparkle 可生成并验证更新包。
- 增加本地 `start.sh`、锁定 Swift Package 版本并补充第三方许可声明。

## 1.2.2 - 2026-07-17

- 修复无 Developer ID 环境下 Sparkle 更新安装失败问题。
- 改进 arm64 与 x86_64 发布包的签名检查与 appcast 生成。

## 1.2.1 - 2026-07-17

- Mini 模式支持智能翻译方向。
- 增加原文、译文和 Mini 窗口独立字号。
- 改进全局快捷键、权限刷新与服务商切换。
