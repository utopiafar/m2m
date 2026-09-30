import Foundation
import ApplicationServices
import AppKit

// MARK: - 真实 AX 文本路径
//
// 这条路径**需要辅助功能权限**。实现按 docs/04-text-input.md §5 的优先级组织：
//   1. 真实编辑事件路径（CGEvent 携带已确认文字，作用于焦点控件）
//   2. AX 语义写入（kAXSelectedTextAttribute —— 替换选区式插入，**不是**整框覆盖）
//   3. 明确报告"该控件不接受"，不假装成功
//
// 明确不做：用整框覆盖 `AXValue` 冒充输入法支持。那会破坏组合、选区与撤销语义。

/// 从辅助功能接口读取远端编辑状态（焦点控件、光标矩形、选区、上下文片段）。
public final class AXTextContextProvider: TextContextProvider {
    public let targetPID: pid_t
    private var editVersion: UInt64 = 1
    private let lock = NSLock()

    /// 最近一次读取的诊断信息，用于报告与降级提示。
    public private(set) var lastDiagnostics: Diagnostics = .init()

    public struct Diagnostics: Sendable {
        public var focusedElementFound = false
        public var caretRectRead = false
        public var selectionRead = false
        public var role: String = ""
        public var failureReason: String?
    }

    public init(targetPID: pid_t) { self.targetPID = targetPID }

    public var available: Bool { AXIsProcessTrusted() }
    public var unavailableReason: String? {
        available ? nil : "缺少辅助功能权限，无法读取远端编辑状态"
    }

    private var appElement: AXUIElement { AXUIElementCreateApplication(targetPID) }

    /// 本机是否具备"光标处本地组合"所需的插入点定位能力。
    ///
    /// 这是 P2 的判定输入：读不到插入点就不允许标注为"本地输入法体验达标"。
    public var caretRectCapability: CapabilityReport.TextAccessMode {
        guard available else { return .remoteIMEOnly }
        guard let element = focusedElement() else { return .remoteIMEOnly }
        let rect = caretRect(of: element, selectionLength: selection(of: element).length)
        if rect != nil { return .fullLocalIME }
        // 能读焦点与选区、但读不到插入点矩形 ⇒ 候选窗只能近似定位
        return selectionReadable(element) ? .degradedCaret : .remoteIMEOnly
    }

    // MARK: 读取

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else {
            lastDiagnostics.focusedElementFound = false
            lastDiagnostics.failureReason = "无法获取焦点控件（应用可能未激活或无辅助功能权限）"
            return nil
        }
        lastDiagnostics.focusedElementFound = true
        return (v as! AXUIElement)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func selection(of element: AXUIElement) -> (location: Int, length: Int) {
        guard let v = attribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(v) == AXValueGetTypeID() else {
            return (-1, 0)
        }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return (-1, 0) }
        lastDiagnostics.selectionRead = true
        return (range.location, range.length)
    }

    private func selectionReadable(_ element: AXUIElement) -> Bool {
        selection(of: element).location >= 0
    }

    /// 插入点矩形。这是候选窗能否"贴近插入点"的前提。
    private func caretRect(of element: AXUIElement, selectionLength: Int) -> Rect? {
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        // 有选区时定位到选区起点，组合期间的候选窗应贴住插入点
        var query = CFRange(location: range.location, length: max(0, selectionLength))
        guard let qv = AXValueCreate(.cfRange, &query) else { return nil }
        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, qv, &boundsValue)
        guard result == .success, let bv = boundsValue, CFGetTypeID(bv) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect) else { return nil }
        lastDiagnostics.caretRectRead = true
        return Rect(Double(rect.origin.x), Double(rect.origin.y),
                    max(1, Double(rect.width)), max(1, Double(rect.height)))
    }

    public func currentContext() -> TextContext? {
        guard available else { return nil }
        lastDiagnostics = Diagnostics()
        guard let element = focusedElement() else { return nil }

        let role = string(element, kAXRoleAttribute as String) ?? ""
        lastDiagnostics.role = role

        // 只把真正可编辑的控件当作输入目标
        let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        let isEditableRole = editableRoles.contains(role)
        let settable = isAttributeSettable(element, kAXValueAttribute as String)
        guard isEditableRole || settable else {
            lastDiagnostics.failureReason = "焦点控件不是可编辑文本控件（role=\(role)）"
            return nil
        }

        let sel = selection(of: element)
        let caret = caretRect(of: element, selectionLength: sel.length)
        let value = string(element, kAXValueAttribute as String) ?? ""
        let chars = Array(value)
        let loc = sel.location >= 0 ? min(sel.location, chars.count) : chars.count
        let before = String(chars[max(0, loc - 64)..<loc])
        let after = String(chars[loc..<min(chars.count, loc + 64)])

        // 窗口归属：用于 Viewer 把文字与窗口对上
        var windowUID = "ax:\(targetPID):unknown"
        if let window = attribute(element, kAXWindowAttribute as String),
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            let title = string(window as! AXUIElement, kAXTitleAttribute as String) ?? ""
            windowUID = "ax:\(targetPID):\(title.hashValue)"
        }

        lock.lock(); let version = editVersion; lock.unlock()

        return TextContext(
            epoch: 1, editVersion: version,
            windowUID: windowUID, nodeID: "ax-node-\(role)-\(value.hashValue)",
            role: roleToNodeRole(role), editable: true,
            acceptsUnicodeEvents: false,   // 需实测；默认不假设支持，走 AX 路径
            caret: CaretInfo(valid: caret != nil,
                             rectInWindow: caret ?? .zero,
                             lineHeight: caret?.size.height ?? 0),
            selection: SelectionInfo(valid: sel.location >= 0 && sel.length > 0,
                                     location: max(0, sel.location), length: max(0, sel.length)),
            remoteMarkedPresent: false, remoteMarkedLength: 0,
            contextBefore: before, contextAfter: after,
            contextTruncated: loc > 64 || chars.count - loc > 64)
    }

    private func roleToNodeRole(_ role: String) -> TextNodeRole {
        switch role {
        case "AXTextField", "AXSearchField": return .textField
        case "AXTextArea": return .textArea
        case "AXComboBox": return .textField
        default: return .unknown
        }
    }

    private func isAttributeSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    @discardableResult
    public func advanceEditVersion() -> UInt64 {
        lock.lock(); editVersion &+= 1; let v = editVersion; lock.unlock()
        return v
    }

    /// 在远端发生编辑后（例如用户直接在远端打字）推进版本，使在途的旧提交失效。
    public func noteRemoteEdit() { advanceEditVersion() }
}

