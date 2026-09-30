import Foundation

// MARK: - 平台适配层协议（规格 C3：所有平台调用封在薄适配层内）

/// Host 侧输入执行。真实实现走 CGEvent（需要辅助功能权限）；记录实现用于无权限验证。
public protocol InputSink: AnyObject {
    func deliver(_ event: KeyEvent)
    func deliver(_ event: PointerEvent)
    func releaseAllModifiers(forWindow uid: String)
    var available: Bool { get }
    var unavailableReason: String? { get }
}

/// Host 侧窗口能力。
public protocol WindowProvider: AnyObject {
    /// 目标应用身份。能力上报与 UI 提示需要它（缺失时不得编造名称）。
    var appBundleID: String { get }
    var appDisplayName: String { get }
    func currentWindows() -> [WindowInfo]
    func applySize(_ uid: String, requested: Size) -> (actual: Size, constrainedBy: SizeConstraint)
    func perform(_ action: WindowActionKind, on uid: String) -> Bool
    func activate(_ uid: String) -> Bool
}

/// 权限与能力探测结果，直接驱动 UI 提示（不兼容场景必须明确告知，不得静默降级）。
public struct CapabilityReport: Equatable, Sendable {
    public var screenRecording: PermissionState
    public var accessibility: PermissionState
    public var inputMonitoring: PermissionState
    public var captureMode: CaptureMode
    public var inputMode: InputExecutionMode
    public var textMode: TextAccessMode

    public enum PermissionState: String, Equatable, Sendable {
        case granted, denied, unknown, notRequired

        public var localizedDescription: String {
            switch self {
            case .granted: return "已授权"
            case .denied: return "未授权"
            case .unknown: return "未知"
            case .notRequired: return "不需要"
            }
        }
    }

    public enum CaptureMode: String, Equatable, Sendable {
        /// 真实窗口采集（ScreenCaptureKit）
        case realWindowCapture
        /// 合成采集（无需权限，用于验证与演示）
        case synthetic
        /// 不可用
        case unavailable

        public var localizedDescription: String {
            switch self {
            case .realWindowCapture: return "真实窗口采集"
            case .synthetic: return "合成采集（演示/验证模式）"
            case .unavailable: return "画面采集不可用"
            }
        }
    }

    public enum InputExecutionMode: String, Equatable, Sendable {
        case realEventInjection
        case recorded
        case unavailable

        public var localizedDescription: String {
            switch self {
            case .realEventInjection: return "真实事件注入"
            case .recorded: return "记录模式（不注入系统）"
            case .unavailable: return "输入执行不可用"
            }
        }
    }

    public enum TextAccessMode: String, Equatable, Sendable {
        /// 可读插入点矩形 → 支持"光标处本地组合"（P2 达标）
        case fullLocalIME
        /// 可读文本但无插入点位置 → 候选窗只能降级定位
        case degradedCaret
        /// 只能读窗口级信息 → 必须降级为远端输入法
        case remoteIMEOnly
        case unavailable

        public var localizedDescription: String {
            switch self {
            case .fullLocalIME: return "本地输入法（光标跟随）"
            case .degradedCaret: return "本地输入法（候选窗位置近似）"
            case .remoteIMEOnly: return "降级：使用远端输入法"
            case .unavailable: return "文本输入不可用"
            }
        }

        /// 是否达到 P2 对"认证应用"的要求。
        public var meetsCertifiedBar: Bool { self == .fullLocalIME }

        /// 降级的可读解释（用于界面提示与能力上报）。
        public var degradationExplanation: String {
            switch self {
            case .fullLocalIME:
                return "本地输入法（光标跟随）"
            case .degradedCaret:
                return "远端未提供可用的插入点位置：能读到控件与文本，但光标位置不可用，"
                    + "候选窗只能近似定位（Chromium 系应用的常见情况）"
            case .remoteIMEOnly:
                return "未读到可编辑文本控件，本地输入法无法工作"
            case .unavailable:
                return "文本输入不可用"
            }
        }
    }

    public var textCapabilities: TextCapabilities {
        TextCapabilities(axAvailable: accessibility == .granted || textMode == .fullLocalIME,
                         focusTracking: accessibility == .granted,
                         selectionRead: accessibility == .granted,
                         caretRect: textMode == .fullLocalIME,
                         compositionSupport: textMode == .fullLocalIME || textMode == .degradedCaret)
    }

    /// 面向用户的提示文案集合。空数组表示无须提示。
    public var userFacingNotices: [Notice] {
        var out: [Notice] = []
        if screenRecording == .denied {
            out.append(Notice(severity: .warning, scope: .permission,
                              title: "缺少屏幕录制权限",
                              detail: "远端画面将使用合成源。如需看到真实窗口内容，请在「系统设置 → 隐私与安全性 → 屏幕录制」中授权后重试。"))
        }
        if accessibility == .denied {
            out.append(Notice(severity: .warning, scope: .permission,
                              title: "缺少辅助功能权限",
                              detail: "窗口尺寸同步与本地中文输入法将不可用。请在「系统设置 → 隐私与安全性 → 辅助功能」中授权。"))
        }
        switch textMode {
        case .degradedCaret:
            out.append(Notice(severity: .warning, scope: .text,
                              title: "候选窗位置可能不精确",
                              detail: "远端未提供稳定的插入点位置，候选窗将定位在控件附近而非光标处。该应用不会被标记为「本地输入法体验达标」。"))
        case .remoteIMEOnly:
            out.append(Notice(severity: .info, scope: .text,
                              title: "该应用使用远端输入法",
                              detail: "当前应用未通过本地输入法认证，将回退为远端输入法（候选词需经网络往返）。"))
        case .unavailable:
            out.append(Notice(severity: .error, scope: .text,
                              title: "文本输入不可用", detail: "无法读取远端输入控件信息。"))
        case .fullLocalIME:
            break
        }
        if inputMonitoring == .denied {
            out.append(Notice(severity: .info, scope: .permission,
                              title: "未授予输入监控权限",
                              detail: "全局快捷键捕获将不可用，但窗口内的输入不受影响。"))
        }
        return out
    }
}

