# Input Assist — 开源复用调研（Phase 0 产出）

> 对应 PRD §34 / §41 / §42 / §55 Phase 0 / §61 Checklist。
> 调研时间：2026-08-23。所有仓库均已 clone 到本地实际阅读源码，不是只看 README。
> 结论分四档：**直接抽取** / **参考重写** / **仅参考思路** / **不采用**。

---

## 0. 一句话结论

八个参考项目里，**能解决替换与定位的有三个，能解决自动触发的一个也没有。**

替换、剪贴板恢复、弹层定位、黑名单、缓存这些"苦活"确实都有成熟实现，照抄能省不少坑；
但 PRD 里风险最高的 Spike 2（Apple 拼音 commit 检测 / composition 保护），
**八个项目零覆盖**——没有任何一个从进程外判断过输入法组字状态。
这恰好印证了 PRD §55「Auto Trigger 放最后」的排期是对的。

---

## 1. LICENSE 核查结果（PRD §34 要求逐一确认）

| 项目 | PRD 标注 | 实际核查 | 可用性 |
|---|---|---|---|
| lglot/translate-kit | MIT | ✅ MIT | 可抽取，保留 copyright |
| everettjf/TypeTide | MIT | ✅ MIT | 可抽取，保留 copyright |
| luke-chang/MacishType | MIT | ✅ MIT | 可抽取，保留 copyright |
| deimoc/UASwitcher | MIT | ✅ MIT | 可抽取，保留 copyright |
| spendolas/traple | MIT | ⚠️ MIT，但 GitHub 识别为 NOASSERTION | 可用（见下） |
| komandakycto/bilingual-switcher | MIT | ✅ MIT | 可用 |
| **rshagiev/punto-switcher** | 未标注 | ❌ **仓库无 LICENSE 文件** | **不得抄代码** |
| **mgxv/SwiftType** | 未标注 | ❌ **仓库无 LICENSE 文件** | **不得抄代码** |

### 需要注意的两点

**punto-switcher 与 SwiftType 没有开源许可。** 没有 LICENSE 文件 = 默认保留所有权利，
不是"可以随便用"。PRD §41 把 punto-switcher 排在 P0，但按 §34「所有代码复用前必须再次确认
LICENSE」的规矩，它只能用来读思路（"确认不了目标区域就 no-op"这类工程原则），
**不能抽取任何代码**。SwiftType 同理。这两个项目在本文档里一律归入「仅参考思路」。

顺带一提，traple 的 LICENSE 里写着它的注入时序参考自 punto-switcher 并标注其为 MIT——
这个标注和上游实际情况对不上，不能作为依据。

**traple 被 GitHub 识别为 NOASSERTION 是误报。** 实际 LICENSE 文件正文是标准 MIT，
只是尾部附加了第三方数据来源说明（词表来自 keyswitcher，MIT），导致识别器不认。
我们只用它的 Swift 代码，不碰 `Resources/*.json` 词表，MIT 条款成立。

---

## 2. 直接可抽取的实现

### 2.1 AX 能力探测 + 写回验证（translate-kit `ReplaceEngine.swift`）

这是整份调研里**最值钱的一段**，直接对应 PRD §28 的 capability-based 策略。

关键在于它没有假设「AX 能读就能写」，而是分两步确认：

```swift
// 1. 写之前先问系统这个属性到底能不能写
AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)

// 2. 写完之后再读回来比对——有些 App（Chromium）会接受 set 调用然后悄悄忽略它
let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
let written = stringAttribute(element, kAXValueAttribute)
if err != .success || written == old {
    // 降级到 ⌘A + 粘贴
}
```

`err == .success` 但内容没变——这个坑不实际踩一次基本想不到。

另外两处小而关键的写法：

- `IsSecureEventInputEnabled()` 作为替换前的硬闸门（PRD §44 安全红线）。
  这是全系统级的安全输入状态，比逐个判断 `AXSecureTextField` 更早也更可靠，**两者都要**。
