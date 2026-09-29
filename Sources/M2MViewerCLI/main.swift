import Foundation
import AppKit
import M2MCore

// m2mviewer —— 本地原生客户端（独立进程）
//
// 一期核心体验都在这里：
//   · 远端窗口 → 本地独立 NSWindow，可与本地应用混排
//   · 中文输入法 → 本地组合与候选窗，确认后经文本通道提交（不经网络往返选词）
//   · 快捷键 → 与输入法路径分开，直接发往远端
//   · 缩放 → 本地立即改变外框，远端重新排版后恢复清晰
//
// 无 GUI 模式（--headless）用于自动化：仍然跑完整的协议与状态机，只是不创建窗口。

struct ViewerOptions {
    var relaySocket = ""
    var runDir: String?
    var stateFile: String?
    var headless = false
    var script: [String] = []
    var duration: Double = 0
}

func parseViewerOptions() -> ViewerOptions {
    var o = ViewerOptions()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--relay": o.relaySocket = it.next() ?? ""
        case "--run-dir": o.runDir = it.next()
        case "--state-file": o.stateFile = it.next()
        case "--headless": o.headless = true
        case "--duration": o.duration = Double(it.next() ?? "0") ?? 0
        case "--script":
            if let s = it.next() { o.script = s.split(separator: ";").map(String.init) }
        case "--help", "-h":
            print("""
            m2mviewer —— 本地原生客户端

            用法: m2mviewer --relay <path> [选项]

              --relay <path>       中继套接字（必填）
              --headless           不创建窗口（自动化用）
              --script <步骤;…>    自动化脚本：type:文本 / resize:WxH / focus / action:名称
              --duration <秒>      运行指定时长后自动退出
              --state-file <path>  周期性写出运行状态（供断言与报告）
              --run-dir <dir>      隔离运行目录
            """)
            exit(0)
        default: break
        }
    }
    return o
}

func logViewer(_ m: String) { FileHandle.standardError.write(Data("[viewer] \(m)\n".utf8)) }

let viewerOptions = parseViewerOptions()
guard !viewerOptions.relaySocket.isEmpty else {
    FileHandle.standardError.write(Data("m2mviewer: 缺少 --relay\n".utf8))
    exit(2)
}

let viewerConnection: IPCConnection
do {
    viewerConnection = try IPCClient.connectWithRetry(to: viewerOptions.relaySocket, timeout: 10)
} catch {
    FileHandle.standardError.write(Data("m2mviewer: 连接中继失败 \(error)\n".utf8))
    exit(1)
}

let viewerTransport = MuxTransport(connection: viewerConnection)
viewerTransport.start()

let viewerEpoch: UInt64 = 1
let viewerBus = MessageBus(epoch: viewerEpoch)
let viewerSession = Session(epoch: viewerEpoch)
let viewerRunDir = viewerOptions.runDir.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("m2m-viewer-\(UUID().uuidString.prefix(8))")
try? FileManager.default.createDirectory(at: viewerRunDir, withIntermediateDirectories: true)

let viewerRuntime = ViewerRuntime(bus: viewerBus, session: viewerSession,
                                  decoder: ScreenRLEDecoder(),
                                  fileBridge: FileBridge(remoteTempDirectory: viewerRunDir,
                                                         chunkSize: 32 * 1024,
                                                         rateLimitBytesPerSecond: 256 * 1024))
viewerBus.attach(viewerTransport)

// 会话与运行时的消息处理放在独立队列，避免与传输读取队列互相等待
let viewerQueue = DispatchQueue(label: "m2m.viewer.session")
viewerBus.deliveryQueue = viewerQueue

signal(SIGTERM) { _ in viewerConnection.close(); exit(0) }
signal(SIGINT) { _ in viewerConnection.close(); exit(0) }

let viewerStateURL = viewerOptions.stateFile.map { URL(fileURLWithPath: $0) }
let viewerPid = getpid()

// 外部命令队列：编排器（m2mctl）向本地客户端投递交互命令的方式，
// 与状态文件同属私有运行目录，不引入额外连接或网络监听面。
//
// **实现约束**：命令处理绝不能阻塞会话队列——消息投递也走这条队列，
// 一旦阻塞等待，就永远等不到自己的响应。因此文本输入被拆成由定时器推进的状态机。
let viewerCommandFile = viewerRunDir.appendingPathComponent("commands.json")

enum PendingInputPhase {
    case awaitingContext
    case readyToCommit
    case awaitingCommitResult
}

struct PendingInput {
    var text: String
    var phase: PendingInputPhase
    var deadline: Date
}

nonisolated(unsafe) var pendingInput: PendingInput?

