# 03 协议：四条逻辑通道

本协议是**自研**的，不是 RDP 兼容协议。设计目标是借鉴微软 MS-RDPERP / MS-RDPEGFX / MS-RDPETXT 的**分层**，而不是复制其字节格式。

## 0. 通用约定

| 项 | 约定 |
|---|---|
| 传输 | 一次加密会话；通道是逻辑通道，由独立队列与优先级区分（实现可为 WebRTC DataChannel + 媒体轨，或自定义多路复用）。**分通道不等于自动解决共同链路拥塞**，仍需应用层限速（T7） |
| 编码 | 控制/状态消息用紧凑二进制或 CBOR；调试模式可切 JSON |
| 版本 | `protocol_version` 在协商阶段交换；不匹配则拒绝连接并给出可读原因 |
| 幂等 | 每条修改类消息带 `msg_id`（单调递增）与 `epoch`；接收方对重复 `msg_id` 直接丢弃 |
| 序号 | `seq`（可靠有序通道内递增）用于检测丢失与乱序；`epoch`（会话代次）用于检测过期消息 |
| 时钟 | 不依赖两端时钟同步；延迟测量用请求-响应往返，不用绝对时间戳做业务判断 |

### 优先级与调度

| 优先级 | 内容 | 行为 |
|---|---|---|
| P0（最高） | 撤销控制、会话状态变更、修饰键释放 | 独立小消息，不排队 |
| P1 | 输入事件、文本提交 | 可靠有序，不丢弃 |
| P2 | 窗口状态、几何、文本上下文 | 可靠；**同类消息可合并**（只保留最新） |
| P3 | 媒体画面 | 可丢弃过期帧 |
| P4（最低） | 文件分块 | 限速，剩余带宽使用 |

## 1. 通道 A：窗口状态（Window Channel）

职责：回答"这个窗口是谁、在哪里、是否激活、尺寸多少、和谁有父子/模态关系"。

### 1.1 消息

```text
// 远端 → 本地：窗口注册表快照（连接/重连/漂移后发送）
WindowSnapshot {
  epoch: uint64
  layout_version: uint64
  windows: [
    {
      window_uid: string        // 远端稳定身份（会话内唯一，非永久）
      app_pid: int32
      app_launch_id: string     // 应用重启后变化
      bundle_id: string
      title: string
      role: enum { main, panel, dialog, popup_menu, child, unknown }
      parent_uid: string?       // 父子关系
      modal: bool
      content_rect: Rect        // 远端逻辑点
      content_size_px: Size     // 用于采集与编码像素量计算
      resizable: enum { none, width, height, both }
      min_size: Size?; max_size: Size?
      minimized: bool
      focusable: bool
      z_order: int              // 仅用于判断遮挡，不用于本地摆放
    }
  ]
}

// 远端 → 本地：增量更新
WindowDelta {
  epoch, layout_version            // 每产生布局变化即 +1
  added: [WindowInfo]
  removed: [window_uid]
  changed: [WindowPatch]           // 只含变化的字段
}

// 本地 → 远端：请求修改远端窗口尺寸
WindowResizeRequest {
  msg_id, epoch, window_uid
  requested_content_size: Size     // 远端逻辑点
  request_seq: uint32              // 同一窗口的合并序号，只处理最新
}

// 远端 → 本地：实际生效的尺寸（事实，不是承诺）
WindowResizeResult {
  request_seq
  actual_content_size: Size
  layout_version                   // 必须与随后的画面帧一致
  constrained_by: enum { none, app_min, app_max, screen, system }
}

// 本地 → 远端：窗口行为请求
WindowAction {
  msg_id, epoch, window_uid
  action: enum { activate, minimize, unminimize, close, request_fullscreen }
}
```

### 1.2 硬性规则

1. **本地移动窗口不驱动远端移动。** 远端窗口只需待在适合采集的位置。本地拖动只改本地 `NSWindow` 的 frame。
2. **本地缩放发出的是请求，远端读回的是事实。** `WindowResizeResult.actual_content_size` 才是权威值；本地必须接受约束，不得双方互相纠正导致抖动。
3. **同一窗口的 resize 请求合并到约 10 Hz**，拖动中只发最新值（`request_seq` 覆盖）。
4. **画面帧与几何信息必须携带同一 `layout_version`。** 客户端不得用旧坐标裁剪新画面（会显示错区域、点错位置）。
5. `window_uid` 不得作为永久标识持久化；应用重启后必须换新。

### 1.3 本地窗口 ↔ 远端窗口的映射表

| 远端 role | 本地表现 |
|---|---|
| `main` | `NSWindow`，可与本地 App 混排 |
| `dialog` / `panel` | `NSPanel` 或 `NSWindow`，保留父子与模态 |
| `popup_menu` / 右键菜单 | 附属视图或贴近主窗口的轻量面板，**不得被其他本地窗口错误遮挡** |
| `child` | 随主窗口画面显示（若采集已包含），不单独建壳 |
| `unknown` | 建壳并标注"未识别窗口类型"，**不得自动退化为共享整个远端桌面** |