- 取 focused element 时校验 `CFGetTypeID(value) == AXUIElementGetTypeID()` 再转换。
  TypeTide 那边直接 `as! AXUIElement` 强转，属性返回非预期类型时会崩。

**结论：直接抽取，按 Bagayalu 架构改造。** 落到 `AXTextCapture` + `TextReplaceEngine`。

### 2.2 AX → Cocoa 坐标翻转必须用主屏高度（TypeTide `PopupPositioner.swift`）

```swift
// ✅ 正确：两套坐标系都以主屏（screens[0]）为基准互为上下翻转
let primaryHeight = NSScreen.screens.first?.frame.maxY ?? (NSScreen.main?.frame.height ?? 0)
let cocoaY = primaryHeight - axRect.origin.y - axRect.size.height
```

源码注释里写明这是他们的 issue #4：早期用「所有屏幕的全局 maxY」翻转，
一旦副屏比主屏更高或更靠上，整体就会偏移，弹窗直接落到另一台显示器上。

PRD §16.2 要求「多显示器正确定位」，这条是唯一一处别人已经用 bug 换来的答案，**照抄**。

配套的 `kAXBoundsForRangeParameterizedAttribute` 拿精确插入点、
拿不到再退化到 `kAXPosition`/`kAXSize` 整个控件、再退化到鼠标位置，
正好是 PRD §16.1 的 Level 1/2/3 三级，结构可以直接沿用。

**结论：直接抽取。** 落到 `CandidatePanelPositioner`（纯函数，可单测）。

### 2.3 剪贴板深拷贝快照 / 恢复（TypeTide `Pasteboard.swift`）

按 `item.types` 逐类型 `setData` 深拷贝，而不是只存 `string(forType:)`。
只存字符串的话，用户剪贴板里原本的图片、富文本、文件引用在 fallback 之后就没了。

两个项目在时序上不一致，值得记一下：

| | 复制取词等待 | 粘贴后恢复延迟 |
|---|---|---|
| TypeTide | 20×20ms 轮询 changeCount（≤400ms） | 固定 150ms |
| translate-kit | 30ms 轮询（≤350ms） | 固定 300ms |

粘贴后恢复太早会把还没被目标 App 读走的内容覆盖掉。150ms 偏激进，
我们取 **250ms**，并且和 TypeTide 一样用 `changeCount` 轮询而不是死等。

**结论：直接抽取。** 落到 `PasteboardSnapshot`。

### 2.4 黑名单匹配要同时比对三个标识（TypeTide `AppSettings.swift`）

```swift
let candidates = [
    app.localizedName,
    app.bundleIdentifier,
    app.bundleURL?.deletingPathExtension().lastPathComponent
]
```

用户在 UI 上填的可能是 "Terminal"、"com.apple.Terminal" 或 "Terminal.app"，
三种都得认，并且统一小写、去掉 `.app` 后缀再比。

traple 的默认黑名单也可以直接拿来做我们的初始值——它已经覆盖了终端、
VS Code、Xcode、钥匙串和几个密码管理器，和 PRD §24.1 的清单高度重合。

**结论：直接抽取。** 落到 `AppFilter`。

---

## 3. 参考重写（结构可用，但不能照搬）

### 3.1 候选浮层的视觉底子（MacishType `MacishBasePanel.swift`）

原生候选窗的观感来自三件事，源码里都能看到：

```swift
styleMask: [.borderless, .nonactivatingPanel]
level = .floating
// 背景用 NSVisualEffectView
material = .hudWindow
blendingMode = .behindWindow
```

`.hudWindow` + `.behindWindow` 才有系统候选框那种半透明质感，
普通 `Color(nsColor:)` 填充做不出来。高亮行用 `selectedContentBackgroundColor`，
圆角走 `insetRect.height / 2` 的胶囊形。