/// 真实提交执行器。
///
/// 路径优先级（对齐规格 §5）：
/// 1. AX 选区写入 `kAXSelectedTextAttribute` —— 语义是"替换选区"，保留前后文本与撤销链
/// 2. CGEvent 携带已确认文字作用于焦点控件
/// 3. 如实报告控件不接受
///
/// **明确拒绝**：整框覆盖 `AXValue`。那样会破坏组合、选区、撤销，属于伪输入法支持。
public final class AXTextCommitExecutor: TextCommitExecutor {
    public let targetPID: pid_t
    public private(set) var stats = Stats()

    public struct Stats: Sendable {
        public var axSelectionInsert = 0
        public var cgEventInsert = 0
        public var rejected = 0
        public var lastPath: String = ""
    }

    public init(targetPID: pid_t) { self.targetPID = targetPID }

    private var appElement: AXUIElement { AXUIElementCreateApplication(targetPID) }

    public func execute(_ commit: TextCommit, context: TextContext) -> TextCommitResult {
        guard AXIsProcessTrusted() else {
            stats.rejected += 1
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedNoFocus,
                                    detail: "缺少辅助功能权限，无法向远端写入")
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let elementValue = value, CFGetTypeID(elementValue) == AXUIElementGetTypeID() else {
            stats.rejected += 1
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedNoFocus,
                                    detail: "无法获取远端焦点控件")
        }
        let element = elementValue as! AXUIElement

        switch commit.intent {
        case .deleteBackward, .deleteForward:
            return deleteViaKeyEvent(commit, element: element)
        case .insertText, .newline, .replaceSelection:
            // 路径 1：AX 选区写入。语义上等价于"用这段文字替换当前选区/插入点"，
            // 因此保留前后文本；这与"整框覆盖"有本质区别。
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
               settable.boolValue {
                let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                                         commit.text as CFString)
                if result == .success {
                    stats.axSelectionInsert += 1
                    stats.lastPath = "AXSelectedText"
                    return TextCommitResult(commitSeq: commit.commitSeq, status: .applied,
                                            appliedRange: SelectionInfo(valid: true, location: 0,
                                                                        length: commit.text.count),
                                            detail: "AX 选区写入")
                }
            }
            // 路径 2：CGEvent 携带已确认文字
            if let r = cgEventInsert(commit) {
                stats.cgEventInsert += 1
                stats.lastPath = "CGEventUnicode"
                return r
            }
            stats.rejected += 1
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedUnsupported,
                                    detail: "焦点控件不接受 AX 语义写入，也未接受 Unicode 事件")
        }
    }

    /// 用键盘事件表达删除，保证远端撤销链与原生行为一致。
    private func deleteViaKeyEvent(_ commit: TextCommit, element: AXUIElement) -> TextCommitResult {
        let source = CGEventSource(stateID: .hidSystemState)
        let isBackward = commit.intent == .deleteBackward
        let keycode: CGKeyCode = isBackward ? 51 : 117   // Delete / Forward Delete
        guard let src = source,
              let down = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: false) else {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedUnsupported,
                                    detail: "无法构造删除按键事件")
        }
        down.postToPid(targetPID)
        up.postToPid(targetPID)
        stats.lastPath = "CGEventKey"
        return TextCommitResult(commitSeq: commit.commitSeq, status: .applied,
                                appliedRange: SelectionInfo(valid: true, location: 0, length: 0),
                                detail: "删除按键事件")
    }

    private func cgEventInsert(_ commit: TextCommit) -> TextCommitResult? {
        guard !commit.text.isEmpty else { return nil }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            return nil
        }
        let utf16 = Array(commit.text.utf16)
        guard !utf16.isEmpty else { return nil }
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        event.postToPid(targetPID)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.postToPid(targetPID)
        }
        return TextCommitResult(commitSeq: commit.commitSeq, status: .applied,
                                appliedRange: SelectionInfo(valid: true, location: 0,
                                                            length: commit.text.count),
                                detail: "CGEvent Unicode（该路径依赖应用是否尊重事件中的 Unicode）")
    }
}
