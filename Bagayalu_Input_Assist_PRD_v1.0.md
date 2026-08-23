# Bagayalu Translate — Input Assist 输入增强 PRD

> 文档类型：产品 + 技术 PRD  
> 产品：Bagayalu Translate  
> 功能模块：Input Assist / 输入增强  
> 平台：macOS only  
> 状态：Draft v1.0  
> 日期：2026-08-23  
> 核心原则：**优先复用成熟开源实现，减少手搓；不重造中文输入法；不破坏用户现有输入习惯。**

---

## 1. 背景

Bagayalu Translate 当前已经具备完整的 macOS 翻译能力，包括：

- Apple Translation
- Google Translate
- OpenAI Compatible
- 快捷翻译
- OCR 翻译
- 浮层展示
- 系统级辅助功能权限能力

现有翻译产品的典型交互仍然是：

1. 用户输入/选中文本
2. 主动触发翻译
3. 查看译文
4. 再复制或替换

本功能希望把翻译进一步前移到“输入行为”本身：

> 用户继续使用 Apple 原生输入法、搜狗等现有中文输入法；中文完成上屏后，Bagayalu 自动或手动在当前光标附近展示预设目标语言候选，用户像选择输入法候选词一样选择目标语言，随后直接用译文替换刚刚输入的中文。

---

# 2. 产品目标

## 2.1 核心目标

让跨语言输入从：

`中文输入 → 翻译软件 → 复制 → 返回原应用 → 粘贴`

缩短为：

`中文输入 → Bagayalu 翻译候选 → Enter / 快捷键 → 直接替换`

最终体验应尽量接近：

> “macOS 原生输入法突然多了一层跨语言候选能力。”

但技术上 **Bagayalu 不修改、不注入、不替代 Apple 或第三方输入法**。

---

## 2.2 产品体验原则

### P0 原则

1. **不重造输入法**
   - 第一版不做独立 InputMethodKit 输入法。
   - 不实现拼音 → 中文。
   - 不修改 Apple 拼音或搜狗候选框。

2. **不打断现有输入习惯**
   - 用户继续使用原生/第三方输入法。
   - Bagayalu 仅在中文已确认上屏后介入。

3. **像输入法，而不是翻译 App**
   - 浮层贴近文字光标。
   - 风格接近 macOS 原生候选窗。
   - 不显示明显品牌 Logo。
   - 键盘操作优先。

4. **可预测**
   - 不智能调整语言顺序。
   - 不记忆最近选择语言。
   - 不自动改默认高亮。
   - 不做过度 AI 化行为。

5. **安全优先**
   - 无法确认文本范围时，宁可不替换，也不能删错、改错用户内容。
   - 密码框、安全输入框必须跳过。

6. **优先复用**
   - 跨 App 文本读取/替换、候选浮层、位置计算、Accessibility fallback 等优先参考或复用成熟 MIT 项目。
   - 禁止为了“纯自研”重复实现已有可靠轮子。

---

# 3. 非目标

第一版明确 **不做**：

- 独立 Bagayalu 输入法
- 拼音输入引擎
- 修改 Apple 原生候选框
- 注入搜狗候选框
- InputMethodKit 主链路
- 翻译风格预设（商务 / 自然 / 简洁等）
- 术语表
- 单条重新翻译
- 最近使用语言智能排序
- 自动改变默认高亮语言
- 定时暂停功能
- 浮层手动 X/Y 偏移
- 新增翻译服务
- 远程遥测系统
- Windows / iOS / Android

---

# 4. 平台与系统要求

- 平台：**macOS only**
- 最低 macOS 版本：**与现有 Bagayalu Translate 保持一致**
- 不为 Input Assist 单独提高最低系统版本
- 权限：
  - Accessibility / 辅助功能：必需
  - 剪贴板：仅 fallback 时临时使用
  - 不申请与本功能无关的权限

---

# 5. 功能入口

Input Assist 直接整合到现有 **Bagayalu Translate**，不拆分新 App。

建议产品结构：

```text
Bagayalu Translate
├── 文本翻译
├── 快捷翻译
├── OCR 翻译
├── 钉图
├── Input Assist / 输入增强   ← 新增
└── 设置
```

---

# 6. 首次上线与引导

## 6.1 默认状态

**Input Assist 默认关闭。**

不得因为用户升级 Bagayalu 而自动打开系统级输入监听。

---

## 6.2 新功能推荐

新版本上线后展示一次新功能推荐。

推荐流程：

```text
发现新功能
    ↓
10 秒内理解功能演示
    ↓
[开启输入增强] / [以后再说]
    ↓
辅助功能权限检查
    ↓
配置目标语言
    ↓
进入测试页
```

规则：

- 主动推荐仅出现一次
- 用户跳过后不再自动弹出
- 设置页长期保留入口
- 菜单栏长期保留 Input Assist 状态入口
- 不重复骚扰

---

# 7. 核心用户流程

## 7.1 自动触发

示例：

用户在 WhatsApp / Mail / Chrome CRM 中使用 Apple 拼音输入：

```text
women keyi tigong 16 dun chuandiao
```

Apple 输入法候选：

```text
我们可以提供16吨船吊
```

用户确认中文上屏。

此时：

```text
Apple / 搜狗输入阶段结束
        ↓
中文 commit
        ↓
Bagayalu 检测新增中文
        ↓
等待输入稳定
        ↓
并行翻译目标语言
        ↓
光标附近出现候选浮层
```