/// 读取并接受外部命令（在会话队列上执行，但不做任何阻塞等待）。
func acceptViewerCommands() {
    guard let data = try? Data(contentsOf: viewerCommandFile),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          !list.isEmpty else { return }
    try? FileManager.default.removeItem(at: viewerCommandFile)
    for entry in list {
        let op = (entry["op"] as? String) ?? ""
        let value = entry["value"] as? String
        switch op {
        case "focus":
            if let uid = viewerRuntime.windowTable.allShells.first(where: { $0.role == .main })?.windowUID
                ?? viewerRuntime.windowTable.allShells.first?.windowUID {
                viewerRuntime.focus(windowUID: uid)
                logViewer("外部指令：聚焦 \(uid)")
            }
        case "type":
            guard let text = value, !text.isEmpty else { break }
            if let uid = viewerRuntime.windowTable.allShells.first(where: { $0.role == .main })?.windowUID
                ?? viewerRuntime.windowTable.allShells.first?.windowUID {
                viewerRuntime.inputRouter.setTargetWindow(uid)
            }
            // 主动请求编辑上下文；拿不到就如实放弃（绝不伪造版本号）
            viewerRuntime.requestTextContext(reason: "script-type")
            pendingInput = PendingInput(text: text, phase: .awaitingContext,
                                        deadline: Date().addingTimeInterval(5.0))
            logViewer("外部指令：准备提交「\(text)」，已请求编辑上下文")
        case "resize":
            guard let v = value else { break }
            let parts = v.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2,
               let uid = viewerRuntime.windowTable.allShells.first(where: { $0.role == .main })?.windowUID
                ?? viewerRuntime.windowTable.allShells.first?.windowUID {
                viewerRuntime.beginResize(windowUID: uid, requested: Size(parts[0], parts[1]))
                viewerRuntime.endResize(windowUID: uid, finalSize: Size(parts[0], parts[1]))
                logViewer("外部指令：请求尺寸 \(Int(parts[0]))x\(Int(parts[1]))")
            }
        default: break
        }
    }
}

/// 推进待处理的文本输入。由定时器调用，绝不阻塞。
func advancePendingInput(now: TimeInterval) {
    guard var input = pendingInput else { return }
    if Date() > input.deadline {
        logViewer("待处理输入超时（阶段 \(input.phase)）：已放弃，不伪造")
        pendingInput = nil
        return
    }
    switch input.phase {
    case .awaitingContext:
        guard let ctx = viewerRuntime.textBridge.context else { return }
        if !viewerRuntime.textBridge.state.isComposing {
            viewerRuntime.textBridge.beginComposition(editVersion: ctx.editVersion)
        }
        viewerRuntime.textBridge.updateComposition(input.text)
        input.phase = .readyToCommit
        pendingInput = input
    case .readyToCommit:
        let sent = viewerRuntime.confirmComposition(input.text, at: now)
        if sent > 0 {
            logViewer("外部指令：已提交「\(input.text)」")
            input.phase = .awaitingCommitResult
            input.deadline = Date().addingTimeInterval(5.0)
            pendingInput = input
        }
    case .awaitingCommitResult:
        // 结果由 TextBridge 处理（成功 / 拒绝 / 结果不明），此处只等待落定
        if !viewerRuntime.textBridge.state.isCommitting {
            if case .pendingUnknown = viewerRuntime.textBridge.state {
                logViewer("外部指令：本条输入结果未确认，等待重新同步（不自动重试）")
            }
            pendingInput = nil
        }
    }
}

func writeViewerState() {
    guard let viewerStateURL else { return }
    let shells = viewerRuntime.windowTable.allShells.map {
        ["uid": $0.windowUID, "title": $0.title, "role": $0.role.localizedDescription,
         "remoteW": $0.remoteContentSize.width, "remoteH": $0.remoteContentSize.height,
         "localW": $0.localContentSize.width, "localH": $0.localContentSize.height,
         "layoutVersion": $0.layoutVersion, "degraded": $0.isDegraded,
         "degradedReason": $0.degradedReason ?? ""]
    }
    var info: [String: Any] = [
        "role": "viewer",
        "pid": Int(viewerPid),
        "epoch": viewerSession.epoch,
        "phase": viewerSession.phase.rawValue,
        "layout_version": viewerRuntime.layoutVersion,
        "windows": shells,
        "streams": Array(viewerRuntime.streams.keys),
        "frames_received": viewerRuntime.framesReceived,
        "frames_dropped_stale": viewerRuntime.framesDroppedStale,
        "keyframe_requests": viewerRuntime.keyframeRequestsSent,
        "text_state": "\(viewerRuntime.textBridge.state)",
        "commit_results": viewerRuntime.commitResults.map { $0.status.localizedDescription },
        "notices": viewerRuntime.notices.map {
            ["title": $0.title, "detail": $0.detail, "severity": $0.severity.rawValue]
        },
        "host_capabilities": viewerRuntime.hostCapabilities.map {
            ["caretRect": $0.text.caretRect, "ax": $0.text.axAvailable,
             "certified_apps": $0.apps.filter { $0.certified }.map { $0.displayName },
             "degraded_apps": $0.apps.filter { !$0.certified }.map { $0.displayName }]
        } ?? [:],
    ]
    if let coord = ViewerUIBridge.shared.lastCaretLocalRect {
        info["caret_local_rect"] = ["x": coord.origin.x, "y": coord.origin.y,
                                    "w": coord.size.width, "h": coord.size.height]
    }
    info["caret_valid"] = viewerRuntime.textBridge.context?.caret.valid ?? false
    info["composition"] = viewerRuntime.textBridge.state.isComposing
    if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: viewerStateURL, options: .atomic)
    }
}

