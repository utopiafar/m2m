import Foundation
import M2MCore

// m2mhost —— 远端主机代理（独立进程）
//
// 职责：定位目标应用 → 维护窗口注册表 → 采集与编码 → 经中继把画面送到 Viewer
//       ← 接收并执行来自 Viewer 的输入与文本提交
//
// 与真实模式的差别只在"目标应用"和"采集源"：
//   --demo-socket 连接真实的 demo 进程（默认，无需任何系统权限）
//   --real        使用 ScreenCaptureKit + AX + CGEvent（需要屏幕录制与辅助功能权限）
//
// 两种模式共用**同一份**窗口注册表、媒体管线、文本会话、输入路由与恢复逻辑，
// 因此合成模式下的验证结论对真实模式同样有意义。

struct HostOptions {
    var relaySocket = ""
    var demoSocket: String?
    var runDir: String?
    var stateFile: String?
    var targetFPS: Double = 30
    var bitrateMbps: Double = 8
    var useReal = false
    var targetPID: Int32?
    var windowSize = Size(560, 380)
}

func parseHostOptions() -> HostOptions {
    var o = HostOptions()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--relay": o.relaySocket = it.next() ?? ""
        case "--demo-socket": o.demoSocket = it.next()
        case "--run-dir": o.runDir = it.next()
        case "--state-file": o.stateFile = it.next()
        case "--fps": o.targetFPS = Double(it.next() ?? "30") ?? 30
        case "--bitrate": o.bitrateMbps = Double(it.next() ?? "8") ?? 8
        case "--real": o.useReal = true
        case "--pid": o.targetPID = Int32(it.next() ?? "")
        case "--size":
            if let s = it.next() {
                let p = s.split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { o.windowSize = Size(p[0], p[1]) }
            }
        case "--help", "-h":
            print("""
            m2mhost —— 远端主机代理

            用法: m2mhost --relay <path> [选项]

              --relay <path>        中继套接字（必填）
              --demo-socket <path>  连接目标应用进程（推荐，无需系统权限）
              --real                改用 ScreenCaptureKit + AX + CGEvent（需权限）
              --pid <pid>           --real 模式下的目标进程
              --fps <n>             目标帧率（默认 30）
              --bitrate <mbps>      目标码率（默认 8）
              --size WxH            内置 demo 窗口尺寸
              --state-file <path>   周期性写出运行状态（供断言与报告）
              --run-dir <dir>       隔离运行目录
            """)
            exit(0)
        default: break
        }
    }
    return o
}

func logHost(_ m: String) { FileHandle.standardError.write(Data("[host] \(m)\n".utf8)) }

let hostOptions = parseHostOptions()
guard !hostOptions.relaySocket.isEmpty else {
    FileHandle.standardError.write(Data("m2mhost: 缺少 --relay\n".utf8))
    exit(2)
}

let sessionQueue = DispatchQueue(label: "m2m.host.session")

// MARK: 目标应用与能力探测

var hostCapability = SystemCapabilityProbe.report()
let hostWindowProvider: WindowProvider
let hostInputSink: InputSink
/// 通用文本上下文提供者（可能是外部 demo 代理，也可能是进程内合成模型）
var hostTextProvider: TextContextProvider?
/// 提交执行器（必须有：缺了它会出现"能看到上下文但提交永远失败"的静默降级）
var hostCommitExecutor: TextCommitExecutor?
var hostDemoProxy: DemoAppProxy?

let runRoot = hostOptions.runDir.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("m2m-host-\(UUID().uuidString.prefix(8))")
try? FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
let receivedDir = runRoot.appendingPathComponent("received")
try? FileManager.default.createDirectory(at: receivedDir, withIntermediateDirectories: true)