候选示例：

```text
┌─────────────────────────────────────────────┐
│ EN  We can provide a 16-ton marine crane.   │
│ ES  Podemos suministrar una grúa marina...  │
│ RU  Мы можем поставить судовой кран...      │
└─────────────────────────────────────────────┘
```

用户按 `Enter`：

```text
我们可以提供16吨船吊
```

被直接替换为：

```text
We can provide a 16-ton marine crane.
```

---

## 7.2 手动触发

用户通过自定义快捷键触发。

### 有选中文字

优先翻译选中文字。

### 无选中文字

翻译当前光标前最近一段可识别文本。

手动模式允许源语言不是中文。

例如：

```text
Can you send me the quotation?
```

手动触发后，如果目标语言配置为：

```text
EN
ES
RU
```

则自动跳过 EN，只显示：

```text
ES
RU
```

---

# 8. 自动触发规则

## 8.1 触发策略

采用 **混合触发**：

### 停顿触发

中文 commit 后等待用户短暂停顿。

预设：

- 快速：200ms
- 默认：300ms
- 稳定：500ms
- 自定义：100–1000ms

### 强标点触发

遇到以下标点可提前认为语义边界成立：

```text
。 ！ ？ ；
```

可绕过普通 debounce，尽快触发。

### 弱标点

以下不作为强边界：

```text
， 、
```

不得只因为逗号就机械切断翻译范围。

---

## 8.2 原生输入法保护

Bagayalu 不得与 Apple/搜狗原候选框同时争抢展示。

目标流程：

```text
输入中
↓
原生候选框存在
↓
用户 commit 中文
↓
原候选框关闭
↓
Bagayalu Candidate Panel 出现
```

如果无法可靠直接判断原候选框消失状态，可使用短保护延迟：

**建议 50–100ms**

此延迟仅用于避免候选窗口视觉冲突，不替代主 debounce。

---

## 8.3 自动触发源语言

自动触发第一版只针对：

**新增中文文本。**

以下内容默认不触发：

- 纯英文
- 纯数字
- URL
- 邮箱
- 型号代码
- 地址栏输入
- 代码输入

但混合文本允许触发，例如：

```text
SQ16 Marine Crane 价格是 12000 USD
```

整体参与翻译，同时保护：

- SQ16
- Marine Crane
- 12000
- USD

等结构化内容尽量不被错误改写。

---

# 9. 翻译范围与上下文

## 9.1 核心原则

**上下文用于理解，替换范围只限本次目标文本。**

例如输入框已有：

```text
Hello John，关于你昨天问的设备，
```

用户新增：

```text
我们可以提供16吨船吊
```

翻译引擎可以获得：

```text
关于你昨天问的设备，我们可以提供16吨船吊
```

作为上下文。

但最终只能替换：

```text
我们可以提供16吨船吊
```

不得修改前文。

---

## 9.2 上下文长度

建议读取：

- 当前句
- 必要时前 1–2 个句子
- 最大约 200–300 字符

不得为了翻译当前句而读取整个长邮件或整篇文档。

---

## 9.3 多句文本

自动触发默认只处理：

**当前 / 最近一句**

不得跨多个完整句子一次性替换整段。

强句界：

```text
。！？；
```

---

## 9.4 短文本

不设置最小字符数。

以下高频文本必须支持：

```text
好的
可以
谢谢
收到
没问题
```

---

# 10. 目标语言

## 10.1 数量

用户可设置：

**1–6 个目标语言**

产品推荐：

**1–3 个**

配置超过 3 个时允许继续，但可轻提示：

> 候选语言较多可能降低选择效率。

---

## 10.2 排序

支持拖拽排序。

示例：

```text
EN
ES
RU
```

用户可以改为：

```text
RU
EN
ES
```

浮层严格按照配置顺序展示。

---

## 10.3 禁止智能重排

不得：

- 根据最近使用语言自动排序
- 自动把高频语言提升到第一位
- 记忆最近选中的语言
- 动态调整默认高亮

默认始终：

**高亮配置列表第一项。**

---

## 10.4 同语言过滤

若源语言与目标语言相同，自动隐藏该目标项。

例如：

源语言：

```text
English
```

目标：

```text
EN / ES / RU
```

实际显示：

```text
ES / RU
```

---

## 10.5 单语言模式

如果只有一个有效目标语言：

仍然弹出 Candidate Panel。

使用紧凑单行样式：

```text
EN   We can provide a 16-ton marine crane.
```

默认高亮，Enter 替换。

---

# 11. Candidate Panel 候选浮层

## 11.1 产品定位

Candidate Panel 是普通 AppKit 浮层。

**不是 Apple 输入法候选框。**

**不是 InputMethodKit Candidate Window。**

但视觉和行为应尽量接近 macOS 原生输入法候选体验。

---

## 11.2 视觉原则

- 贴近当前文字插入点
- 原生 macOS 圆角
- 轻阴影
- 原生字体
- 浅色 / 深色模式适配
- 候选高亮样式接近系统
- 不显示大 Logo
- 不做品牌色大面积装饰
- 不使用卡片式复杂 UI
- 不做夸张动画
- 最多短淡入
- Language Code 使用紧凑标识：

```text
EN
ES
RU
JA
KO
DE
```

不优先使用国旗 Emoji。

原因：

- 国旗 ≠ 语言
- 视觉噪音更高
- 系统感更弱