它的 Base16Metrics 用「以 16pt 为基准线性缩放」来处理字号变化，
这个思路和 Bagayalu 现有 `AppTextFontSize` 的 scale 写法是一致的，可以对齐。

**但不引入它的 `MacishBasePanel`**：那个类背着 InputMethodKit 客户端窗口层级
（`impl.clientWindowLevel + 1`）、分页箭头、横排/竖排/可展开三套面板和主题管理器，
695 行里我们真正需要的不到 30 行。PRD §39 也明确说只参考视觉。

**结论：参考重写。** 只抄视觉常量与 backdrop 构造。

### 3.2 弹层生命周期（TypeTide `PopupController.swift`）

结构（`show/close` + 外部点击监听 + Esc 监听）可以借，
**但它的按键处理方式我们不能用**，这是 Phase 1 最重要的一个架构分歧，单开一节说。

---

## 4. 最大的架构分歧：按键拦截

TypeTide 的弹窗这样收 Esc：

```swift
keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ... }
```

`addLocalMonitorForEvents` **只在本 App 是 key window 时才会收到事件**。
TypeTide 能这么写，是因为它的弹窗允许抢焦点。

PRD §14.1 的要求正好相反：

> Candidate Panel **不得抢占原 App 文本框焦点**……
> 普通文本输入必须继续送给原 App。

也就是说，浮层出现期间，我们要在**别的 App 持有焦点**的前提下：
吃掉 ↑ / ↓ / Enter / Esc / ⌘1–6 / ⌘C，同时把普通字符原样放行。
`addLocalMonitorForEvents` 做不到，`addGlobalMonitorForEvents` 能收但**不能吞**。

唯一可行的是 **`.defaultTap` 的 CGEvent tap**（traple 的 `KeyboardMonitor` 用的就是这个，
返回 `nil` 即吞掉事件）。

这里和本项目历史决策直接冲突，必须写明白：

> 开发日志 2026-08-23 记过，全局快捷键监听从 `.defaultTap` 改成了 `.listenOnly`，
> 理由是"回调从不修改或吞掉事件，主动 tap 只会把本进程插进全系统键盘输入的必经之路上，
> 卡顿时还会被系统判定超时而停用"。

那条结论没有错，也不该被推翻。区别在于：

- `GlobalHotkeyMonitor` 需要**长期常驻**监听 ⌘C/⌘X，永远不吞事件 → 继续 `.listenOnly`。
- Input Assist 的按键拦截**只在候选浮层可见的那几秒存在**，并且确实需要吞事件
  → 只能 `.defaultTap`，但**用完立刻拆掉**。

所以新增的 tap 必须满足三条硬约束，缺一条就会重蹈"卡顿被系统停用"的覆辙：

1. 生命周期严格绑定浮层：`show` 时建，`dismiss` 时立刻 invalidate，不复用、不常驻。
2. 回调里只做 keyCode 比对和一次 `Task { @MainActor }` 派发，**绝不同步做翻译、AX 读写或任何 IO**。
3. 处理 `.tapDisabledByTimeout` / `.tapDisabledByUserInput`，被停用时重新 enable。

另外从 traple 学到一个必须要有的东西——**注入事件自标记**：

```swift
private let kInjectionMarker: Int64 = 0x4C53574954434852
// 回调开头
if event.getIntegerValueField(.eventSourceUserData) == kInjectionMarker {
    return Unmanaged.passRetained(event)   // 我们自己发的，别再处理一遍
}
```

我们替换文本时会合成 ⌘V，如果不打标记，自己发的按键会重新进自己的 tap。
Phase 3 做自动触发时这个问题会更严重（替换产生的文本变化会被当成用户新输入）。
**从 Phase 1 就带上，不要等出问题再补。**

---

## 5. 仅参考思路（不取代码）

### punto-switcher（无 LICENSE）

值得记住的只有一句工程原则，PRD §28 已经写进去了：

> 确认不了目标区域，宁可 no-op。

