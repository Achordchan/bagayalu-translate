# 大佐翻译官 (Bagayalu Translate)

仓库地址：https://github.com/Achordchan/bagayalu-translate

一个专注于 **MacOS** 的轻量翻译工具：

- 输入框翻译（支持自动识别源语言）
- Cmd+C+C快速翻译
- 截图 OCR + 翻译（支持框选区域、翻译覆盖层）
- 钉图（把截图固定在桌面，右键复制/保存/关闭）
- 应用内自动更新（直接安装并自动重启，无需手动覆盖 App）
- 默认使用 Apple 本地翻译，也支持 Google / 微软翻译 / OpenAI Compatible

> 本项目仍在快速迭代中。欢迎 issue / PR。
![截图1](https://raw.githubusercontent.com/Achordchan/bagayalu-translate/refs/heads/main/dazuofanyiguan/img/git1.png)
>
 ![截图2](https://raw.githubusercontent.com/Achordchan/bagayalu-translate/refs/heads/main/dazuofanyiguan/img/git2.png)
---

## 功能特性

- **文本翻译**
  - 自动识别源语言
  - 保留换行（OCR 场景也适用）
  - Mini 模式：双击 Command+C 后在鼠标附近显示译文，不唤起主窗口

- **截图 OCR 翻译**
  - 全局快捷键唤起
  - 框选区域后进行 OCR
  - 译文覆盖层展示

- **钉图（Pinned Screenshot）**
  - 将截图固定为浮窗
  - 右键菜单

- **多引擎**
  - Apple 本地翻译（默认，无需 API Key）
  - Google Translate
  - 微软翻译（免密，走 Edge 网页翻译接口）
  - OpenAI Compatible（可接 OpenAI / 兼容格式的第三方服务）

- **应用内更新**
  - 每天自动检查 GitHub Release
  - 也可在“关于应用”或应用菜单中手动检查
  - 下载完成后直接替换当前版本，并自动重启应用
  - 更新 ZIP 使用 Sparkle EdDSA 签名校验；主程序使用作者免费 Apple ID 自带的 Apple Development 证书签名（非 Developer ID），未经过 Apple 公证
  - 该能力从 1.2.0 开始提供，旧版本需要手动安装一次 1.2.0

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

### 脚本启动

```bash
./start.sh
```

脚本会使用 Xcode 构建 Debug 版本并在当前终端前台运行应用。按 `Ctrl+C` 结束；不需要 `end.sh`。可通过 `DAZUO_DERIVED_DATA_PATH` 自定义 DerivedData 目录。

### 发布与更新签名

当前 GitHub Release 不使用 Developer ID 分发签名，也不进行 Apple 公证。arm64 和 x86_64 发布包都用作者免费 Apple ID 自带的 Apple Development 证书做完整 bundle 签名（`--deep`，连 Sparkle 的嵌套组件一起，不含 sandbox 权限），使 Sparkle 可以检查完整包结构。工作流会通过 `SPARKLE_PRIVATE_KEY` 对更新 ZIP 生成 EdDSA 签名；客户端使用内置 `SUPublicEDKey` 验证下载内容。

签名身份必须跨版本不变，否则每次更新都有东西要用户重来：

- **辅助功能、屏幕录制授权**绑在身份要求上：`identifier "achord.dazuofanyiguan" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and …`。ad-hoc 签名绑的是每次构建都会变的 cdhash。
- **钥匙串里的 API Key**：钥匙串按分区认 App，只有 Apple 签发的证书链才按团队 ID（`teamid:S336CKXSUQ`）认；ad-hoc 和自签名证书一律退回 cdhash，于是每次更新读 API Key 都要弹框输登录密码。1.3.1 ~ 1.4.0 用的自签名证书保住了授权，但挡不住这个框，所以换成了 Apple Development 证书。

工作流把团队 ID 和完整的身份要求写死在校验里，对不上就构建失败，不会悄悄发出去。

**配置方法**：在仓库 Settings → Secrets and variables → Actions 里加两个：

1. 钥匙串访问 →「登录」→「我的证书」，右键「Apple Development: …」→ 导出为 `.p12` 并设一个导出密码
2. 存进 Secrets，然后删掉本地的 `.p12`：

```bash
base64 -i ~/Desktop/dev.p12 | gh secret set MACOS_DEV_CERT_P12_BASE64
gh secret set MACOS_DEV_CERT_PASSWORD   # 交互式输入导出密码，不进 shell 历史
```

**没配就不出包**：退回 ad-hoc 或自签名，等于让所有用户再授权一次。证书一年一续（Xcode → 设置 → 账户里续），续完重新导出、更新这两个 Secret 即可；证书名和团队不变，身份要求也就不变，已装的 App 不受影响。CI 会在到期前 30 天提醒。

主程序不再启用 App Sandbox 的 InstallerLauncher XPC，避免无 Developer ID 时辅助进程连接不稳定。首次从旧沙盒版本迁移时会复制已有设置，但 macOS 辅助功能、屏幕录制等权限仍可能需要重新确认。

---

## OpenAI Compatible 配置说明

当选择 OpenAI Compatible 引擎时：

- **API Key**：保存在 macOS Keychain（钥匙串）
- **BaseURL / Model / EndpointMode**：在设置中配置
- API 请求与响应模型由 `MacPaw/OpenAI 0.5.1` 处理，并启用第三方服务兼容解析
- Responses 标准请求被服务端以 `HTTP 400/422` 拒绝时，会自动使用精简参数重试一次

当遇到 `HTTP 429`（限流）时：

- Toast 仅显示服务端返回的 `code + message`
- 会显示 2 秒倒计时“准备重试中”
- 倒计时结束后再发起一次重试

## Apple 本地翻译说明

- 需要 macOS 15.1 或更高版本
- 无需 API Key，翻译由 macOS Translation 框架处理
- 首次使用某个语言组合时，系统可能提示下载对应语言模型

---

## 贡献

欢迎：

- 提交 Issue：描述问题、复现步骤、截图/日志
- 提交 PR：保持改动聚焦、便于 review
- 提交 PR 时同步在 `开发日志.md` 顶部补一条：为什么改、量到了什么数据、哪些坑要避开

---

## License

本项目使用 MIT License，详见 `LICENSE`。