---

## 11.3 不显示中文 Source

在当前架构中，中文已经由 Apple / 搜狗候选确认并上屏。

因此 Bagayalu 浮层 **不重复显示中文原文**。

错误方案：

```text
中文
English
Español
Русский
```

正确方案：

```text
EN
ES
RU
```

只有未来如果 Bagayalu 真正成为独立输入法，才重新考虑 Source Candidate。

---

# 12. Loading / Skeleton

## 12.1 原则

各目标语言并行翻译。

浮层第一次出现时立即占好所有目标语言槽位。

例如：

```text
EN  ▰▰▰▰▰▰▰▰
ES  ▰▰▰▰▰▰▰
RU  ▰▰▰▰▰▰▰▰
```

随后独立替换：

```text
EN  We can provide a 16-ton marine crane.
ES  ▰▰▰▰▰▰▰
RU  ▰▰▰▰▰▰▰▰
```

再：

```text
EN  We can provide a 16-ton marine crane.
ES  Podemos suministrar una grúa marina...
RU  ▰▰▰▰▰▰▰▰
```

---

## 12.2 禁止行为

不得随着每个翻译返回而不断增加 Panel 高度。

即：

不要：

```text
1 条
↓
2 条
↓
3 条
```

而应：

**第一次出现就固定当前语言数量对应的整体布局。**

---

# 13. 候选文本展示

## 13.1 普通候选

最多显示：

**2 行**

超过部分使用：

```text
…
```

---

## 13.2 当前高亮候选

允许展开到最多：

**4 行**

目的：

- 方便确认长译文
- 又避免 6 个语言把 Panel 拉得过高

---

## 13.3 布局

无论配置 1–6 个语言：

**始终单列纵向**

不做双列。

原因：

- 更接近原生候选
- 适合 ↑ / ↓
- 视觉扫描路径稳定
- 降低认知成本

---

# 14. 键盘交互

Candidate Panel 出现后：

| 按键 | 行为 |
|---|---|
| ↑ | 上一个候选 |
| ↓ | 下一个候选 |
| Enter | 用当前高亮译文替换原文 |
| Esc | 关闭浮层 |
| ⌘1–⌘6 | 直接选择对应目标语言并替换 |
| ⌘C | 复制当前高亮译文，不替换 |
| ⌥ 按住 | 临时显示调试信息 |
| 普通字符 | 关闭旧浮层，继续正常输入 |
| Space | 视为继续输入，关闭旧浮层 |

---

## 14.1 焦点原则

Candidate Panel **不得抢占原 App 文本框焦点**。

用户的输入焦点始终留在原文本控件。

Bagayalu 只在浮层激活期间临时处理：

- ↑
- ↓
- Enter
- Esc
- ⌘1–⌘6
- ⌘C
- ⌥ 调试态

普通文本输入必须继续送给原 App。

---

# 15. 浮层关闭规则

不设置 5 秒等固定超时。

浮层持续存在，直到出现明确用户行为。

关闭条件：

- 用户继续输入
- 用户按 Space
- 用户按 Esc
- 光标移动
- 点击其他区域
- 切换输入法
- 选择候选完成替换
- 当前输入控件失焦
- 当前应用切换

---

# 16. 位置计算

## 16.1 优先级

### Level 1

能够获取精确插入点：

→ 贴当前文字光标显示。

### Level 2

拿不到精确 text bounds，但能拿到当前 editable element：

→ 显示在文本控件附近。

### Level 3

连控件位置也无法获得：

→ fallback 到鼠标附近。

---

## 16.2 屏幕避让

优先：

```text
光标下方
```

空间不足：

```text
光标上方
```

同时需要：

- 避免出屏
- 避免 Menu Bar
- 避免 Dock
- 多显示器正确定位
- 考虑 Retina scale
- 处理不同坐标系

---

# 17. 翻译引擎

第一版只复用 Bagayalu 现有翻译引擎：

1. Apple Translation
2. Google Translate
3. OpenAI Compatible

不新增 Provider。

---

## 17.1 Provider 选择

使用：

**全局统一翻译引擎**

例如：

```text
Current Engine: Apple Translation
```

则所有：

```text
EN / ES / RU / ...
```

统一走 Apple Translation。

第一版不支持：

```text
EN → Apple
ES → Google
RU → OpenAI
```

这种语言级 Provider 配置。

---

# 18. 并发翻译

所有目标语言：

**并行请求**

禁止串行：

```text
EN 完成
↓
再 ES
↓
再 RU
```

正确：

```text
        ┌─ EN
Source ─┼─ ES
        └─ RU
```

单条完成即更新对应 Candidate Row。

---

# 19. 单条失败

某个目标语言失败：

不得让整个 Candidate Panel 失败。

例如：

```text
EN  We can provide...
ES  翻译失败
RU  Мы можем...
```

失败项支持：

**点击重试**

仅失败项重试。

注意：

“正常结果不提供手动重新翻译”。

---

# 20. Apple Translation 语言包

若目标语言缺少本地语言包：

对应 Candidate Row：

```text
ES  需要下载语言包
```

用户可点击触发 / 引导完成资源准备。

其他语言继续工作。

不得整个 Panel 阻塞。

---

# 21. Translation Cache

缓存属于 P0 性能能力。

## 21.1 两级缓存

### L1 内存缓存

- 当前进程生命周期
- 极低延迟

