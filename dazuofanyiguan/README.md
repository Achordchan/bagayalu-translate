# 大佐翻译官 (Bagayalu Translate)

仓库地址：https://github.com/Achordchan/bagayalu-translate

一个专注于 **macOS** 的轻量翻译工具：

- 输入框翻译（支持自动识别源语言）
- 截图 OCR + 翻译（支持框选区域、翻译覆盖层）
- 钉图（把截图固定在桌面，右键复制/保存/关闭）
- 支持 Google / OpenAI Compatible（自定义 BaseURL / Model）

> 本项目仍在快速迭代中。欢迎 issue / PR。

---

## 功能特性

- **文本翻译**
  - 自动识别源语言
  - 保留换行（OCR 场景也适用）

- **截图 OCR 翻译**
  - 全局快捷键唤起
  - 框选区域后进行 OCR
  - 译文覆盖层展示

- **钉图（Pinned Screenshot）**
  - 将截图固定为浮窗
  - 右键菜单：复制 / 保存 / 关闭 / 全部关闭

- **多引擎**
  - Google Translate
  - OpenAI Compatible（可接 OpenAI / 兼容格式的第三方服务）

---

## 预览图标

> 仓库内提供了可编辑的 SVG 图标：`Branding/AppIcon.svg`（可转 PNG / ICNS）。

---

## 权限说明（macOS）

为了实现全局快捷键和截图 OCR，应用会申请/使用以下权限：

- **辅助功能（Accessibility）**
  - 用途：监听全局快捷键、在部分场景控制窗口行为

- **屏幕录制（Screen Recording）**
  - 用途：截图框选区域并进行 OCR

- **剪贴板（Clipboard）**
  - 用途：复制识别文本、复制截图图片

隐私相关说明请阅读：`PRIVACY.md`。

---

## 构建方式

- 系统：macOS
- IDE：Xcode

1. 用 Xcode 打开项目
2. 选择 scheme 并运行

---

## OpenAI Compatible 配置说明

当选择 OpenAI Compatible 引擎时：

- **API Key**：保存在 macOS Keychain（钥匙串）
- **BaseURL / Model / EndpointMode**：在设置中配置

当遇到 `HTTP 429`（限流）时：

- Toast 仅显示服务端返回的 `code + message`
- 会显示 2 秒倒计时“准备重试中”
- 倒计时结束后再发起一次重试

---

## 贡献

欢迎：

- 提交 Issue：描述问题、复现步骤、截图/日志
- 提交 PR：保持改动聚焦、便于 review

---

## License

本项目使用 MIT License，详见 `LICENSE`。