if let demoSocket = hostOptions.demoSocket, !demoSocket.isEmpty,
   let connection = try? IPCClient.connectWithRetry(to: demoSocket, timeout: 5) {
    let proxy = DemoAppProxy(connection: connection)
    hostDemoProxy = proxy
    hostWindowProvider = proxy
    hostInputSink = proxy
    // 关键接线：目标应用既是窗口/输入的去处，也是文本上下文的来源与提交的落点
    hostTextProvider = proxy
    hostCommitExecutor = DemoTextCommitExecutor(proxy: proxy)
    // 能力上报必须反映**目标应用的真实能力**，而不是本机自身的权限状态：
    // 走代理链路时不需要辅助功能权限，能提供插入点就应如实上报为完整本地输入法能力。
    if let snap = proxy.refreshSnapshot() {
        hostCapability.screenRecording = .notRequired
        hostCapability.accessibility = .notRequired
        hostCapability.captureMode = .synthetic
        hostCapability.inputMode = .realEventInjection
        hostCapability.textMode = snap.text.caretRectValid ? .fullLocalIME : .degradedCaret
    }
    logHost("已连接目标应用进程 socket=\(demoSocket)")
    if let snap = proxy.refreshSnapshot() {
        logHost("目标应用 \(snap.displayName) pid=\(snap.pid) 窗口=\(snap.windows.count)")
    }
} else if hostOptions.useReal, let pid = hostOptions.targetPID {
    let ax = AXWindowProvider(targetPID: pid, bundleID: "unknown", displayName: "Target")
    hostWindowProvider = ax
    hostInputSink = CGEventInputSink(targetPID: pid)
    if !ax.available {
        logHost("警告：缺少辅助功能权限，窗口读取与输入注入不可用（报告中会如实标注）")
    }
} else {
    // 进程内合成目标应用：与真实模式共用同一份运行时
    let model = SyntheticAppModel(pid: getpid(), contentScale: 2.0)
    if let uid = model.focusedWindowUID {
        model.setSize(uid, hostOptions.windowSize)
        model.setTitle(uid, "内置 Demo 应用")
    }
    let provider = SyntheticTextContextProvider(model: model, epoch: 1)
    hostTextProvider = provider
    hostCommitExecutor = HostRuntime.SyntheticCommitExecutor(provider: provider)
    hostWindowProvider = SyntheticWindowProvider(model: model)
    hostInputSink = SyntheticInputSink(model: model)
    logHost("未指定 --demo-socket，使用进程内合成目标应用")
}

// MARK: 采集源

var captureSources: [String: CaptureSource] = [:]

func ensureCaptureSources() {
    let wins = hostWindowProvider.currentWindows()
    for w in wins where w.role.requiresLocalShell {
        let streamID = "stream:\(w.windowUID)"
        let content: SyntheticWindowContent
        if let snap = hostDemoProxy?.cachedTextState {
            content = SyntheticWindowContent(title: w.title, textContent: snap.buffer,
                                             caretOffset: snap.caret, selectionLength: snap.selection)
        } else if let snap = hostDemoProxy?.cachedTextState {
            content = SyntheticWindowContent(title: w.title, textContent: snap.buffer,
                                             caretOffset: snap.caret, selectionLength: snap.selection)
        } else {
            content = SyntheticWindowContent(title: w.title)
        }
        if let existing = captureSources[w.windowUID] as? SyntheticCaptureSource {
            existing.size = w.contentSize
            existing.content = content
        } else {
            captureSources[w.windowUID] = SyntheticCaptureSource(streamID: streamID,
                                                                 size: w.contentSize,
                                                                 contentScale: w.contentScale,
                                                                 content: content)
        }
    }
}

// MARK: 中继连接与运行时

let hostConnection: IPCConnection
do {
    hostConnection = try IPCClient.connectWithRetry(to: hostOptions.relaySocket, timeout: 10)
} catch {
    FileHandle.standardError.write(Data("m2mhost: 连接中继失败 \(error)\n".utf8))
    exit(1)
}
let hostTransport = MuxTransport(connection: hostConnection)
hostTransport.start()

let hostEpoch: UInt64 = 1
let hostBus = MessageBus(epoch: hostEpoch)
hostBus.deliveryQueue = sessionQueue
hostBus.attach(hostTransport)
let hostSession = Session(epoch: hostEpoch)

ensureCaptureSources()

let hostFileBridge = FileBridge(remoteTempDirectory: receivedDir, chunkSize: 32 * 1024,
                                rateLimitBytesPerSecond: 512 * 1024)