### L2 本地持久缓存

- App 重启后继续可用
- LRU 淘汰
- 有容量上限

---

## 21.2 Cache Key

至少包括：

```text
sourceText
sourceLanguage
targetLanguage
translationEngine
```

OpenAI Compatible 后续若引入：

- prompt
- model
- style
- temperature

则必须纳入 Cache Key。

---

## 21.3 缓存管理

设置页：

```text
翻译缓存
已占用：xx MB

[清除翻译缓存]
```

清除缓存不得影响：

- 语言配置
- 快捷键
- Provider 设置
- Input Assist 开关

---

# 22. 缓存调试标识

测试阶段，如果某 Candidate 命中缓存：

右侧显示轻量：

```text
⚡
```

鼠标 hover：

```text
本地缓存命中
引擎：Apple Translation
缓存年龄：2h
响应：3ms
```

该标识主要用于：

**开发 / 早期测试验证缓存效果**

后期可通过设置关闭调试标识。

---

# 23. 性能调试模式

正常候选：

```text
EN  We can provide a 16-ton marine crane.
```

用户按住：

```text
⌥
```

临时显示：

```text
EN  We can provide a 16-ton marine crane.
    Apple · 126ms · Network

ES  Podemos suministrar...
    Apple · 143ms · Network

RU  Мы можем...
    Cache · 2ms
```

松开：

```text
⌥
```

立即恢复正常干净样式。

调试信息可包含：

- Provider
- Translation latency
- Cache hit
- Failure reason

---

# 24. 应用场景过滤

## 24.1 默认不自动触发

以下场景默认禁用自动 Input Assist：

- Password field
- Secure text field
- Terminal
- Shell
- Xcode
- VS Code 等代码编辑器
- Browser address bar
- 搜索框内极短关键词场景
- URL
- Email
- 纯数字
- 高风险不可确认 editable surface

---

## 24.2 支持的典型场景

目标覆盖：

- WhatsApp
- 微信
- Telegram
- Mail
- Outlook
- Chrome
- Safari
- CRM
- 网页 textarea / contenteditable
- Notes
- TextEdit
- Word
- 普通 NSTextField / NSTextView

---

# 25. 应用黑名单 / 白名单

提供两种模式：

## Mode A — 默认

```text
全局启用
+
黑名单排除
```

---

## Mode B

```text
仅指定 App 启用
```

---

## 优先级

安全策略 / 黑名单优先于全局规则。

---

# 26. 手动触发行为

## 26.1 有 Selection

```text
Selected Text
↓
Translate
↓
Candidate Panel
```

---

## 26.2 无 Selection

识别：

```text
光标前最近可翻译片段
```

然后触发。

---

## 26.3 非中文文本

手动触发允许翻译：

- 英文
- 西班牙语
- 俄语
- 日语
- 其他 Provider 支持语言

并自动隐藏与 Source 相同的目标语言。

---

# 27. 文本替换

## 27.1 第一版行为

用户选择 Candidate 后：

**直接替换 Source Text。**

例如：

```text
我们可以提供16吨船吊
```

↓

```text
We can provide a 16-ton marine crane.
```

不保留中文原文。

---

## 27.2 不提供

第一版不提供：

```text
中文 + 英文
```

双语插入模式。

---

# 28. Text Replace Engine

文本替换必须采用 capability-based strategy。

建议：

```text
Target Surface
    ↓
AX 可以精确读取/替换？
    ├─ YES
    │   ↓
    │ AX Direct Replace
    │
    └─ NO
        ↓
Clipboard / CGEvent fallback 可安全验证？
        ├─ YES
        │   ↓
        │ Paste Replace
        │
        └─ NO
            ↓
            Abort
```

核心原则：

> A missed translation is better than deleting or replacing the wrong text.

---

## 28.1 Undo

尽量保持目标 App 原生：

```text
⌘Z
```

可以撤销 Bagayalu 替换。

优先采用能够进入宿主 App Undo Stack 的替换方式。

---

# 29. 自动输入监听架构

自动触发是第一版 **最高技术风险点**。

macOS 并没有一个通用公开 API 直接通知：

> “Apple 拼音刚刚 commit 了一句中文。”

因此建议组合：

- Accessibility
- AX Focused Element
- AX Value Changed
- CGEvent keyboard monitoring
- 前后文本 diff
- 输入状态 tracking
- debounce
- focus tracking

大致流程：

```text
Keyboard Event
↓
Focused Editable Element
↓
AX Value Changed
↓
Before / After Diff
↓
新增中文识别
↓
输入仍在继续？
├─ YES → 延后
└─ NO
    ↓
Native IME guard
    ↓
TriggerEngine
```

---

# 30. 自动触发必须 Best-effort

PRD 不定义：

> “任何 App 100% 自动触发。”

而定义：

> “在可安全检测当前 editable surface、输入范围与 commit 状态的 App 中提供自动触发；能力不足时退化为手动快捷键。”

这样避免为了追求覆盖率引入危险的删除 / 粘贴逻辑。

---

# 31. 状态机

建议核心状态：

```text
Disabled
   ↓
Idle
   ↓
ObservingInput
   ↓
PossibleChineseCommit
   ↓
WaitingForNativeIMEEnd
   ↓
Debouncing
   ↓
PreparingContext
   ↓
Translating
   ↓
ShowingCandidates
   ├── SelectionChanged
   ├── Copy
   ├── Commit
   └── Dismiss
        ↓
       Idle
```