以及 focus change 要清空 last-typed 追踪状态。这两条是设计约束，不需要代码。

### SwiftType（无 LICENSE）

PRD §40 想参考它的候选状态机和键盘导航测试设计。
候选导航本身（index 加减、边界处理、⌘1–6 直选）逻辑简单到不值得冒许可风险，
我们自己写成纯函数 `CandidateNavigation` 并配单测即可。

### UASwitcher / bilingual-switcher

`IsSecureEventInputEnabled()` 的用法 UASwitcher 里有，但 translate-kit 已经覆盖。
UASwitcher 有一处判断值得记：它按触发方式决定 tap 选项——
`triggerConfig.isCapsLock ? .defaultTap : .listenOnly`，
即**只有确实需要吞事件时才用主动 tap**。和第 4 节的结论一致。

---

## 6. 不采用

| 东西 | 出处 | 不采用的原因 |
|---|---|---|
| InputMethodKit / IMKServer | MacishType, SwiftType | PRD §3 / §57 明确排除 |
| 键盘布局转换（RU↔EN 映射表） | traple, punto, UASwitcher, bilingual | 我们做的是翻译，不是布局纠正，映射表无关 |
| 各自的 Translation Provider | translate-kit, TypeTide | PRD §33：Provider 只维护一套，走现有 TranslationCore |
| `MacishBasePanel` 整体 | MacishType | 695 行里绝大部分服务于 IMK 场景，见 3.1 |
| TypeTide 的 App 架构 | TypeTide | PRD §36 已明确要求不整体引入 |
| 它们的 TranslationCache | TypeTide | 只有 L1 内存 LRU，PRD §21 要求 L1+L2 两级持久化，重写 |

---

## 7. 空白区：没有任何项目解决过的问题

以下是 PRD 要求、但八个参考项目**全部零覆盖**的部分，只能自研。
写在这里是为了让排期时心里有数——这些地方不会有现成答案。

### 7.1 输入法 composition 状态检测（PRD Spike 2）——**完全空白**

全仓库检索 `markedText` / `hasMarkedText` / `AXMarkedRange` / composition，
只有 MacishType 命中，而它是**作为输入法本身**从 `InputEngineContext.markedText`
读自己的组字状态。**从进程外判断别人的输入法是否在组字，没有任何先例。**

八个项目里也**没有一个使用 `AXObserver`**（检索 `AXObserverCreate` /
`kAXValueChangedNotification` / `kAXFocusedUIElementChangedNotification` 零命中）——
它们全部依赖「鼠标抬起」或「快捷键」这类用户主动动作来取词，
从来不需要知道文本框内容是怎么变的。

PRD §29 设想的 `AX Value Changed → 前后 diff → 新增中文识别` 这条链路，
**是这份 PRD 里唯一一段没有任何参考实现的架构**。这也是它被排到 Phase 3 的原因。

### 7.2 多语言并行候选

参考项目全是"一次一个目标语言"。PRD §12 / §18 要求
"一次出 1–6 个语言、各自独立 skeleton / 成功 / 失败"，没有现成结构可抄。

更麻烦的是本项目自身的约束：现有 `AppleTranslationCoordinator`
**同一时刻只能处理一个请求**（单个 `continuation` + `pendingRequest`，
新请求进来会 `cancelPending` 掉旧的），并且依赖 SwiftUI `.translationTask`
把 session 送进来。Apple 引擎要并行出 N 个语言，
就必须有 N 个 coordinator、N 个 `.translationTask`。这一节在实现里单独处理。

### 7.3 替换前的 session 二次校验（PRD §44 / §45）

translate-kit 的 `last` 只是为了"再按一次撤销"，
TypeTide 干脆不校验。PRD 要求的
「Commit 前重新读取目标控件，比对 Source Range 文本是否与生成候选时一致，不一致就放弃替换」
没有参考实现，自研。

---

## 7.4 补记：这些空白最后是怎么填的

