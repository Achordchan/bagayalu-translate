import AppKit
import ApplicationServices
import Foundation

/// 焦点与文本变化监听。
///
/// **这是整个功能里唯一没有参考实现的一段。** 调研过的八个开源项目
/// （见 `InputAssist-reuse-notes.md` §7.1）没有一个用过 `AXObserver`——
/// 它们全靠「鼠标抬起」或「快捷键」这类用户主动动作取词，
/// 从来不需要知道文本框的内容是怎么变的。
///
/// 这里的做法：
/// - 给前台 App 的 pid 建一个 `AXObserver`，监听 `kAXFocusedUIElementChanged`；
/// - 焦点落到某个控件上之后，再给那个控件挂 `kAXValueChanged` 和 `kAXSelectedTextChanged`；
/// - 前台 App 变了就整个重建。
///
/// 这条链路是 best-effort（PRD §30）：有些 App 根本不发 `kAXValueChanged`，
/// 那就自动退化成只有手动快捷键可用，而不是去猜。
@MainActor
final class InputAssistFocusObserver {
    /// 焦点控件变了（可能变成 nil）。
    var onFocusedElementChanged: ((AXUIElement?) -> Void)?
    /// 当前焦点控件的文本内容变了。
    var onFocusedValueChanged: ((AXUIElement) -> Void)?
    /// 光标 / 选区变了。
    var onSelectionChanged: ((AXUIElement) -> Void)?

    /// 允不允许监听我们自己这个进程。
    ///
    /// 默认不允许——否则用户在主窗口原文框或设置页黑名单编辑器里打字都会触发。
    /// 唯一的例外是输入增强测试页：PRD §48 要求它能就地验证自动触发，
    /// 由外部在「测试窗口是当前 key window」时放行。
    var isOwnApplicationObservationAllowed: () -> Bool = { false }

    private(set) var isRunning = false
    private(set) var focusedElement: AXUIElement?

    private var observer: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private var observedProcessIdentifier: pid_t?
    private var workspaceObserver: (any NSObjectProtocol)?
    private var keyWindowObserver: (any NSObjectProtocol)?

    private static let focusChangedNotification = kAXFocusedUIElementChangedNotification as CFString
    private static let valueChangedNotification = kAXValueChangedNotification as CFString
    private static let selectionChangedNotification = kAXSelectedTextChangedNotification as CFString

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAttachment()
            }
        }
        // 在自己 App 内部换窗口不会触发 didActivateApplication，
        // 但「现在 key 的是不是测试窗口」恰恰会因此改变，所以也要跟。
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAttachment()
            }
        }
        refreshAttachment()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        keyWindowObserver = nil
        detachObserver()
        focusedElement = nil
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }

    // MARK: - Private

    private func refreshAttachment() {
        guard isRunning else { return }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            detachObserver()
            updateFocusedElement(nil)
            return
        }

        let isOwnApplication = application.bundleIdentifier == Bundle.main.bundleIdentifier
        if isOwnApplication, !isOwnApplicationObservationAllowed() {
            // 前台是我们自己，而且不是测试页：不监听。
            detachObserver()
            updateFocusedElement(nil)
            return
        }

        let pid = application.processIdentifier
        guard pid != observedProcessIdentifier else { return }

        detachObserver()

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<InputAssistFocusObserver>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            // AXObserver 的回调投递在我们注册的那个 runloop 上，也就是主线程。
            MainActor.assumeIsolated {
                observer.handle(notification: notification as String, element: element)
            }
        }

        guard AXObserverCreate(pid, callback, &newObserver) == .success,
              let createdObserver = newObserver else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let error = AXObserverAddNotification(
            createdObserver,
            applicationElement,
            Self.focusChangedNotification,
            refcon
        )
        guard error == .success || error == .notificationAlreadyRegistered else {
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .defaultMode
        )

        observer = createdObserver
        observedApplicationElement = applicationElement
        observedProcessIdentifier = pid

        updateFocusedElement(InputAssistAXTextCapture.focusedElement())
    }

    private func detachObserver() {
        if let observer {
            if let observedApplicationElement {
                AXObserverRemoveNotification(
                    observer,
                    observedApplicationElement,
                    Self.focusChangedNotification
                )
            }
            if let focusedElement {
                AXObserverRemoveNotification(observer, focusedElement, Self.valueChangedNotification)
                AXObserverRemoveNotification(
                    observer,
                    focusedElement,
                    Self.selectionChangedNotification
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        observedApplicationElement = nil
        observedProcessIdentifier = nil
        // 必须一起清掉：留着上一个 App 的元素，下次 updateFocusedElement
        // 会拿新 observer 去摘一个根本不属于它的通知。
        focusedElement = nil
    }

    private func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            updateFocusedElement(InputAssistAXTextCapture.focusedElement())
        case kAXValueChangedNotification:
            guard let focusedElement, CFEqual(focusedElement, element) else { return }
            onFocusedValueChanged?(focusedElement)
        case kAXSelectedTextChangedNotification:
            guard let focusedElement, CFEqual(focusedElement, element) else { return }
            onSelectionChanged?(focusedElement)
        default:
            break
        }
    }

    private func updateFocusedElement(_ element: AXUIElement?) {
        if let focusedElement, let observer {
            AXObserverRemoveNotification(observer, focusedElement, Self.valueChangedNotification)
            AXObserverRemoveNotification(observer, focusedElement, Self.selectionChangedNotification)
        }

        focusedElement = element

        if let element, let observer {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            // 挂不上就挂不上：这个 App 不发通知，自动触发对它不可用，
            // 手动快捷键仍然照常工作（PRD §30 best-effort）。
            _ = AXObserverAddNotification(
                observer,
                element,
                Self.valueChangedNotification,
                refcon
            )
            _ = AXObserverAddNotification(
                observer,
                element,
                Self.selectionChangedNotification,
                refcon
            )
        }

        onFocusedElementChanged?(element)
    }
}