异常：

```text
Translating
├── PartialSuccess
├── LanguagePackMissing
├── ProviderFailed
└── SurfaceInvalidated
```

---

# 32. 推荐技术模块

建议新增：

```text
InputAssist/
├── InputAssistCoordinator.swift
│
├── Observation/
│   ├── InputObserver.swift
│   ├── FocusedElementObserver.swift
│   ├── TextDiffTracker.swift
│   └── IMEStateGuard.swift
│
├── Context/
│   ├── TextContextProvider.swift
│   ├── SentenceBoundaryDetector.swift
│   └── SourceRangeTracker.swift
│
├── Trigger/
│   ├── TriggerEngine.swift
│   ├── TriggerPolicy.swift
│   └── HotkeyTrigger.swift
│
├── Candidates/
│   ├── CandidateService.swift
│   ├── CandidateState.swift
│   ├── CandidatePanelController.swift
│   ├── CandidatePanel.swift
│   └── PopupPositioner.swift
│
├── Replacement/
│   ├── TextReplaceEngine.swift
│   ├── AXTextReplacer.swift
│   ├── PasteFallbackReplacer.swift
│   └── ReplacementSafetyGuard.swift
│
├── Cache/
│   ├── TranslationCache.swift
│   ├── MemoryCache.swift
│   └── PersistentLRUCache.swift
│
├── Filtering/
│   ├── AppFilter.swift
│   ├── SurfaceCapability.swift
│   └── SecureInputGuard.swift
│
├── Debug/
│   ├── InputAssistMetrics.swift
│   └── CandidateDebugInfo.swift
│
└── Settings/
    ├── InputAssistSettings.swift
    └── InputAssistTestView.swift
```

---

# 33. 与现有 TranslationCore 的关系

禁止复制现有翻译逻辑。

Input Assist 只调用现有 Provider 抽象。

推荐：

```text
Input Assist
    ↓
CandidateService
    ↓
TranslationCore
    ├── Apple
    ├── Google
    └── OpenAI Compatible
```

目标：

**翻译 Provider 只维护一套。**

---

# 34. 开源复用策略

原则：

> 先读成熟实现，再决定“直接抽取 / 参考重写 / 不采用”。

所有代码复用前必须再次确认：

- LICENSE
- Copyright notice
- 依赖 License
- 是否允许商业使用
- 是否需要保留 attribution
- 上游是否包含非同 License 资源

---

# 35. 第一优先级轮子：TranslateKit

项目：

https://github.com/lglot/translate-kit

License：

**MIT**

重点能力：

- Native Swift
- SwiftUI + AppKit
- AXUIElement
- 跨 App selection capture
- 跨 App replace
- CGEvent fallback
- Clipboard save / restore
- Electron / Chromium fallback
- Secure input skip
- Apple Translation
- Floating Panel
- Onboarding
- Preferences

重点参考：

```text
ReplaceEngine.swift
TranslationCoordinator.swift
AppleTranslationProvider.swift
PreferencesManager.swift
Floating Panel
```

### Bagayalu 复用建议

**最高优先级。**

优先研究其：

```text
AX Read / Replace
CGEvent fallback
Clipboard restore
Undo safety
Secure field guard
```

如果结构清晰且 License 满足要求，可以直接抽取通用实现后按 Bagayalu 架构改造。

---

# 36. 第二优先级轮子：TypeTide

项目：

https://github.com/everettjf/TypeTide

License：

**MIT**

产品能力与 Input Assist 高度接近：

```text
Select / Type
↓
Shortcut / Auto
↓
AX Capture
↓
Clipboard fallback
↓
Translate
↓
Popup / Inline Replace
```

重点模块：

```text
SelectionCapture
TextReplacer
TriggerController
SelectionMonitor
PopupPositioner
per-app skip list
translation cache
```

### Bagayalu 复用建议

重点参考：

- SelectionMonitor
- PopupPositioner
- TextReplacer
- App Skip List
- AX → Clipboard fallback
- Undo-safe paste replace

注意：

TypeTide 当前产品 baseline 与 Bagayalu 不一定一致，因此：

**不要直接整体引入其 App 架构。**

只提取可独立复用的实现思路 / 模块。

---

# 37. 第三优先级轮子：Punto Switcher

项目：

https://github.com/rshagiev/punto-switcher

重点能力：

- Last typed word tracking
- Accessibility
- Clipboard fallback
- Terminal fallback
- Capability-based replacement
- Focus change clears tracking
- 安全替换策略

最重要的工程原则：

> 如果无法确认目标区域，宁可 no-op。

### Bagayalu 重点参考

```text
last typed text tracking
focus tracking
terminal/browser capability detection
safe replacement guards
```

---

# 38. 补充轮子：UASwitcher / Traple / bilingual-switcher

可作为自动输入检测与 keyboard event tracking 的补充参考。

## UASwitcher

https://github.com/deimoc/UASwitcher

重点：

- 自动检测
- Last word
- Pure Swift + AppKit
- 输入事件处理

## Traple

https://github.com/spendolas/traple

License：

MIT

重点：

- raw keycode tracking
- TIS input source
- terminator-based detection
- per-app blacklist
- Accessibility permission handling

Traple 对 macOS 输入源切换、raw keycode 与实际插入字符差异的分析尤其有参考价值。

## bilingual-switcher