let hostRuntime = HostRuntime(bus: hostBus, session: hostSession,
                              windowProvider: hostWindowProvider, inputSink: hostInputSink,
                              captureSources: captureSources,
                              encoder: ScreenRLEEncoder(),
                              textProvider: hostTextProvider,
                              commitExecutor: hostCommitExecutor,
                              fileBridge: hostFileBridge,
                              capabilityReport: hostCapability)
hostRuntime.targetFPS = hostOptions.targetFPS
hostRuntime.bitrate.targetBitsPerSecond = hostOptions.bitrateMbps * 1_000_000

// MARK: 状态上报

let hostStateURL = hostOptions.stateFile.map { URL(fileURLWithPath: $0) }

func jsonSafe(_ notice: Notice) -> [String: Any] {
    ["title": notice.title, "detail": notice.detail, "severity": notice.severity.rawValue,
     "scope": notice.scope.localizedDescription]
}

let hostPid = getpid()
func writeHostState() {
    guard let hostStateURL else { return }
    let snap = hostDemoProxy?.cachedSnapshotPublic
    var info: [String: Any] = [
        "role": "host",
        "pid": Int(hostPid),
        "epoch": hostSession.epoch,
        "phase": hostSession.phase.rawValue,
        "capture_mode": hostCapability.captureMode.rawValue,
        "input_mode": hostCapability.inputMode.rawValue,
        "text_mode": hostCapability.textMode.rawValue,
        "screen_recording": hostCapability.screenRecording.rawValue,
        "accessibility": hostCapability.accessibility.rawValue,
        "frames_sent": hostRuntime.framesSent,
        "frames_skipped_budget": hostRuntime.framesSkippedForBudget,
        "frames_skipped_no_change": hostRuntime.framesSkippedNoChange,
        "resize_applied": hostRuntime.resizeRequestsApplied,
        "resize_coalesced_dropped": hostRuntime.coalescedResizeDropped,
        "streams": Array(hostRuntime.streams.keys),
        "windows": hostWindowProvider.currentWindows().map {
            ["uid": $0.windowUID, "role": $0.role.localizedDescription, "title": $0.title,
             "w": $0.contentSize.width, "h": $0.contentSize.height,
             "minimized": $0.minimized]
        },
        "notices": hostRuntime.notices.map(jsonSafe),
        "received_files": hostFileBridge.completedNames,
        "text_buffer": snap?.text.buffer
            ?? hostDemoProxy?.cachedTextState?.buffer ?? "",
        "text_caret": snap?.text.caret ?? hostDemoProxy?.cachedTextState?.caret ?? 0,
    ]
    if let proxy = hostDemoProxy {
        info["demo_calls"] = proxy.callCount
        info["demo_failures"] = proxy.failures
    }
    if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: hostStateURL, options: .atomic)
    }
}

logHost("能力报告：采集=\(hostCapability.captureMode.localizedDescription) / 输入=\(hostCapability.inputMode.localizedDescription) / 文本=\(hostCapability.textMode.localizedDescription)")
logHost("屏幕录制=\(hostCapability.screenRecording.localizedDescription) 辅助功能=\(hostCapability.accessibility.localizedDescription)")
for n in hostCapability.userFacingNotices {
    logHost("提示[\(n.severity.localizedDescription)] \(n.title)：\(n.detail)")
}

// MARK: 主循环

var hostTicks = 0
let hostTimer = DispatchSource.makeTimerSource(queue: sessionQueue)
hostTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
hostTimer.setEventHandler {
    let now = Date().timeIntervalSinceReferenceDate
    hostTicks += 1
    // 刷新目标应用快照（本地 UDS 往返，微秒级；在会话队列上执行，不会与读取队列互相等待）
    hostDemoProxy?.refresh()
    ensureCaptureSources()
    hostRuntime.tick(now: now)
    if hostTicks % 20 == 0 { writeHostState() }
}
hostTimer.resume()

hostSession.onPhaseChange = { phase in logHost("会话状态：\(phase.localizedDescription)") }

func shutdownHost() {
    writeHostState()
    hostFileBridge.cleanupTempDirectory()
    hostConnection.close()
    exit(0)
}
signal(SIGTERM) { _ in shutdownHost() }
signal(SIGINT) { _ in shutdownHost() }

logHost("已接入中继，等待 Viewer")
writeHostState()
dispatchMain()
