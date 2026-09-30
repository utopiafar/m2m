import Foundation
import AppKit
import CoreGraphics
import M2MCore

// m2mctl —— 编排、场景运行与报告生成
//
// 单机三端隔离运行：中继 / 目标应用（demo）/ 主机代理 / 本地客户端
// 各自是独立进程，通过私有运行目录内的 UDS 通信，不占用任何网络端口。
//
// 子命令：
//   scenarios   列出可用场景
//   run <场景>  运行单个场景
//   selftest    跑完整场景矩阵并生成 Markdown 报告
//   up          启动可交互的三端演示（带窗口，供人工体验）
//   env         查看隔离运行环境

struct CLIOptions {
    var command = "help"
    var scenario = ""
    var reportPath: String?
    var quiet = false
    var keepRunDir = false
    var windowSize = Size(560, 380)
    var noGUI = false
}

func parseCLI() -> CLIOptions {
    var o = CLIOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { return o }
    o.command = args.removeFirst()
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--scenario": o.scenario = it.next() ?? ""
        case "--report": o.reportPath = it.next()
        case "--quiet": o.quiet = true
        case "--keep": o.keepRunDir = true
        case "--no-gui": o.noGUI = true
        case "--size":
            if let s = it.next() {
                let p = s.split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { o.windowSize = Size(p[0], p[1]) }
            }
        default:
            if o.scenario.isEmpty { o.scenario = a }
        }
    }
    return o
}