https://github.com/komandakycto/bilingual-switcher

License：

MIT

重点：

- Selected text
- Accessibility
- Clipboard fallback
- Clipboard restore
- macOS menu-bar native app

---

# 39. 候选视觉参考：MacishType

项目：

https://github.com/luke-chang/MacishType

License：

**MIT**

重点：

- macOS system-look candidate window
- Candidate UI
- Settings UI
- Native input experience

### Bagayalu 使用方式

**只参考 Candidate Window 视觉和布局。**

不引入：

- InputMethodKit host
- 输入法引擎
- .cin runtime
- JS engine

Bagayalu 第一版不是输入法。

---

# 40. 候选交互参考：SwiftType

项目：

https://github.com/mgxv/SwiftType

重点：

- Floating candidate window
- Candidate selection
- `1–6`
- ↑ / ↓
- Return
- Escape
- Candidate state
- Theme system
- 大量测试

### Bagayalu 使用方式

参考：

- Candidate Window 状态机
- 键盘导航
- selection logic
- candidate test design

不引入：

- IMKServer
- InputController
- KenLM
- InputMethodKit 主链路

---

# 41. 开源轮子复用优先级

| 等级 | 项目 | 用途 |
|---|---|---|
| P0 | TranslateKit | AX 捕获 / 替换 / fallback |
| P0 | TypeTide | Popup / Replace / Position / Trigger |
| P0 | Punto Switcher | last typed text / safety |
| P1 | Traple | keyboard tracking / TIS / terminator |
| P1 | MacishType | 原生候选视觉 |
| P1 | SwiftType | candidate state / keyboard UX |
| P2 | UASwitcher | 自动输入检测参考 |
| P2 | bilingual-switcher | AX / clipboard 参考 |

---

# 42. 技术选型原则

开发顺序必须：

```text
Search existing implementation
↓
Read license
↓
Read tests
↓
Build small spike
↓
Reuse / adapt
↓
Only then write custom implementation
```

禁止：

```text
先写一套
↓
遇到 bug
↓
最后才发现 GitHub 已经有人解决
```

---

# 43. P0 技术 Spike

正式功能开发之前必须先验证下面 5 件事。

## Spike 1 — 跨 App 获取当前新增中文

目标 App：

- TextEdit
- Notes
- Safari textarea
- Chrome textarea
- WhatsApp / Electron 类 App

验证：

```text
刚 commit 的中文
Source Range
Cursor Position
```

是否可稳定获得。

---

## Spike 2 — Apple 拼音状态保护

验证：

- composition 中不弹
- 原生候选框未结束不弹
- commit 后能尽快触发
- 不抢输入法方向键 / Enter

---

## Spike 3 — 安全替换

验证：

```text
Source:
我们可以提供16吨船吊

Target:
We can provide a 16-ton marine crane.
```

在不同 App：

- 替换范围正确
- 光标位置正确
- Undo 正常
- Clipboard 正常恢复

---

## Spike 4 — Candidate Panel 不抢焦点

验证：

- Panel 显示
- 原文本框仍是 focused element
- ↑ / ↓ / Enter 可操作候选
- 普通字符仍进入原 App
- 普通输入时 Panel 立即关闭

---

## Spike 5 — 自动触发可靠性

统计：

```text
100 次中文 commit
```

分别测：

- TextEdit
- Notes
- Safari
- Chrome
- WhatsApp

记录：

- 正确触发
- 漏触发
- 误触发
- composition 未结束提前触发
- Source Range 错误
- Replace 错误

---

# 44. 安全红线

任何情况下：

## 禁止自动操作

- AXSecureTextField
- Password input
- 无法确认 focused element
- 无法确认 Source Range
- 当前 App 刚发生 focus change
- Source 文本与预期 diff 不一致
- Candidate 产生后原文本已被用户修改
- 当前 caret 已移动

---

## Commit 前必须二次验证

在用户按 Enter / ⌘1–6 时：

重新读取目标控件。

确认：

```text
Current Source Range Text
==
Candidate 生成时 Source Text
```

若不一致：

**取消替换并关闭 Panel。**

防止：

1. 用户输入完中文
2. Candidate 出现
3. 用户又移动光标 / 编辑
4. 旧 Candidate 把错误位置替换

---

# 45. Candidate Snapshot

Candidate Panel 创建时保存：

```text
CandidateSession
├── sessionId
├── appBundleId
├── focusedElementIdentity
├── sourceText
├── sourceRange
├── cursorRect
├── context
├── createdAt
└── candidates[]
```

Commit 前必须进行 session validation。

---

# 46. 应用兼容等级

建议内部维护：

## Level A

完整支持：

- Auto Trigger
- Cursor Position
- AX Replace
- Undo

## Level B

支持：

- Auto Trigger
- Fallback Position
- Paste Replace

## Level C

只支持：

- Manual Trigger
- Selection
- Clipboard fallback

## Level D

禁用 Input Assist。

UI 不一定暴露 ABCD，但内部 capability model 必须存在。

---

# 47. Input Assist 设置页

建议：

```text
输入增强

[ ] 启用输入增强

触发
[x] 自动触发
自动触发速度：默认 300ms

手动触发快捷键
⌥ Space

目标语言
☰ English
☰ Español
☰ Русский
[+ 添加语言]
最多 6 个

翻译引擎
Apple Translation

应用范围
● 全局启用
○ 仅指定应用

黑名单
Terminal
Xcode
VS Code
...

缓存
已使用 18.4 MB
[清除缓存]

调试
[x] 显示缓存命中 ⚡

[打开输入增强测试]
```