/// 面向用户的提示（规格 §5 错误呈现：必须区分，不得合并成"连接失败"）。
public struct Notice: Equatable, Sendable, Identifiable {
    public var id: String { "\(scope.rawValue):\(code):\(title)" }
    public var code: String = ""
    public var severity: Severity
    public var scope: ErrorScope
    public var title: String
    public var detail: String

    public enum Severity: String, Equatable, Sendable {
        case info, warning, error

        public var localizedDescription: String {
            switch self { case .info: return "提示"; case .warning: return "注意"; case .error: return "错误" }
        }
    }

    public init(severity: Severity, scope: ErrorScope, title: String, detail: String, code: String = "") {
        self.severity = severity; self.scope = scope; self.title = title; self.detail = detail
        self.code = code
    }
}

// MARK: - 会话

/// 会话状态机。承载规格 §5 的五个"必须区分"的语义与 §5.2 的重连要求。
public final class Session {
    public private(set) var phase: SessionPhase = .disconnected
    public private(set) var epoch: UInt64
    public private(set) var phaseHistory: [SessionPhase] = []
    public private(set) var notices: [Notice] = []

    /// 重连次数与"丢弃的未确认输入数"，用于断言不重放。
    public private(set) var reconnectCount = 0
    public private(set) var discardedPendingInputs = 0

    public var onPhaseChange: ((SessionPhase) -> Void)?
    /// 重连时回调，用于重新同步窗口注册表、清空组合、请求关键帧。
    public var onReconnect: (() -> Void)?

    public init(epoch: UInt64 = 1) {
        self.epoch = epoch
    }

    private func setPhase(_ p: SessionPhase) {
        guard p != phase else { return }
        phase = p
        phaseHistory.append(p)
        onPhaseChange?(p)
    }

    public func beginNegotiation() { setPhase(.negotiating) }

    public func activate(degraded: Bool = false, notices: [Notice] = []) {
        self.notices = notices
        setPhase(degraded ? .degraded : .active)
    }

    public func note(_ notice: Notice) {
        notices.append(notice)
    }

    public func clearNotice(code: String) {
        notices.removeAll { $0.code == code }
    }

    /// 网络中断。**只冻结画面，不关闭远端应用**（规格 §5.1）。
    public func transportInterrupted(detail: String?) {
        switch phase {
        case .active, .degraded:
            setPhase(.reconnecting)
            notices.append(Notice(severity: .warning, scope: .media,
                                  title: "画面中断", detail: "远端应用仍在运行，正在尝试重连。",
                                  code: "media.interrupted"))
            _ = detail
        default:
            break
        }
    }

    /// 采纳对端（Host）权威指定的会话代次。
    ///
    /// 重连时不能由本地自行推进 `epoch`：两端各自推进会让对方的合法消息被判为过期。
    public func adoptEpoch(_ e: UInt64, reason: String) {
        guard e != epoch else { return }
        epoch = e
        notices.append(Notice(severity: .info, scope: .auth,
                              title: "会话已更新", detail: reason, code: "session.epoch"))
    }

    /// 远端确认重连完成（仅记账，不改 epoch）。
    public func noteReconnectCompleted() {
        reconnectCount += 1
        clearNotice(code: "media.interrupted")
        if phase == .reconnecting {
            phase = .active
            phaseHistory.append(.active)
            onReconnect?()
            onPhaseChange?(.active)
        }
    }

    /// 重连成功：推进 `epoch`（使旧消息失效），并要求上层重新同步。
    public func reconnectSucceeded() {
        reconnectCount += 1
        epoch &+= 1
        clearNotice(code: "media.interrupted")
        phase = .active
        phaseHistory.append(.active)
        onReconnect?()
        onPhaseChange?(.active)
    }

    /// 挂起：远端应用保留，连接释放。
    public func suspend(reason: String) {
        setPhase(.suspended)
        notices.append(Notice(severity: .info, scope: .media, title: "已挂起", detail: reason))
    }

    public func revoke(_ reason: RevokeReason) {
        setPhase(.revoked)
        notices.append(Notice(severity: .warning, scope: .auth,
                              title: "控制已撤销", detail: reason.localizedDescription,
                              code: "auth.revoked"))
    }

    public func fail(notice: Notice) {
        notices.append(notice)
        setPhase(.error)
    }

    /// 进入结果不明状态时的记录（不自动重试的记账）。
    public func recordDiscardedPendingInput(count: Int = 1) {
        discardedPendingInputs += count
    }

    /// 重连后必须执行的动作清单（供上层逐项落实，便于测试断言）。
    public var reconnectChecklist: [String] {
        ["重新枚举远端窗口并关闭已消失窗口的本地壳",
         "丢弃本地未确认发出的输入队列（不重放）",
         "请求可解码关键帧",
         "重新读取文本上下文；焦点变化则清空本地组合",
         "释放所有按下的修饰键"]
    }
}