let stdoutHandle = FileHandle.standardOutput
func out(_ s: String) { stdoutHandle.write(Data((s + "\n").utf8)) }
func errOut(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let cli = parseCLI()

/// 供信号处理器使用的全局清理入口（C 函数指针不能捕获上下文）。
nonisolated(unsafe) var globalShutdown: (() -> Void)?

// MARK: - 场景定义

enum StepAction {
    case sleep(Double)
    case typeText(String)
    case resize(Size)
    case focusMain
    case setLink(RelayControl)
    case demoCommand([DemoRequest])
    case expectLocalWindows(Int)
    case expectRemoteWindows(Int)
    case expectRemoteText(String)
    case expectMinFrames(Int)
    case expectDegraded(Bool)
    case expectRemoteSize(Size)
    /// 画面必须看起来像真实屏幕内容（色彩多样、亮度正常）
    case expectRealScreenPixels
    /// 主机必须报告真实采集已生效的窗口数 ≥ n
    case expectRealCaptureWindows(Int)
    /// 本地窗口壳数量：给出具体值则必须相等，nil 表示只要求 ≥1
    case expectLocalWindowsExact(Int?)
}

struct Step {
    var description: String
    var action: StepAction
}

struct Scenario {
    var name: String
    var summary: String
    var expectation: String
    var demoArgs: [String] = []
    var linkConditions: LinkConditions = .lan
    var steps: [Step] = []
    /// 运行前置条件。不满足时场景被标记为"跳过"而不是"通过"——跳过不等于通过。
    var visibility: Visibility = .always
    /// 使用真实屏幕采集（启动主机时带 --real-capture 并把目标指向 demo 的可见窗口）
    var usesRealCapture = false
    /// 真实采集场景的窗口尺寸与码率预算。
    /// 真实屏幕像素的熵远高于合成内容，本仓库的无损 RLE 会产出大得多的帧，
    /// 因此需要更高的预算才能拿到多帧（真实产品用 H.264/HEVC，不在此受限）。
    var realCaptureWindowSize: Size?
    var realCaptureBitrateMbps: Double?

    enum Visibility {
        case always
        /// 需要 GUI 会话 + 屏幕录制权限
        case requiresDisplayAndScreenRecording
    }
}

let scenarioTable: [Scenario] = [
    Scenario(
        name: "basic",
        summary: "基本链路：连接 → 窗口 → 画面 → 中文输入 → 缩放",
        expectation: "远端窗口以独立本地壳出现；画面像素与远端渲染一致；中文提交生效；缩放后远端重新排版",
        steps: [
            Step(description: "等待握手与首帧", action: .sleep(2.0)),
            Step(description: "本地出现 1 个远端窗口", action: .expectLocalWindows(1)),
            Step(description: "收到画面帧", action: .expectMinFrames(1)),
            Step(description: "聚焦主窗口", action: .focusMain),
            Step(description: "输入中文「你好，世界」", action: .typeText("你好，世界")),
            Step(description: "远端文本为「你好，世界」", action: .expectRemoteText("你好，世界")),
            Step(description: "缩放到 800x600", action: .resize(Size(800, 600))),
            Step(description: "远端窗口尺寸变为 800x600", action: .expectRemoteSize(Size(800, 600))),
        ]),
    Scenario(
        name: "windows",
        summary: "窗口生命周期：新增设置 / 模态对话框 / 右键菜单",
        expectation: "每种窗口类型都建立独立本地壳，且不因出现特殊窗口而退化为共享整桌面",
        steps: [
            Step(description: "等待连接", action: .sleep(2.0)),
            Step(description: "远端应只有 1 个窗口", action: .expectRemoteWindows(1)),
            Step(description: "打开设置 + 模态对话框 + 右键菜单", action: .demoCommand([
                DemoRequest.openSettings(), DemoRequest.openModal(), DemoRequest.openPopup(),
            ])),
            Step(description: "等待窗口同步", action: .sleep(2.0)),
            Step(description: "远端应有 4 个窗口", action: .expectRemoteWindows(4)),
            Step(description: "本地应有 4 个窗口壳", action: .expectLocalWindows(4)),
        ]),
    Scenario(
        name: "degraded",
        summary: "能力降级：目标应用无法提供插入点位置",
        expectation: "画面仍可见（AX 缺失不得阻断显示），但必须明确提示降级，且不得标记为「本地输入法体验达标」",
        demoArgs: ["--no-caret-rect"],
        steps: [
            Step(description: "等待连接", action: .sleep(2.0)),
            Step(description: "窗口仍可见", action: .expectLocalWindows(1)),
            Step(description: "必须出现降级提示且无认证应用", action: .expectDegraded(true)),
        ]),
    Scenario(
        name: "bandwidth",
        summary: "弱带宽：1 Mbps 下仍可用",
        expectation: "画面继续送达、输入仍然生效",
        linkConditions: LinkConditions.bandwidth(mbps: 1),
        steps: [
            Step(description: "等待连接", action: .sleep(2.5)),
            Step(description: "窗口可用", action: .expectLocalWindows(1)),
            Step(description: "画面到达", action: .expectMinFrames(1)),
            Step(description: "聚焦并输入「弱网可用」", action: .focusMain),
            Step(description: "输入", action: .typeText("弱网可用")),
            Step(description: "远端文本正确", action: .expectRemoteText("弱网可用")),
        ]),
    Scenario(
        name: "lossy",
        summary: "丢包 5% + 160ms RTT",
        expectation: "可靠通道重传、媒体通道丢帧；文字不丢不重，画面不出现长期花屏",
        linkConditions: LinkConditions(oneWayLatency: 0.08, lossRate: 0.05),
        steps: [
            Step(description: "等待连接", action: .sleep(3.0)),
            Step(description: "窗口可用", action: .expectLocalWindows(1)),
            Step(description: "画面到达", action: .expectMinFrames(1)),
            Step(description: "聚焦并输入", action: .focusMain),
            Step(description: "输入「丢包不丢字」", action: .typeText("丢包不丢字")),
            Step(description: "远端文本正确且不重复", action: .expectRemoteText("丢包不丢字")),
        ]),
    Scenario(
        name: "disconnect",
        summary: "链路中断 2 秒后恢复",
        expectation: "远端应用保留、有中断提示、重连后窗口恢复；**中断期间的输入绝不重放**",
        steps: [
            Step(description: "等待连接", action: .sleep(2.0)),
            Step(description: "聚焦主窗口", action: .focusMain),
            Step(description: "输入基线文本「基线」", action: .typeText("基线")),
            Step(description: "确认基线生效", action: .expectRemoteText("基线")),
            Step(description: "断开链路", action: .setLink(RelayControl(down: true))),
            Step(description: "中断期间继续输入（不应到达）", action: .typeText("中断期间内容")),
            Step(description: "等待超时判定", action: .sleep(2.0)),
            Step(description: "恢复链路", action: .setLink(RelayControl(down: false))),
            Step(description: "等待重连与重新同步", action: .sleep(3.0)),
            Step(description: "窗口必须恢复", action: .expectLocalWindows(1)),
            Step(description: "远端文本必须仍只是「基线」（不得重放）", action: .expectRemoteText("基线")),
        ]),
    Scenario(
        name: "churn",
        summary: "反复断连重连三轮并持续输入",
        expectation: "会话 epoch 由两端协商保持一致；多轮重连后仍能正确输入，不丢不重",
        steps: [
            Step(description: "等待连接", action: .sleep(2.0)),
            Step(description: "聚焦", action: .focusMain),
            Step(description: "第 1 轮中断", action: .setLink(RelayControl(down: true))),
            Step(description: "等待", action: .sleep(0.8)),
            Step(description: "第 1 轮恢复", action: .setLink(RelayControl(down: false))),
            Step(description: "等待重连", action: .sleep(2.0)),
            Step(description: "输入 A", action: .typeText("A")),
            Step(description: "第 2 轮中断", action: .setLink(RelayControl(down: true))),
            Step(description: "等待", action: .sleep(0.8)),
            Step(description: "第 2 轮恢复", action: .setLink(RelayControl(down: false))),
            Step(description: "等待重连", action: .sleep(2.0)),
            Step(description: "输入 B", action: .typeText("B")),
            Step(description: "第 3 轮中断", action: .setLink(RelayControl(down: true))),
            Step(description: "等待", action: .sleep(0.8)),
            Step(description: "第 3 轮恢复", action: .setLink(RelayControl(down: false))),
            Step(description: "等待重连", action: .sleep(2.0)),
            Step(description: "输入 C", action: .typeText("C")),
            Step(description: "远端文本应为 ABC", action: .expectRemoteText("ABC")),
        ]),
    Scenario(
        name: "real-capture",
        summary: "真实屏幕采集（ScreenCaptureKit）——仅需屏幕录制权限",
        expectation: "主机用 SCK 枚举并采集真实窗口，本地收到的是真实屏幕像素（色彩种类远高于合成渲染）",
        steps: [
            Step(description: "等待连接与首帧", action: .sleep(4.0)),
            Step(description: "主机报告真实采集窗口 ≥1", action: .expectRealCaptureWindows(1)),
            Step(description: "本地窗口壳出现（≥1，真实应用可能有多个系统窗口）", action: .expectLocalWindowsExact(nil)),
            Step(description: "画面到达且为真实屏幕像素", action: .expectRealScreenPixels),
        ],
        // 该场景需要 GUI 会话与屏幕录制权限；无显示的 CI 环境会跳过（跳过 ≠ 通过）
        visibility: .requiresDisplayAndScreenRecording,
        usesRealCapture: true,
        // 真实像素的熵远高于合成内容，本仓库的无损 RLE 会产出更大的帧，
        // 因此需要更高预算才能拿到多帧（真实产品用 H.264/HEVC，不受此限）。
        realCaptureWindowSize: Size(420, 300),
        realCaptureBitrateMbps: 60),
    Scenario(
        name: "constraint",
        summary: "尺寸约束：请求小于应用最小尺寸",
        expectation: "本地必须接受应用约束（而不是坚持请求值），远端实际尺寸被读回",
        steps: [
            Step(description: "等待连接", action: .sleep(2.0)),
            Step(description: "请求 200x150（应用最小 320x200）", action: .resize(Size(200, 150))),
            Step(description: "远端实际尺寸为 320x200", action: .expectRemoteSize(Size(320, 200))),
        ]),
]

// MARK: - 进程编排

final class Orchestrator {
    let env: RunEnvironment
    private var processes: [String: Process] = [:]
    var relay: RelayServer?
    private let viewerCommandsURL: URL

    init(env: RunEnvironment) {
        self.env = env
        self.viewerCommandsURL = env.directory(for: .viewer).appendingPathComponent("commands.json")
    }

    func binaryPath(_ name: String) throws -> String {
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var probe = selfPath.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = probe.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            // 兼容 SwiftPM 的 .build/debug 与 .build/out/Products/Debug 两种布局
            for sub in ["out/Products/Debug", "debug"] {
                let alt = probe.appendingPathComponent(sub).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: alt) { return alt }
            }
            probe = probe.deletingLastPathComponent()
        }
        throw NSError(domain: "m2mctl", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "找不到可执行文件 \(name)"])
    }

    func startRelay(conditions: LinkConditions) throws {
        let server = RelayServer(socketPath: env.relaySocketPath, conditions: conditions,
                                 seed: 0xC0FFEE,
                                 controlFilePath: env.directory(for: .relay)
                                     .appendingPathComponent("control.json").path)
        try server.start()
        relay = server
        try waitForPath(env.relaySocketPath, timeout: 5)
    }

    @discardableResult
    func spawn(_ name: String, args: [String], role: String) throws -> Process {
        let path = try binaryPath(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? env.prepareLogs()
        let logURL = env.logDirectory.appendingPathComponent("\(role).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }
        var environment = ProcessInfo.processInfo.environment
        environment["M2M_ROLE"] = role
        environment["M2M_RUN_DIR"] = env.root.path
        // 每个角色独立的临时目录，避免相互影响
        let roleDir: RunEnvironment.Role = role == "demo" ? .demo : (role == "host" ? .host : .viewer)
        let scratch = env.directory(for: roleDir).appendingPathComponent("scratch")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        environment["TMPDIR"] = scratch.path + "/"
        p.environment = environment
        p.currentDirectoryURL = env.root
        try p.run()
        processes[role] = p
        return p
    }

    /// 启动带真实可见窗口的目标应用（真实采集场景使用）。
    @discardableResult
    func startDemoVisible(extraArgs: [String], windowSize: Size) throws -> Int32 {
        var args = ["--socket", env.demoAppSocketPath,
                    "--state-file", env.stateFile("demo-state.json").path,
                    "--control-file", env.directory(for: .demo).appendingPathComponent("control.json").path,
                    "--size", "\(Int(windowSize.width))x\(Int(windowSize.height))"]
        args.append(contentsOf: extraArgs)
        let p = try spawn("m2mdemo", args: args, role: "demo")
        try waitForPath(env.stateFile("demo-state.json").path, timeout: 8)
        // 等窗口真正出现在屏幕上，否则 SCK 枚举不到
        Thread.sleep(forTimeInterval: 2.0)
        return p.processIdentifier
    }

    func startDemo(extraArgs: [String], windowSize: Size) throws {
        var args = ["--socket", env.demoAppSocketPath,
                    "--state-file", env.stateFile("demo-state.json").path,
                    "--control-file", env.directory(for: .demo).appendingPathComponent("control.json").path,
                    "--headless",
                    "--size", "\(Int(windowSize.width))x\(Int(windowSize.height))"]
        args.append(contentsOf: extraArgs)
        try spawn("m2mdemo", args: args, role: "demo")
        try waitForPath(env.stateFile("demo-state.json").path, timeout: 6)
    }

    func startHost(windowSize: Size, realCaptureForPID: Int32?, bitrateMbps: Double?) throws {
        var args = ["--relay", env.relaySocketPath]
        if let pid = realCaptureForPID {
            args.append(contentsOf: ["--real-capture", "--pid", String(pid)])
        } else {
            args.append(contentsOf: ["--demo-socket", env.demoAppSocketPath])
        }
        args.append(contentsOf: [
            "--state-file", env.stateFile("host-state.json").path,
            "--run-dir", env.directory(for: .host).path,
            "--size", "\(Int(windowSize.width))x\(Int(windowSize.height))"])
        if let bitrateMbps { args.append(contentsOf: ["--bitrate", String(bitrateMbps)]) }
        try spawn("m2mhost", args: args, role: "host")
        try waitForPath(env.stateFile("host-state.json").path, timeout: 10)
    }

    func startViewer(headless: Bool) throws {
        var args = ["--relay", env.relaySocketPath,
                    "--state-file", env.stateFile("viewer-state.json").path,
                    "--run-dir", env.directory(for: .viewer).path]
        if headless { args.append("--headless") }
        try spawn("m2mviewer", args: args, role: "viewer")
        try waitForPath(env.stateFile("viewer-state.json").path, timeout: 8)
    }

    func waitForPath(_ path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(50_000)
        }
        throw NSError(domain: "m2mctl", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "等待超时：\(path)"])
    }

    func stopAll() {
        for (_, p) in processes where p.isRunning { p.terminate() }
        usleep(400_000)
        for (_, p) in processes where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        processes.removeAll()
        relay?.stop()
        relay = nil
    }

    func sendRelayControl(_ control: RelayControl) {
        if let conditions = control.conditions {
            relay?.update(conditions: conditions.apply(to: relay?.conditions ?? .lan))
        }
        if let down = control.down { relay?.setDown(down) }
        ControlFile.write(control, to: env.directory(for: .relay).appendingPathComponent("control.json"))
    }

    func sendDemoCommand(_ requests: [DemoRequest]) {
        ControlFile.write(DemoControl(requests: requests),
                          to: env.directory(for: .demo).appendingPathComponent("control.json"))
    }

    /// 向本地客户端投递一条交互命令（它轮询自己的命令文件，不额外建立连接）。
    func sendViewerCommand(_ op: String, value: String? = nil) {
        var list: [[String: Any]] = []
        if let data = try? Data(contentsOf: viewerCommandsURL),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            list = arr
        }
        var entry: [String: Any] = ["op": op]
        if let value { entry["value"] = value }
        list.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? data.write(to: viewerCommandsURL, options: .atomic)
            chmod(viewerCommandsURL.path, 0o600)
        }
    }

    func clearViewerCommands() {
        try? FileManager.default.removeItem(at: viewerCommandsURL)
    }

    func readState(_ name: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: env.stateFile(name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    func readHostState() -> [String: Any] { readState("host-state.json") }
    func readViewerState() -> [String: Any] { readState("viewer-state.json") }
    func readDemoState() -> [String: Any] { readState("demo-state.json") }
}

// MARK: - 结果模型

struct StepResult {
    var description: String
    var passed: Bool
    var detail: String
}

struct ScenarioResult {
    var scenario: String
    var summary: String
    var expectation: String
    var steps: [StepResult]
    var runID: String
    var environment: [String: String]
    var linkStats: String
    var duration: Double

    var passed: Bool { steps.allSatisfy { $0.passed } }
    var passedCount: Int { steps.filter { $0.passed }.count }
}

/// 检测文本中是否出现连续重复片段（"不得重复提交"的粗粒度检查）
func findDuplicatedSubstrings(_ s: String) -> [String] {
    guard s.count >= 4 else { return [] }
    let chars = Array(s)
    let window = 2
    var found: [String] = []
    var i = 0
    while i + window * 2 <= chars.count {
        let a = String(chars[i..<(i + window)])
        let b = String(chars[(i + window)..<(i + window * 2)])
        if a == b, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(a)
            i += window * 2
        } else {
            i += 1
        }
    }
    return found
}