/// GUI 与运行时的桥：无 GUI 模式下为空实现，保证两条路径共用同一套逻辑。
final class ViewerUIBridge {
    static let shared = ViewerUIBridge()
    var lastCaretLocalRect: Rect?
    var onWindowsChanged: (() -> Void)?
    var onFramesReady: (() -> Void)?
    func refreshWindows() { onWindowsChanged?() }
    func refreshFrames() { onFramesReady?() }
    func showNotice(_ notice: Notice) {}
}

logViewer("已连接中继 socket=\(viewerOptions.relaySocket)")

// MARK: 启动

viewerSession.onPhaseChange = { phase in logViewer("会话状态：\(phase.localizedDescription)") }

let viewerTimer = DispatchSource.makeTimerSource(queue: viewerQueue)
viewerTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
viewerTimer.setEventHandler {
    let now = Date().timeIntervalSinceReferenceDate
    viewerRuntime.tick(now: now)
    ViewerUIBridge.shared.refreshFrames()
}
viewerTimer.resume()

// 半秒后写一次状态，之后每 200ms 一次
let stateQueue = DispatchQueue(label: "m2m.viewer.state")
let stateTimer = DispatchSource.makeTimerSource(queue: stateQueue)
stateTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
stateTimer.setEventHandler {
    let now = Date().timeIntervalSinceReferenceDate
    viewerQueue.sync {
        acceptViewerCommands()
        // 在途提交超时判定：转入"结果不明"，绝不自动重试
        viewerRuntime.tick(now: now)
        advancePendingInput(now: now)
    }
    writeViewerState()
}
stateTimer.resume()

if viewerOptions.headless {
    runHeadlessViewer(options: viewerOptions)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let controller = ViewerWindowController(runtime: viewerRuntime, queue: viewerQueue)
    ViewerUIBridge.shared.onWindowsChanged = { [weak controller] in
        DispatchQueue.main.async { controller?.syncWindows() }
    }
    ViewerUIBridge.shared.onFramesReady = { [weak controller] in
        DispatchQueue.main.async { controller?.syncWindows() }
    }
    app.delegate = controller

    // 运行脚本（如果有），便于自动化操作真实 GUI
    if !viewerOptions.script.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            runViewerScript(viewerOptions.script, runtime: viewerRuntime, queue: viewerQueue)
        }
    }
    if viewerOptions.duration > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + viewerOptions.duration) {
            writeViewerState()
            exit(0)
        }
    }
    app.run()
}

func runViewerScript(_ steps: [String], runtime: ViewerRuntime, queue: DispatchQueue) {
    var delay = 0.0
    for step in steps {
        delay += 0.6
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let verb = parts[0], value = parts[1]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            queue.sync {
                let now = Date().timeIntervalSinceReferenceDate
                switch verb {
                case "type":
                    runtime.textBridge.receive(context: runtime.textBridge.context
                        ?? TextContext(epoch: 1, editVersion: 0, windowUID: "", nodeID: "",
                                       role: .unknown, editable: false, acceptsUnicodeEvents: true,
                                       caret: CaretInfo(valid: false), selection: SelectionInfo(valid: false)))
                    if let ctx = runtime.textBridge.context {
                        runtime.textBridge.beginComposition(editVersion: ctx.editVersion)
                        runtime.textBridge.updateComposition(value)
                    }
                    _ = runtime.confirmComposition(value, at: now)
                case "resize":
                    let p = value.split(separator: "x").compactMap { Double($0) }
                    if p.count == 2, let uid = runtime.windowTable.allShells.first(where: { $0.role == .main })?.windowUID {
                        runtime.endResize(windowUID: uid, finalSize: Size(p[0], p[1]))
                    }
                case "focus":
                    if let uid = runtime.windowTable.allShells.first(where: { $0.role == .main })?.windowUID {
                        runtime.focus(windowUID: uid)
                    }
                case "action":
                    if let uid = runtime.windowTable.allShells.first(where: { $0.title == value })?.windowUID,
                       let a = DemoRequest.actionFromName(value) {
                        runtime.perform(action: a, on: uid)
                    } else if let uid = runtime.windowTable.allShells.first?.windowUID,
                              let a = DemoRequest.actionFromName(value) {
                        runtime.perform(action: a, on: uid)
                    }
                default: break
                }
            }
        }
    }
}

func runHeadlessViewer(options: ViewerOptions) {
    viewerRuntime.sendHello()
    logViewer("headless 模式：已发送握手")
    if !options.script.isEmpty {
        runViewerScript(options.script, runtime: viewerRuntime, queue: viewerQueue)
    }
    if options.duration > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + options.duration) {
            writeViewerState()
            exit(0)
        }
    }
    dispatchMain()
}