Phase 3 做完之后回填，方便下次有人读到这里时不用再重新想一遍。

**composition 检测：绕开了，没有去解。**
既然从进程外问不出「输入法现在在不在组字」，那就不问状态，只看**新出现的文字长什么样**：
中文输入法开着、新增内容却全是 ASCII 字母 → 那是还没上屏的拼音，等着；
一旦出现汉字 → 已经 commit 了。
判定逻辑落在 `InputAssistAutoTriggerPolicy.classify`，纯函数，有单测。

**AXObserver：确实得自己写。**
`InputAssistFocusObserver` 给前台 App 的 pid 建 observer，监听
`kAXFocusedUIElementChanged`，焦点落定后再给那个控件挂 `kAXValueChanged` 和
`kAXSelectedTextChanged`。挂不上就挂不上——那个 App 的自动触发不可用，
手动快捷键照常，这就是 PRD §30 说的 best-effort。

**PRD §32 建议的 TextDiffTracker 最后没有做，而且不做更稳。**
拼音 `nihao`（5 字符）被 commit 成「你好」（2 字符）时**光标是往回跳的**，
任何「只往前增长」的 diff 在这里都会失效，放宽成通用 diff 又会把组字过程中的
每一次抖动当成新输入。改成记住「这轮输入开始时光标在哪」这一个锚点，
新增内容永远是 `value[burstStart ..< caret]`，组字期间光标怎么跳都不影响这个区间的定义。

**PRD §8.2 的 50–100ms 保护延迟：普通 debounce 已经覆盖了。**
时间基准本来就是「最后一次 AX 文本变化」，而原生候选框正是在 commit
（也就是那次文本变化）的瞬间关闭的，200–500ms 的 debounce 足够。
只有强标点绕过 debounce 那条路径才单独留了 80ms。因此**没有**为自动触发再挂一个常驻键盘 tap。

---

## 8. 落地映射

| PRD §32 建议模块 | 来源 | 档位 |
|---|---|---|
| `AXTextCapture` | translate-kit ReplaceEngine | 直接抽取 |
| `TextReplaceEngine` | translate-kit ReplaceEngine | 直接抽取 |
| `PasteboardSnapshot` | TypeTide Pasteboard | 直接抽取 |
| `CandidatePanelPositioner` | TypeTide PopupPositioner | 直接抽取 |
| `AppFilter` | TypeTide AppSettings + traple 默认黑名单 | 直接抽取 |
| `SecureInputGuard` | translate-kit + UASwitcher | 直接抽取 |
| `CandidatePanel`（视觉） | MacishType | 参考重写 |
| `CandidateKeyTap`（按键拦截） | traple KeyboardMonitor | 参考重写，见 §4 |
| `CandidateNavigation` | — | 自研（许可风险规避） |
| `TranslationCache` L1+L2 | — | 自研（PRD 要求两级） |
| `CandidateSession` 校验 | — | 自研（无先例） |
| `InputAssistFocusObserver` | — | 自研（无先例） |
| `InputAssistAutoTriggerPolicy` | — | 自研（无先例） |
| `InputAssistAppCompatibility` | — | 自研（PRD §46） |

---

## 9. 复核清单（PRD §61 对照）

- [x] 阅读 TranslateKit ReplaceEngine
- [x] 阅读 TypeTide TextReplacer
- [x] 阅读 TypeTide PopupPositioner
- [x] 阅读 TypeTide SelectionMonitor
- [x] 阅读 Punto last typed tracking → 无 LICENSE，仅取原则不取码
- [x] 阅读 Punto capability-based replace → 同上；能力探测改用 translate-kit 的实现
- [x] 阅读 Traple raw key / TIS 处理
- [x] 阅读 MacishType candidate UI
- [x] 阅读 SwiftType candidate state / tests → 无 LICENSE，改自研
- [x] 逐一确认 LICENSE（见 §1，两个项目不合格）
- [x] 建立 reuse-notes.md（本文件）