---

# 48. Input Assist 测试页

必须提供。

目的：

用户开启权限和配置后立即验证功能。

测试内容：

```text
在此输入中文：
[                              ]
```

支持验证：

- Auto Trigger
- Manual Trigger
- Target order
- Candidate position
- Skeleton
- ↑ / ↓
- Enter
- Esc
- ⌘1–⌘6
- ⌘C
- Cache ⚡
- ⌥ Debug
- Direct Replace
- Undo

测试页应显示一个轻量状态：

```text
Accessibility    ✓
Input Monitor    ✓
Translation      ✓
Cache            ✓
```

---

# 49. 本地 Metrics

第一版只做：

**Local Metrics**

不因为 Input Assist 新增远程 analytics SDK。

记录：

- Input Assist enabled
- Auto trigger count
- Manual trigger count
- Candidate show count
- Candidate commit count
- Candidate copy count
- Dismiss by Esc
- Dismiss by continued typing
- Target language usage
- Provider success rate
- Provider failure rate
- Average latency
- Cache hit rate
- AX replace success
- Paste fallback count
- Safe abort count

---

# 50. Metrics 隐私

本地统计默认：

**不记录原文与译文正文。**

只记录：

```text
timestamp
triggerType
provider
targetLanguage
latency
cacheHit
result
replacementStrategy
appBundleId（如产品隐私策略允许）
```

不得为了性能统计保存用户聊天正文。

---

# 51. 性能目标

以下作为目标而非硬性跨机器 SLA：

## Cache Hit

Candidate 应接近即时：

```text
< 30ms 进入 UI 更新
```

## Local Apple Translation

优先追求：

```text
用户感知近即时
```

## Candidate Panel

触发后：

Skeleton 应优先出现，不等待最慢目标语言。

---

# 52. UX 验收标准

## 自动模式

- [ ] 中文 composition 期间不出现 Bagayalu
- [ ] 中文 commit 后正常触发
- [ ] Apple 原候选框未结束时不重叠
- [ ] Candidate 靠近 caret
- [ ] Panel 不抢焦点
- [ ] 第一目标语言默认高亮
- [ ] Enter 替换
- [ ] Esc 关闭
- [ ] 普通输入关闭旧 Panel
- [ ] 切换输入法关闭
- [ ] 光标移动关闭
- [ ] 不存在固定 5 秒超时

---

## 多语言

- [ ] 1–6 个目标语言
- [ ] 拖拽排序
- [ ] 推荐 ≤3
- [ ] 同源语言自动隐藏
- [ ] 始终单列
- [ ] 独立 Skeleton
- [ ] 独立成功 / 失败
- [ ] 不因为慢语言阻塞快语言

---

## 替换

- [ ] 只替换 Source Range
- [ ] 不破坏前文
- [ ] Commit 前重新验证 Source
- [ ] 尽量支持 ⌘Z
- [ ] Clipboard fallback 后恢复原 clipboard
- [ ] 无法安全操作时 Abort

---

# 53. 技术验收矩阵

至少覆盖：

| App | Auto Detect | Position | Replace | Undo | Fallback |
|---|---|---|---|---|---|
| TextEdit | ✓ | ✓ | ✓ | ✓ | - |
| Notes | ✓ | ✓ | ✓ | ✓ | - |
| Safari textarea | ✓ | ✓ | ✓ | ✓ | optional |
| Chrome textarea | ✓ | target | ✓ | ✓ | clipboard |
| WhatsApp / Electron | target | target | target | target | clipboard |
| Mail | ✓ | ✓ | ✓ | ✓ | optional |
| Password Field | blocked | - | - | - | - |
| Terminal | blocked auto | - | manual only | target | capability |

---

# 54. 测试建议

## Unit Tests

重点：

```text
TextDiffTracker
SentenceBoundaryDetector
TriggerEngine
TargetLanguageFilter
CacheKey
LRU
CandidateState
CandidateNavigation
CandidateSessionValidation
AppFilter
SecureInputGuard
```

---

## Integration Tests

重点：

```text
AX capture
AX replace
Clipboard fallback
Focus change
Caret movement
Typing while panel visible
Native IME commit
Undo
Multi-monitor popup
Dark mode
```

---

## Regression Tests

每次修改 Input Assist 后至少验证：

```text
Apple Pinyin
TextEdit
Chrome
WhatsApp/Electron
Manual Trigger
Auto Trigger
Replacement
Undo
Clipboard Restore
```

---

# 55. 推荐开发顺序

不按“页面”开发。

按风险开发：

## Phase 0 — 开源代码阅读

先完成：

- TranslateKit
- TypeTide
- Punto
- Traple

的关键代码阅读。

输出：

```text
reuse-notes.md
```

记录：

- 可直接复用
- 需要改造
- 不采用
- License note

---

## Phase 1 — Manual MVP

先实现最稳链路：

```text
选中文本
↓
快捷键
↓
翻译
↓
Candidate Panel
↓
Enter Replace
```

目标：

验证 Candidate + Replace Engine。

---

## Phase 2 — Current Sentence

实现：

```text
无 Selection
↓
识别 caret 前最近一句
↓
Candidate
↓
Replace
```

---

## Phase 3 — Auto Trigger