## 2. 通道 B：媒体画面（Media Channel）

一块窗口一个媒体流（T5）。消息面只保留元数据与关键帧请求；画面本体走 WebRTC 媒体轨。

```text
// 远端 → 本地：流注册与描述（与 WindowSnapshot 配合）
StreamInfo {
  stream_id: string
  window_uid: string
  layout_version: uint64
  content_size_px: Size        // 采集像素尺寸
  content_scale: float         // 点 → 像素
  color_space: enum { sRGB, displayP3 }
  encoder: { codec: enum { h264, hevc }, profile: string, level: string }
  target_fps: uint8
  is_static: bool              // 静态内容降频标记
}

// 本地 → 远端：关键帧请求（重连、花屏、切流后立即发）
KeyframeRequest { stream_id, reason: enum { connect, decode_error, resume, manual } }

// 本地 → 远端：流参数调整请求（弱网分级）
StreamAdjustRequest {
  stream_id
  fps_max: uint8?
  scale: enum { full, half, quarter }?   // 分辨率降级，文字场景慎用
  quality_bias: enum { text, motion }?
}

// 远端 → 本地：流状态
StreamState { stream_id, state: enum { live, paused_app_hidden, window_minimized, closed } }
```

**规则**：窗口最小化时远端停止编码并发 `paused`（不是持续发送同一帧）；恢复时先发关键帧。

## 3. 通道 C：文本与输入（Text & Input Channel）— 一期核心

这是本项目与"普通远程桌面"的**主要差别**。详细状态机见 `04-text-input.md`，此处定义消息。

### 3.1 编辑上下文（远端 → 本地）

```text
TextContext {
  epoch
  edit_version: uint64          // 每次远端编辑状态变化 +1
  target: {
    window_uid: string
    node_id: string             // 远端控件身份（AX 元素/AXPath，稳定可复取）
    role: enum { text_field, text_area, contenteditable, unknown }
    editable: bool
    accepts_unicode_events: bool // 实测结论，非猜测
  }
  caret: {
    valid: bool
    rect_in_window: Rect        // 远端窗口逻辑坐标下的插入点矩形
    line_height: float
  }
  selection: {
    valid: bool
    range: { location: int, length: int } | null
  }
  marked: {                     // 远端是否已有组合文本（一般应为空；用于异常检测）
    present: bool
    length: int
  }
  context_excerpt: {            // 受限长度，用于降级插入与断言，非全文同步
    before: string   // ≤ 64 字符
    after: string    // ≤ 64 字符
    truncated: bool
  }
}

// 远端 → 本地：编辑状态失效（焦点转移、窗口关闭、控件重建）
TextContextInvalidated { epoch, reason: enum { focus_moved, window_closed, node_gone, app_restarted } }
```

**`edit_version` 的意义**：本地每次提交都携带它读取时的版本。远端不匹配则拒绝执行并返回 `stale_context`，本地重新读取上下文后由**用户**决定是否重发（不自动重发）。

### 3.2 提交（本地 → 远端）

```text
TextCommit {
  msg_id, epoch
  window_uid, node_id
  edit_version                 // 本地发起时的上下文版本
  commit_seq: uint32           // 本地单调递增，用于去重
  text: string                 // UTF-8，已确认文字（不含组合中的拼音）
  composition_span: {          // 若该次提交是替换某段组合文本
    from_local_marked: bool
    replace_range: { location: int, length: int }?
  }
  intent: enum { insert_text, replace_selection, delete_backward, delete_forward, newline }
}

// 远端 → 本地
TextCommitResult {
  msg_id
  status: enum {
    applied            // 已执行，附 new_edit_version
    applied_partial    // 部分执行（如仅插入未处理换行）
    rejected_stale     // edit_version 不匹配
    rejected_unsupported // 该控件不接受此提交方式
    rejected_no_focus  // 目标控件未聚焦
    unknown            // 超时/连接中断，**执行结果不明**
  }
  new_edit_version: uint64?
  applied_range: { location: int, length: int }?
  detail: string?
}
```

**`unknown` 是最重要的状态**：网络超时/断线导致的"执行结果不明"，Viewer 必须：

- **不自动重试**；
- 在界面上以非阻塞方式提示"上一条输入结果未确认"；
- 让下一次 `TextContext` 拉取来揭示实际状态（例如文字是否已经出现）；
- 界面**不得**先乐观地把文字显示为"已发送"。

### 3.3 键鼠输入（本地 → 远端）