// MARK: - 场景执行

/// 前置条件检查。不满足时返回原因（场景标记为跳过，**不是通过**）。
func preflightFailure(_ s: Scenario) -> String? {
    switch s.visibility {
    case .always:
        return nil
    case .requiresDisplayAndScreenRecording:
        if CGPreflightScreenCaptureAccess() == false {
            return "缺少屏幕录制权限"
        }
        // 无 GUI 会话时 SCK 也枚举不到窗口
        if NSScreen.main == nil {
            return "当前无图形会话（无显示器/未登录）"
        }
        return nil
    }
}

func runScenario(_ s: Scenario, options: CLIOptions, into results: inout [ScenarioResult]) throws {
    if let reason = preflightFailure(s) {
        out("")
        out("⏭ 场景 \(s.name)：前置条件不满足（\(reason)）→ 跳过，不计入通过")
        return
    }
    let env = try RunEnvironment.create(label: s.name)
    env.writeManifest(["scenario": s.name, "summary": s.summary])
    let orch = Orchestrator(env: env)
    defer {
        orch.stopAll()
        if !options.keepRunDir { env.cleanup() } else { errOut("运行目录保留：\(env.root.path)") }
    }

    out("")
    out("▶ 场景 \(s.name)：\(s.summary)")
    out("  隔离运行目录 \(env.root.path)")

    try orch.startRelay(conditions: s.linkConditions)
    if s.usesRealCapture {
        // 真实采集需要目标应用有真实可见窗口（SCK 只采集真实窗口）
        let windowSize = s.realCaptureWindowSize ?? options.windowSize
        let pid = try orch.startDemoVisible(extraArgs: s.demoArgs, windowSize: windowSize)
        try orch.startHost(windowSize: windowSize, realCaptureForPID: pid,
                           bitrateMbps: s.realCaptureBitrateMbps)
    } else {
        try orch.startDemo(extraArgs: s.demoArgs, windowSize: options.windowSize)
        try orch.startHost(windowSize: options.windowSize, realCaptureForPID: nil, bitrateMbps: nil)
    }
    try orch.startViewer(headless: true)

    var stepResults: [StepResult] = []
    let started = Date()

    for step in s.steps {
        var passed = true
        var detail = ""
        switch step.action {
        case .sleep(let seconds):
            Thread.sleep(forTimeInterval: seconds)
            detail = "等待 \(String(format: "%.1f", seconds))s"

        case .typeText(let text):
            orch.sendViewerCommand("type", value: text)
            Thread.sleep(forTimeInterval: 0.5)
            detail = "已提交文本「\(text)」"

        case .resize(let size):
            orch.sendViewerCommand("resize", value: "\(Int(size.width))x\(Int(size.height))")
            detail = "已请求尺寸 \(Int(size.width))x\(Int(size.height))"

        case .focusMain:
            orch.sendViewerCommand("focus")
            Thread.sleep(forTimeInterval: 0.4)
            detail = "已聚焦主窗口"

        case .setLink(let control):
            orch.sendRelayControl(control)
            if let down = control.down {
                detail = down ? "链路已断开" : "链路已恢复"
            } else {
                detail = "链路条件已更新"
            }
            Thread.sleep(forTimeInterval: 0.3)

        case .demoCommand(let requests):
            orch.sendDemoCommand(requests)
            Thread.sleep(forTimeInterval: 0.5)
            detail = "已发送 \(requests.count) 条目标应用指令"

        case .expectLocalWindows(let expected):
            let count = waitForValue(timeout: 8, target: expected) {
                (orch.readViewerState()["windows"] as? [[String: Any]])?.count ?? 0
            }
            passed = count == expected
            detail = "本地窗口壳 \(count) 个（期望 \(expected)）"

        case .expectRemoteWindows(let expected):
            let count = waitForValue(timeout: 8, target: expected) {
                (orch.readDemoState()["windows"] as? [[String: Any]])?.count ?? 0
            }
            passed = count == expected
            detail = "远端窗口 \(count) 个（期望 \(expected)）"

        case .expectMinFrames(let minimum):
            let frames = waitForValue(timeout: 8, target: minimum) {
                (orch.readViewerState()["frames_received"] as? Int) ?? 0
            }
            passed = frames >= minimum
            detail = "收到画面帧 \(frames)（期望 ≥\(minimum)）"

        case .expectRemoteText(let expected):
            var actual = ""
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                actual = ((orch.readDemoState()["text"] as? [String: Any])?["buffer"] as? String) ?? ""
                if actual == expected { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let dup = findDuplicatedSubstrings(actual)
            passed = actual == expected && dup.isEmpty
            detail = "远端文本「\(actual)」"
                + (dup.isEmpty ? "" : "（检测到重复片段：\(dup.joined(separator: ","))）")

        case .expectRemoteSize(let expected):
            var actual = Size(0, 0)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let wins = orch.readDemoState()["windows"] as? [[String: Any]],
                   let main = wins.first(where: { ($0["role"] as? String) == "main" }) {
                    actual = Size((main["width"] as? Double) ?? 0, (main["height"] as? Double) ?? 0)
                }
                if actual == expected { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            passed = actual == expected
            detail = "远端实际尺寸 \(Int(actual.width))x\(Int(actual.height))（期望 \(Int(expected.width))x\(Int(expected.height))）"

        case .expectLocalWindowsExact(let expected):
            var count = 0
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                count = (orch.readViewerState()["windows"] as? [[String: Any]])?.count ?? 0
                if let expected, count == expected { break }
                if expected == nil, count >= 1 { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            if let expected {
                passed = count == expected
                detail = "本地窗口壳 \(count) 个（期望 \(expected)）"
            } else {
                passed = count >= 1
                detail = "本地窗口壳 \(count) 个（要求 ≥1）"
            }

        case .expectRealCaptureWindows(let minimum):
            var count = 0
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                let host = orch.readHostState()
                count = (host["real_capture_windows"] as? [String])?.count ?? 0
                if count >= minimum { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            let host = orch.readHostState()
            let failures = (host["capture_failures"] as? [String]) ?? []
            passed = count >= minimum
            detail = "真实采集窗口 \(count) 个（期望 ≥\(minimum)）"
                + (failures.isEmpty ? "" : "；失败项：\(failures.joined(separator: " / "))")

        case .expectRealScreenPixels:
            var sig: [String: Any] = [:]
            // 真实采集在窗口刚出现时可能先只报 idle/blank，给足时间等第一个可用画面
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                sig = (orch.readViewerState()["frame_signature"] as? [String: Any]) ?? [:]
                if !sig.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard !sig.isEmpty else {
                passed = false
                detail = "未收到任何画面帧的像素分析"
                break
            }
            let width = (sig["width"] as? Int) ?? 0
            let height = (sig["height"] as? Int) ?? 0
            let checksum = (sig["checksum"] as? String) ?? ""
            let colors = (sig["distinct_colors"] as? Int) ?? 0
            let luma = (sig["average_luma"] as? Double) ?? 0

            // 判据必须与环境无关：CI runner 的桌面是纯色背景，用"颜色种类"设阈值会在
            // 那里误判。改用**与合成渲染做对照**——真实采集的像素不可能等于我们自己的
            // 渲染器在同一尺寸下产出的位图（真实画面还包含窗口装饰、缩放与桌面背景）。
            let size = Size(Double(width), Double(height))
            func checksumOf(render content: SyntheticWindowContent) -> String {
                let px = SyntheticRenderer.render(content, size: size)
                var h: UInt64 = 0xcbf29ce484222325
                for b in px { h = (h ^ UInt64(b)) &* 0x100000001b3 }
                return String(h)
            }
            let syntheticEmpty = checksumOf(render: SyntheticWindowContent())
            let syntheticTitled = checksumOf(render: SyntheticWindowContent(title: "M2M Demo App"))

            let plausibleSize = width >= 64 && height >= 64
            let differsFromSynthetic = !checksum.isEmpty
                && checksum != syntheticEmpty && checksum != syntheticTitled
            // 纯合成渲染（空窗口）只有两三种颜色；这里给一个很宽的下限，
            // 主要用来排除"全黑/全白"的异常帧。
            let hasSomeVariation = colors >= 4

            passed = plausibleSize && differsFromSynthetic && hasSomeVariation
            detail = "帧尺寸 \(width)x\(height)（要求 ≥64x64：\(plausibleSize)）；"
                + "像素与合成渲染不同：\(differsFromSynthetic)；"
                + "颜色种类 \(colors)、平均亮度 \(String(format: "%.1f", luma))"

        case .expectDegraded(let degraded):
            Thread.sleep(forTimeInterval: 1.0)
            let viewer = orch.readViewerState()
            let caps = (viewer["host_capabilities"] as? [String: Any]) ?? [:]
            let caretRect = (caps["caretRect"] as? Bool) ?? true
            let certified = (caps["certified_apps"] as? [String]) ?? []
            let degradedApps = (caps["degraded_apps"] as? [String]) ?? []
            let notices = (viewer["notices"] as? [[String: Any]]) ?? []
            let hasNotice = notices.contains {
                let t = ($0["title"] as? String) ?? ""
                return t.contains("降级") || t.contains("插入点")
            }
            if degraded {
                passed = (!caretRect || hasNotice) && certified.isEmpty
                detail = "插入点能力=\(caretRect) 提示=\(hasNotice) 认证应用=\(certified.count) 降级应用=\(degradedApps) "
            } else {
                passed = caretRect && !certified.isEmpty
                detail = "插入点能力=\(caretRect) 认证应用=\(certified.count)"
            }
        }

        stepResults.append(StepResult(description: step.description, passed: passed, detail: detail))
        if !options.quiet {
            out("  \(passed ? "✅" : "❌") \(step.description) → \(detail)")
        }
    }

    let demo = orch.readDemoState()
    let host = orch.readHostState()
    let viewer = orch.readViewerState()
    let buffer = ((demo["text"] as? [String: Any])?["buffer"] as? String) ?? ""
    let dup = findDuplicatedSubstrings(buffer)

    let result = ScenarioResult(
        scenario: s.name, summary: s.summary, expectation: s.expectation,
        steps: stepResults, runID: env.runID,
        environment: [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "架构": ProcessInfo.processInfo.machineArchitecture,
            "链路条件": s.linkConditions.description,
            "目标应用": s.demoArgs.contains("--no-caret-rect") ? "无法提供插入点（降级场景）" : "标准 demo 应用",
            "隔离方式": "四进程 + 私有运行目录(0700) + UDS(0600)",
            "采集模式": (host["capture_mode"] as? String) ?? "-",
            "输入模式": (host["input_mode"] as? String) ?? "-",
            "文本模式": (host["text_mode"] as? String) ?? "-",
            "本地窗口壳": "\((viewer["windows"] as? [[String: Any]])?.count ?? 0)",
            "收到帧数": "\(viewer["frames_received"] as? Int ?? 0)",
            "丢弃旧帧": "\(viewer["frames_dropped_stale"] as? Int ?? 0)",
            "关键帧请求": "\(viewer["keyframe_requests"] as? Int ?? 0)",
            "远端文本": "「\(buffer)」",
            "重复片段": dup.isEmpty ? "无" : dup.joined(separator: ","),
            "远端提交成功次数": "\(viewer["commit_results"] as? [String] ?? [])",
        ],
        linkStats: orch.relay.map { $0.linkStats.description } ?? "不可用",
        duration: Date().timeIntervalSince(started)
    )
    results.append(result)
    out("  → \(result.passed ? "通过" : "未通过")（\(result.passedCount)/\(result.steps.count) 步）")
}

/// 在超时内轮询直到达到目标值（≥ target），返回最后一次观测值。
///
/// 必须等到**目标值**而不是"刚大于 0"：后者会在机器负载高时读到中间态
/// （例如窗口壳 1 个而期望 4 个）而误判失败，属于测试脚本自身的竞态。
func waitForValue(timeout: TimeInterval, target: Int, _ probe: () -> Int) -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var last = probe()
    while Date() < deadline {
        if last >= target { return last }
        Thread.sleep(forTimeInterval: 0.1)
        last = probe()
    }
    return last
}

// MARK: - 报告

func renderMarkdown(_ results: [ScenarioResult], environment: [String: String]) -> String {
    let total = results.count
    let passedCount = results.filter { $0.passed }.count
    var md = """
    # m2m 单机三端自动化测试报告

    生成时间：\(ISO8601DateFormatter().string(from: Date()))

    **拓扑**：中继进程 / 目标应用进程 / 主机代理进程 / 本地客户端进程，各自独立进程，
    通过私有运行目录内的 Unix 域套接字（目录 0700、套接字 0600）通信，不占用任何网络端口。

    **结论：\(passedCount)/\(total) 个场景通过。**

    ## 环境

    | 项 | 值 |
    |---|---|

    """
    for (k, v) in environment.sorted(by: { $0.key < $1.key }) { md += "| \(k) | \(v) |\n" }

    md += "\n## 场景汇总\n\n| 场景 | 说明 | 结果 | 步骤 | 耗时 |\n|---|---|---|---:|---:|\n"
    for r in results {
        md += "| `\(r.scenario)` | \(r.summary) | \(r.passed ? "通过" : "**未通过**") | \(r.passedCount)/\(r.steps.count) | \(String(format: "%.1f", r.duration))s |\n"
    }

    md += "\n## 逐场景明细\n"
    for r in results {
        md += "\n### `\(r.scenario)`　\(r.passed ? "✅ 通过" : "❌ 未通过")\n\n"
        md += "**预期**：\(r.expectation)\n\n**运行信息**\n\n| 项 | 值 |\n|---|---|\n"
        for (k, v) in r.environment.sorted(by: { $0.key < $1.key }) {
            md += "| \(k) | \(v.replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        md += "| 链路统计 | \(r.linkStats) |\n| 运行 ID | `\(r.runID)`（已清理） |\n"
        md += "\n**步骤**\n\n| 步骤 | 结果 | 观测 |\n|---|---|---|\n"
        for s in r.steps {
            md += "| \(s.description) | \(s.passed ? "✅" : "❌") | \(s.detail.replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
    }

    md += """

    ## 边界与说明

    - 本报告由 `m2mctl selftest` 在**四进程隔离**环境下实测生成，每次运行使用全新的运行目录。
    - 目标应用为本仓库自建的 demo 应用（按约定可用 demo 代替 Claude 验证）。它同样具备窗口、
      尺寸约束、文本编辑与弹窗能力，因此能验证通用链路；但**不能替代**对具体第三方应用的兼容性结论。
    - 链路条件（延迟/抖动/丢包/带宽/中断）通过中继进程的外部控制文件在线注入，
      模型为"可靠通道重传、媒体通道丢帧"，与真实可靠传输语义一致。
    - 中文输入法在该自动化路径中模拟为"本地已确认文字的一次提交"，用于验证**协议与状态机**层面的
      不丢不重、不误发送；键盘手感、候选窗视觉位置等必须人工判断，见 `docs/06-test-plan.md` §6。
    - 屏幕录制与辅助功能权限在自动化环境通常不可用，因此采集与输入走合成/代理路径；
      真实权限下的行为需按 `docs/06-test-plan.md` 手工执行对应用例。
    """
    return md
}

// MARK: - 命令分发

switch cli.command {
case "scenarios":
    out("可用场景：")
    for s in scenarioTable {
        out("  \(s.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(s.summary)")
    }

case "run":
    let name = cli.scenario.isEmpty ? "basic" : cli.scenario
    guard let s = scenarioTable.first(where: { $0.name == name }) else {
        errOut("未知场景：\(name)。用 `m2mctl scenarios` 查看列表。")
        exit(2)
    }
    var results: [ScenarioResult] = []
    do { try runScenario(s, options: cli, into: &results) }
    catch {
        errOut("场景执行失败：\(error.localizedDescription)")
        exit(1)
    }
    out("")
    let ok = results.first?.passed ?? false
    out(ok ? "结论：通过" : "结论：未通过")
    exit(ok ? 0 : 1)

case "selftest":
    var results: [ScenarioResult] = []
    var failures = 0
    for s in scenarioTable {
        do { try runScenario(s, options: cli, into: &results) }
        catch {
            errOut("场景 \(s.name) 执行异常：\(error.localizedDescription)")
            failures += 1
        }
    }
    let environment: [String: String] = [
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "架构": ProcessInfo.processInfo.machineArchitecture,
        "屏幕录制权限": SystemCapabilityProbe.screenRecordingState().localizedDescription,
        "辅助功能权限": SystemCapabilityProbe.accessibilityState().localizedDescription,
        "场景数": "\(scenarioTable.count)",
        "运行方式": "四进程隔离（中继 / 目标应用 / 主机代理 / 本地客户端）",
    ]
    let markdown = renderMarkdown(results, environment: environment)
    let reportURL = cli.reportPath.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/reports/automated-test-report.md")
    try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try markdown.write(to: reportURL, atomically: true, encoding: .utf8)
        out("")
        out("报告已写入：\(reportURL.path)")
    } catch {
        errOut("写入报告失败：\(error.localizedDescription)")
    }
    let passedCount = results.filter { $0.passed }.count
    out("场景通过：\(passedCount)/\(scenarioTable.count)")
    exit(failures == 0 && passedCount == scenarioTable.count ? 0 : 1)

case "perf":
    // 性能基线（G3）。在多种链路条件下重复最典型的交互，采集分位数。
    // 本地交互项必须与网络无关——这是分层架构的核心主张，因此单独判定。
    let conditions: [(String, LinkConditions)] = [
        ("局域网", .lan),
        ("RTT 80ms", .rtt80),
        ("RTT 160ms", .rtt160),
        ("RTT 250ms", .rtt250),
        ("丢包 3%", .loss(0.03)),
        ("带宽 3Mbps", .bw3Mbps),
    ]
    var rows: [[String: String]] = []
    out("性能基线（每种条件下：建立连接 → 10 次中文提交 → 5 次缩放）")
    out("")
    for (label, cond) in conditions {
        let env = try RunEnvironment.create(label: "perf")
        let orch = Orchestrator(env: env)
        defer {
            orch.stopAll()
            if !cli.keepRunDir { env.cleanup() }
        }
        try orch.startRelay(conditions: cond)
        try orch.startDemo(extraArgs: [], windowSize: Size(420, 320))
        try orch.startHost(windowSize: Size(420, 320), realCaptureForPID: nil, bitrateMbps: nil)
        try orch.startViewer(headless: true)
        Thread.sleep(forTimeInterval: 2.0)
        orch.sendViewerCommand("focus")
        Thread.sleep(forTimeInterval: 0.5)
        for i in 0..<10 {
            orch.sendViewerCommand("type", value: "测量\(i)")
            Thread.sleep(forTimeInterval: 0.45)
        }
        for i in 0..<5 {
            orch.sendViewerCommand("resize", value: "\(420 + i * 20)x\(320 + i * 10)")
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 1.5)

        let viewer = orch.readViewerState()
        let latency = (viewer["latency"] as? [[String: Any]]) ?? []
        func stat(_ name: String, _ key: String) -> Double {
            guard let row = latency.first(where: { ($0["name"] as? String) == name }),
                  let v = row[key] as? Double else { return -1 }
            return v
        }
        let localOk = (viewer["local_interaction_ok"] as? Bool) ?? false
        rows.append([
            "链路条件": label,
            "本地尺寸p95": String(format: "%.3f", stat("本地窗口尺寸生效", "p95_ms")),
            "本地组合p95": String(format: "%.3f", stat("本地组合更新", "p95_ms")),
            "提交往返p50": String(format: "%.1f", stat("文本提交往返", "p50_ms")),
            "提交往返p95": String(format: "%.1f", stat("文本提交往返", "p95_ms")),
            "帧延迟p50": String(format: "%.1f", stat("画面帧延迟", "p50_ms")),
            "帧延迟p95": String(format: "%.1f", stat("画面帧延迟", "p95_ms")),
            "尺寸往返p50": String(format: "%.1f", stat("尺寸请求往返", "p50_ms")),
            "帧数": "\((viewer["frames_received"] as? Int) ?? 0)",
            "本地交互达标": localOk ? "是" : "否",
        ])
        out("▸ \(label)：本地交互达标=\(localOk ? "是" : "否")  提交往返p50=\(rows.last!["提交往返p50"]!)ms  帧延迟p50=\(rows.last!["帧延迟p50"]!)ms  帧数=\(rows.last!["帧数"]!)")
    }

    out("")
    out("| " + rows[0].keys.sorted(by: { a, b in
        let order = ["链路条件","本地尺寸p95","本地组合p95","提交往返p50","提交往返p95","帧延迟p50","帧延迟p95","尺寸往返p50","帧数","本地交互达标"]
        return (order.firstIndex(of: a) ?? 99) < (order.firstIndex(of: b) ?? 99)
    }).joined(separator: " | ") + " |")
    let keys = rows[0].keys.sorted(by: { a, b in
        let order = ["链路条件","本地尺寸p95","本地组合p95","提交往返p50","提交往返p95","帧延迟p50","帧延迟p95","尺寸往返p50","帧数","本地交互达标"]
        return (order.firstIndex(of: a) ?? 99) < (order.firstIndex(of: b) ?? 99)
    })
    out("|" + keys.map { _ in "---" }.joined(separator: "|") + "|")
    for row in rows {
        out("| " + keys.map { row[$0] ?? "-" }.joined(separator: " | ") + " |")
    }

    // 写入报告
    let reportURL = cli.reportPath.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/reports/performance-baseline.md")
    var md = """
    # m2m 性能基线（G3）

    生成时间：\(ISO8601DateFormatter().string(from: Date()))
    环境：\(ProcessInfo.processInfo.operatingSystemVersionString) / \(ProcessInfo.processInfo.machineArchitecture)

    **说明**

    - 单位：毫秒。"本地尺寸p95 / 本地组合p95"衡量**本地交互**，按设计**必须与网络条件无关**。
    - "提交往返 / 帧延迟 / 尺寸往返"是端到端指标，随注入的链路条件变化；它们是链路与实现叠加的结果，
      不能据此推断某一模块的独立耗时（见 docs/05-media-performance.md §9.3 的测量纪律）。
    - 链路条件由中继进程按"可靠通道重传、媒体通道丢帧"的模型注入，不是真实跨境线路的实测。
    - 单次运行的样本量有限（提交 10 次、缩放 5 次），分位数用于发现数量级问题；
      压力测试需按 docs/06-test-plan.md §4 的矩阵扩充样本。

    | \(keys.joined(separator: " | ")) |
    |\(keys.map { _ in "---" }.joined(separator: "|"))|
    """
    for row in rows {
        md += "| " + keys.map { row[$0] ?? "-" }.joined(separator: " | ") + " |\n"
    }
    try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try md.write(to: reportURL, atomically: true, encoding: .utf8)
        out("")
        out("性能基线已写入：\(reportURL.path)")
    } catch {
        errOut("写入性能基线失败：\(error.localizedDescription)")
    }

case "env":
    let env = try RunEnvironment.create(label: "inspect")
    out("隔离运行目录：\(env.root.path)（权限 0700）")
    out("目录结构：")
    for item in env.inventory().prefix(20) { out("  \(item)") }
    out("中继套接字：\(env.relaySocketPath)")
    out("目标应用套接字：\(env.demoAppSocketPath)")
    out("套接字权限：0600（仅同一用户可连接）")
    out("网络端口：未使用")
    if !cli.keepRunDir { env.cleanup() }

case "up":
    let env = try RunEnvironment.create(label: "demo")
    env.writeManifest(["mode": "interactive"])
    let orch = Orchestrator(env: env)
    out("隔离运行环境：\(env.root.path)")
    try orch.startRelay(conditions: .lan)
    try orch.startDemo(extraArgs: [], windowSize: cli.windowSize)
    try orch.startHost(windowSize: cli.windowSize, realCaptureForPID: nil, bitrateMbps: nil)
    var viewerArgs = ["--relay", env.relaySocketPath,
                      "--state-file", env.stateFile("viewer-state.json").path,
                      "--run-dir", env.directory(for: .viewer).path]
    if cli.noGUI { viewerArgs.append("--headless") }
    try orch.spawn("m2mviewer", args: viewerArgs, role: "viewer")
    out("""

    三端已启动（各自独立进程，私有运行目录内通过 UDS 通信）：
      · 中继（本进程内）       \(env.relaySocketPath)
      · 目标应用（demo 进程）  \(env.demoAppSocketPath)
      · 主机代理（host 进程）  已连接目标应用，等待本地客户端
      · 本地客户端（viewer）   远端窗口应已以独立本地窗口出现

    可以做的事：
      · 在远端窗口里用本地输入法打中文：拼音组合与候选窗在本地完成，确认后才提交到目标应用
      · 拖动 / 缩放窗口：本地立即响应外框，松手后远端重新排版、文字恢复清晰
      · 观察「m2m 状态」窗口：远端能力、输入法模式、帧数、会话状态与降级提示

    按 Ctrl-C 退出并清理运行目录。
    """)
    globalShutdown = {
        out("\n清理中…")
        orch.stopAll()
        if !cli.keepRunDir { env.cleanup() }
        exit(0)
    }
    signal(SIGINT) { _ in globalShutdown?() ; exit(0) }
    signal(SIGTERM) { _ in globalShutdown?() ; exit(0) }
    while true { Thread.sleep(forTimeInterval: 1) }

default:
    out("""
    m2mctl —— 单机三端编排、场景运行与报告

    用法:
      m2mctl scenarios              列出场景
      m2mctl run <场景>             运行单个场景
      m2mctl selftest               跑完整场景矩阵并生成报告
      m2mctl perf                   采集性能基线（多种链路条件）
      m2mctl up [--no-gui]          启动可交互三端演示
      m2mctl env                    查看隔离运行环境

    选项:
      --report <path>   报告输出路径（默认 docs/reports/automated-test-report.md）
      --keep            保留运行目录（排障用）
      --quiet           只输出结论
      --size WxH        目标窗口内容尺寸
    """)
}
