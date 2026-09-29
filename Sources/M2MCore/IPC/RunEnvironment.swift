import Foundation

/// 一次运行（一个"会话"）的隔离环境。
///
/// 隔离要求（用户要求"几个端测试全在本台电脑运行，做好隔离"）：
/// - 每个角色独立进程、独立配置/数据目录
/// - 所有 IPC 走私有运行目录内的 UDS（0600），不占用网络端口
/// - 运行目录带唯一标识，互不干扰；退出时清理
/// - 运行状态写入文件，便于断言与排障（只读、无内容泄露）
public struct RunEnvironment {
    public let root: URL
    public let runID: String

    public init(root: URL, runID: String) {
        self.root = root
        self.runID = runID
    }

    /// 创建一套全新的隔离运行环境。
    public static func create(base: URL? = nil, label: String = "run") throws -> RunEnvironment {
        let baseDir = base ?? FileManager.default.temporaryDirectory
        let runID = "\(label)-\(UUID().uuidString.prefix(8))"
        let root = baseDir.appendingPathComponent("m2m-\(runID)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        let env = RunEnvironment(root: root, runID: runID)
        for role in Role.allCases {
            try FileManager.default.createDirectory(at: env.directory(for: role),
                                                    withIntermediateDirectories: true)
        }
        return env
    }

    public enum Role: String, CaseIterable {
        case demo, host, viewer, relay, reports
    }

    public func directory(for role: Role) -> URL {
        root.appendingPathComponent(role.rawValue)
    }

    /// 中继套接字（host / viewer 接入此处）
    public var relaySocketPath: String { directory(for: .relay).appendingPathComponent("relay.sock").path }
    /// 目标应用（demo）套接字（host 接入此处）
    public var demoAppSocketPath: String { directory(for: .demo).appendingPathComponent("app.sock").path }
    /// 只读状态文件：供测试断言读取，不含聊天正文之外的隐私内容
    public func stateFile(_ name: String) -> URL { directory(for: .reports).appendingPathComponent(name) }

    public var logDirectory: URL { root.appendingPathComponent("logs") }

    public func prepareLogs() throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    /// 运行元信息，便于事后复现。
    public func writeManifest(_ extra: [String: String] = [:]) {
        var info: [String: String] = [
            "run_id": runID,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "host_macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "host_arch": ProcessInfo.processInfo.machineArchitecture,
        ]
        for (k, v) in extra { info[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("manifest.json"))
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 递归列出运行目录内容（用于报告）。
    public func inventory() -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            out.append(rel)
        }
        return out.sorted()
    }
}

public extension ProcessInfo {
    var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

// MARK: - Host ↔ 目标应用（demo）之间的本地协议

/// Host → 目标应用（demo）的请求。
///
/// 刻意用"扁平结构 + 可选字段"而不是带关联值的枚举：手写 Codable 的枚举在
/// 增加字段时极易出错，而这里需要的是可读、可演进、可排障的本地协议。
public struct DemoRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello, snapshot, resize, action, key, pointer, textContext
        case textCommit, setContent, openSettings, openModal, openPopup, close, revokeInput
    }
    /// 请求标识：响应按它匹配，避免"替换回调"式的竞态。
    public var requestID: String?
    public var kind: Kind
    public var uid: String?
    public var width: Double?
    public var height: Double?
    public var action: String?
    public var windowUID: String?
    public var keycode: Int?
    public var isDown: Bool?
    public var flags: Int?
    public var unicode: String?
    public var pointerKind: String?
    public var x: Double?
    public var y: Double?
    public var button: String?
    public var scrollDX: Double?
    public var scrollDY: Double?
    public var text: String?
    public var caret: Int?
    public var selection: Int?
    public var revoke: Bool?
    /// 文本提交（与按键严格分开：提交是编辑语义，不是按键事件）
    public var commitIntent: String?
    public var commitLocation: Int?
    public var commitLength: Int?

    public init(kind: Kind) { self.kind = kind }

    public static func snapshot() -> DemoRequest { .init(kind: .snapshot) }
    public static func hello() -> DemoRequest { .init(kind: .hello) }
    public static func textContext() -> DemoRequest { .init(kind: .textContext) }
    public static func openSettings() -> DemoRequest { .init(kind: .openSettings) }
    public static func openModal() -> DemoRequest { .init(kind: .openModal) }
    public static func openPopup() -> DemoRequest { .init(kind: .openPopup) }