再进入最高风险部分：

```text
AX / keyboard observer
↓
commit detection
↓
diff
↓
debounce
↓
auto panel
```

---

## Phase 4 — Cache / Multi-language / Debug

完善：

- 1–6 语言
- parallel translation
- cache
- ⚡
- ⌥ debug
- failure row

---

## Phase 5 — Compatibility

逐 App 做 capability matrix。

---

# 56. 为什么不先做 Auto Trigger

Auto Trigger 是整个方案最不确定的部分。

如果一开始所有代码都围绕自动监听写：

一旦 macOS / Electron / AX 行为存在差异，容易拖垮整个功能。

Manual MVP 可以先验证：

- Candidate UI
- Translation concurrency
- Replace Engine
- Session safety
- Cache
- Keyboard UX

这些全部都可以复用到 Auto Trigger。

---

# 57. 为什么不做 InputMethodKit

第一版不需要。

当前产品价值来自：

```text
用户继续使用最熟悉输入法
+
Bagayalu 提供翻译候选层
```

而不是：

```text
Bagayalu 成为中文输入法
```

使用 InputMethodKit 会引入：

- 拼音引擎
- 中文候选质量
- 输入法切换
- 安装 Input Source
- IMK 生命周期
- 用户迁移成本
- 与成熟输入法直接竞争

投入与第一版产品验证目标不匹配。

---

# 58. 架构总结

最终推荐链路：

```text
┌──────────────────────────────┐
│ Apple / 搜狗 / 其他中文输入法 │
└───────────────┬──────────────┘
                │
          中文 commit
                │
                ▼
┌──────────────────────────────┐
│ InputObserver / AX / CGEvent │
└───────────────┬──────────────┘
                │
            Text Diff
                │
                ▼
┌──────────────────────────────┐
│ TriggerEngine                │
│ debounce / punctuation / IME │
└───────────────┬──────────────┘
                │
                ▼
┌──────────────────────────────┐
│ TextContextProvider          │
│ Context + Exact Source Range │
└───────────────┬──────────────┘
                │
                ▼
┌──────────────────────────────┐
│ TranslationCore              │
│ Apple / Google / OpenAI      │
└───────────────┬──────────────┘
                │
          Parallel Results
                │
                ▼
┌──────────────────────────────┐
│ TranslationCache             │
└───────────────┬──────────────┘
                │
                ▼
┌──────────────────────────────┐
│ CandidatePanel               │
│ EN / ES / RU / ...           │
└───────────────┬──────────────┘
                │
          Enter / ⌘1–6
                │
                ▼
┌──────────────────────────────┐
│ TextReplaceEngine            │
│ AX → Clipboard Fallback      │
└──────────────────────────────┘
```

---

# 59. 一句话产品定义

> **Bagayalu Input Assist 是运行在 macOS 原生输入法之后的一层跨语言输入增强：用户正常用中文输入，Bagayalu 在中文确认后自动给出多语言候选，并像选择输入法候选一样一键用译文替换原文。**

---

# 60. 第一版成功标准

第一版成功不以“支持所有 App”为标准。

成功标准是：

1. 用户不需要改变原来的中文输入法。
2. Manual Trigger 足够可靠。
3. 主流文本 App 自动触发体验稳定。
4. Candidate Panel 足够像系统输入体验。
5. 选择译文可以安全替换。
6. 不发生错误文本删除。
7. Cache 明显改善重复短句响应。
8. 用户能在几乎不离开键盘的情况下完成跨语言输入。

---

# 61. 开发前 Checklist

- [ ] 阅读 TranslateKit ReplaceEngine
- [ ] 阅读 TypeTide TextReplacer
- [ ] 阅读 TypeTide PopupPositioner
- [ ] 阅读 TypeTide SelectionMonitor
- [ ] 阅读 Punto last typed tracking
- [ ] 阅读 Punto capability-based replace
- [ ] 阅读 Traple raw key / TIS 处理
- [ ] 阅读 MacishType candidate UI
- [ ] 阅读 SwiftType candidate state / tests
- [ ] 逐一确认 LICENSE
- [ ] 建立 reuse-notes.md
- [ ] 完成 Manual Replace Spike
- [ ] 完成 non-focus Candidate Panel Spike
- [ ] 完成 Auto Trigger Spike
- [ ] 再进入正式产品代码

---

# 62. 参考项目

## TranslateKit

https://github.com/lglot/translate-kit

MIT

---

## TypeTide

https://github.com/everettjf/TypeTide

MIT

---

## Punto Switcher

https://github.com/rshagiev/punto-switcher

---

## UASwitcher

https://github.com/deimoc/UASwitcher

---

## Traple

https://github.com/spendolas/traple

MIT

---

## bilingual-switcher

https://github.com/komandakycto/bilingual-switcher

MIT

---

## MacishType

https://github.com/luke-chang/MacishType

MIT

---

## SwiftType

https://github.com/mgxv/SwiftType

---

# 63. 最终开发约束

> **先复用，再改造，最后才手搓。**

任何涉及以下能力的新实现：

- AX text capture
- AX replace
- clipboard fallback
- popup positioning
- last typed tracking
- candidate keyboard navigation
- focus tracking
- secure input guard

在提交自研代码前，应先确认上述参考项目是否已有可复用实现。

目标不是代码“原创度”，而是：

**更少 bug、更少兼容性坑、更快达到稳定可用。**