```text
KeyEvent {
  msg_id, epoch
  window_uid                     // 目标窗口，必填
  kind: enum { key_down, key_up, flags_changed }
  keycode: uint16                // 物理键码（用于快捷键）
  flags: uint32                  // modifiers
  unicode: string?               // 仅当本地已确认文字时使用；见 04
  category: enum { shortcut, navigation, editing, raw_key }
}

PointerEvent {
  msg_id, epoch, window_uid
  kind: enum { move, down, up, drag, scroll }
  position_in_window: Point      // 远端窗口逻辑坐标
  button: enum { left, right, middle, none }
  scroll: { dx: float, dy: float, precise: bool }?
}

// 鼠标移动可合并（只发最新位置）；按键不得合并
PointerMoveCoalesced { epoch, window_uid, latest_position, sample_count }
```

**规则**：

- **物理按键与文本提交是两条路径**，不得把同一段文字既作为 `TextCommit` 又作为按键发送（会重复输入）。
- `KeyEvent` 中若带 `unicode`，仅用于**已被本地输入法确认**的字符；拼音按键绝不走此路径。
- 修饰键状态由 Host 侧跟踪；连接丢失时 Host 主动释放所有按下的修饰键。

### 3.4 输入模式协商

| 模式 | 用于 | 说明 |
|---|---|---|
| `local-ime` | 认证应用 | 本地组合、本地候选窗、`TextCommit` 提交 |
| `remote-ime` | 未认证应用（降级） | 原样转发按键，使用**远端**输入法；界面必须标识 |
| `direct-text` | 无 AX 但控件接受 Unicode 事件的场景 | 直接发 `KeyEvent(unicode:)`，无组合支持；界面标识为降级 |

## 4. 通道 D：文件与剪贴板（File & Clipboard Channel）

```text
ClipboardUpdate {
  kind: enum { text, image, cleared }
  payload_ref: string?          // 大对象走 blob 通道，不内联
  hash: string                  // 用于防止 A→B→A 回环
  origin: enum { viewer, host }
}

FileOffer {
  transfer_id, name, size, mime, sha256
  dest_hint: enum { temp_dir }  // 一期只落远端临时目录
}

FileChunk { transfer_id, index, bytes }          // 限速，P4 优先级
FileComplete { transfer_id, remote_path }        // 远端明文路径回传，供用户选择
FileAbort { transfer_id, reason }
FileProgress { transfer_id, received, total }    // 双向进度
```

**规则**：

- 文件不得内联进控制通道；`FileChunk` 必须限速（例如不超过可用带宽的 30%）且可被暂停。
- 上传完成后，**由用户在远端应用的文件选择流程中选择该文件**；一期不做透明的文件选择器重定向（P4）。
- 剪贴板必须防回环：收到 `origin=host` 的内容不再回传。
- 临时文件需有清理策略（会话结束 / 定时 / 大小上限）。

## 5. 会话与错误

```text
Hello { protocol_version, device_id, capabilities, nonce }
HelloAck { protocol_version, accepted_capabilities, session_id, epoch }

SessionStateMsg { state: enum { active, degraded, reconnecting, suspended, revoked } , detail: string? }
RevokeControl { reason: enum { user_local, user_remote, policy } }   // P0 优先级，必须立即生效

ErrorReport {
  scope: enum { media, text, window, file, auth, permission }
  code: string
  message: string              // 用户可读
  retryable: bool
}
```

**必须区分的错误呈现**（不得合并成"连接失败"）：

| 错误 | 用户可见信息 |
|---|---|
| 屏幕录制权限缺失 | "远端缺少屏幕录制权限"，并给出授权路径 |
| 辅助功能权限缺失 | "中文输入将降级"，说明受影响的功能 |
| 文本控件不支持 | "该窗口不支持本地输入法"，并标注降级 |
| 媒体中断 | "画面中断，远端应用仍在运行" |
| 文本提交结果不明 | "上一条输入结果未确认" |

## 6. 与微软规范的对照（设计参考，非兼容目标）

| 本协议 | 微软对应 | 借鉴点 | 不借鉴 |
|---|---|---|---|
| 通道 A 窗口 | MS-RDPERP / RAIL | 客户端收到窗口事件即建本地窗口；远端 WindowId ↔ 本地窗口关联；Enhanced RemoteApp 只传窗口内容不传桌面背景 | 不做字节级兼容，不实现 RDP 协商 |
| 通道 B 媒体 | MS-RDPEGFX | 表面管理、缓存、图形更新与业务控件树无关 | 不实现 GDI/EGFX 指令集 |
| 通道 C 文本 | MS-RDPETXT | **最有价值**：本地输入法连接到远端编辑控件，含组合文本、文本变化、几何变化、文本范围 | Windows 服务端已有的文本系统能力在 macOS 必须自研 |
| 通道 D 文件 | RDP 剪贴板/驱动器重定向 | 通道独立性 | 一期不做驱动器重定向 |

## 7. 协议的一期冻结范围

| 状态 | 内容 |
|---|---|
| **冻结** | §1 窗口、§3.1–3.2 文本提交、§5 会话与错误 |
| **可调整** | §2 媒体参数（依 G3 实测）、§3.4 输入模式细节（依 G1）、§4 文件限速参数 |
| **预留不实现** | 多控制者、音频通道、驱动器重定向、动态插件协议 |