    public static func resize(uid: String, width: Double, height: Double) -> DemoRequest {
        var r = DemoRequest(kind: .resize); r.uid = uid; r.width = width; r.height = height; return r
    }
    public static func action(uid: String, action: WindowActionKind) -> DemoRequest {
        var r = DemoRequest(kind: .action); r.uid = uid; r.action = actionName(action); return r
    }
    public static func close(uid: String) -> DemoRequest {
        var r = DemoRequest(kind: .close); r.uid = uid; return r
    }
    public static func setContent(text: String, caret: Int, selection: Int) -> DemoRequest {
        var r = DemoRequest(kind: .setContent); r.text = text; r.caret = caret; r.selection = selection; return r
    }
    public static func revokeInput(_ v: Bool) -> DemoRequest {
        var r = DemoRequest(kind: .revokeInput); r.revoke = v; return r
    }
    /// 文本提交请求。刻意与 `.key` 分开：提交是编辑语义，按键是物理事件，
    /// 混用会导致"同一段文字既提交又按键"从而重复输入。
    public static func textCommit(_ c: TextCommit) -> DemoRequest {
        var r = DemoRequest(kind: .textCommit)
        r.text = c.text
        r.commitIntent = c.intent == .replaceSelection ? "replaceSelection"
            : (c.intent == .newline ? "newline"
               : (c.intent == .deleteBackward ? "deleteBackward"
                  : (c.intent == .deleteForward ? "deleteForward" : "insertText")))
        r.commitLocation = c.replaceRange?.location
        r.commitLength = c.replaceRange?.length
        return r
    }
    public static func textIntentFromName(_ s: String) -> TextIntent {
        switch s {
        case "replaceSelection": return .replaceSelection
        case "newline": return .newline
        case "deleteBackward": return .deleteBackward
        case "deleteForward": return .deleteForward
        default: return .insertText
        }
    }
    public static func key(_ e: KeyEvent) -> DemoRequest {
        var r = DemoRequest(kind: .key)
        r.windowUID = e.windowUID; r.keycode = Int(e.keycode)
        r.isDown = e.kind != .keyUp; r.flags = Int(e.flags); r.unicode = e.unicode
        return r
    }
    public static func pointer(_ e: PointerEvent) -> DemoRequest {
        var r = DemoRequest(kind: .pointer)
        r.windowUID = e.windowUID
        r.pointerKind = pointerName(e.kind)
        r.x = e.positionInWindow.x; r.y = e.positionInWindow.y
        r.button = buttonName(e.button)
        r.scrollDX = e.scrollDX; r.scrollDY = e.scrollDY
        return r
    }

    public static func actionName(_ a: WindowActionKind) -> String {
        switch a {
        case .activate: return "activate"
        case .minimize: return "minimize"
        case .unminimize: return "unminimize"
        case .close: return "close"
        case .requestFullscreen: return "fullscreen"
        }
    }
    public static func actionFromName(_ s: String) -> WindowActionKind? {
        switch s {
        case "activate": return .activate
        case "minimize": return .minimize
        case "unminimize": return .unminimize
        case "close": return .close
        case "fullscreen": return .requestFullscreen
        default: return nil
        }
    }
    public static func pointerName(_ k: PointerKind) -> String {
        switch k {
        case .move: return "move"
        case .down: return "down"
        case .up: return "up"
        case .drag: return "drag"
        case .scroll: return "scroll"
        case .moveCoalesced: return "move"
        }
    }
    public static func pointerFromName(_ s: String) -> PointerKind? {
        switch s {
        case "move": return .move
        case "down": return .down
        case "up": return .up
        case "drag": return .drag
        case "scroll": return .scroll
        default: return nil
        }
    }
    public static func buttonName(_ b: PointerButton) -> String {
        switch b {
        case .none: return "none"
        case .left: return "left"
        case .right: return "right"
        case .middle: return "middle"
        }
    }
    public static func roleName(_ r: WindowRole) -> String {
        switch r {
        case .main: return "main"
        case .panel: return "panel"
        case .dialog: return "dialog"
        case .popupMenu: return "popupMenu"
        case .child: return "child"
        case .unknown: return "unknown"
        }
    }
    public static func roleFromName(_ s: String) -> WindowRole {
        switch s {
        case "main": return .main
        case "panel": return .panel
        case "dialog": return .dialog
        case "popupMenu": return .popupMenu
        case "child": return .child
        default: return .unknown
        }
    }
}

/// demo 进程的响应。`windowList` 用可读结构，便于跨进程断言。
public struct DemoSnapshot: Codable, Sendable {
    public struct Win: Codable, Sendable, Equatable {
        public var uid: String
        public var title: String
        public var role: String
        public var width: Double
        public var height: Double
        public var minWidth: Double
        public var minHeight: Double
        public var resizable: Bool
        public var minimized: Bool
        public var modal: Bool
        public var parentUID: String?
        public var focusable: Bool
        public var zOrder: Int
    }
    public struct TextState: Codable, Sendable {
        public var buffer: String
        public var caret: Int
        public var selection: Int
        public var focusedWindowUID: String?
        public var caretRectValid: Bool
        public var caretX: Double
        public var caretY: Double
        public var acceptsInput: Bool
    }
    public var bundleID: String
    public var displayName: String
    public var launchID: String
    public var pid: Int32
    public var contentScale: Double
    public var windows: [Win]
    public var text: TextState
}

public struct DemoResponse: Codable, Sendable {
    public var requestID: String?
    public var ok: Bool
    public var error: String?
    public var snapshot: DemoSnapshot?
    public var createdUID: String?
    public var appliedWidth: Double?
    public var appliedHeight: Double?
    public var constrained: Bool?

    public init(requestID: String? = nil, ok: Bool, error: String? = nil, snapshot: DemoSnapshot? = nil,
                createdUID: String? = nil, appliedWidth: Double? = nil,
                appliedHeight: Double? = nil, constrained: Bool? = nil) {
        self.requestID = requestID
        self.ok = ok; self.error = error; self.snapshot = snapshot; self.createdUID = createdUID
        self.appliedWidth = appliedWidth; self.appliedHeight = appliedHeight; self.constrained = constrained
    }
}
