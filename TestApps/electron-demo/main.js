// 被代理的 Electron 目标应用
//
// 它刻意包含 Electron 系应用的典型结构，用于验证：
//   · Chromium 的辅助功能树对 contenteditable / textarea 的覆盖程度
//   · 插入点（光标）矩形能否被读取 —— 这是本地输入法候选窗能否跟随的前提
//   · 虚拟滚动列表下的窗口与编辑状态
//   · 独立窗口（设置）与模态对话框
//
// 同时提供与 m2mdemo 相同的"状态文件 + 控制文件"接口，
// 使 m2mctl 可以在不依赖应用配合的前提下做跨进程断言。

const { app, BrowserWindow, ipcMain, dialog } = require('electron')
const fs = require('fs')
const path = require('path')

// 允许第三方辅助功能客户端接管（Electron 的已知机制）。
// 不设置时 Chromium 可能不暴露辅助功能树，导致读不到任何控件。
app.commandLine.appendSwitch('force-renderer-accessibility')

const args = process.argv.slice(2)
function argValue(name) {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : null
}

const stateFile = argValue('--state-file')
const controlFile = argValue('--control-file')
let mainWindow = null
let settingsWindow = null
let dialogWindow = null

// 应用状态（模型）
const state = {
  inputText: '',
  caret: 0,
  messages: Array.from({ length: 500 }, (_, i) => `历史消息 #${i + 1}：用于验证虚拟滚动下的远程操作`),
  settingsOpen: false,
  lastCommand: null,
}

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 720,
    height: 560,
    minWidth: 420,
    minHeight: 320,
    title: 'M2M Electron Demo',
    show: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: false,
      nodeIntegration: false,
    },
  })
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'))
  mainWindow.on('closed', () => { mainWindow = null })
}

function createSettingsWindow() {
  if (settingsWindow) { settingsWindow.focus(); return }
  settingsWindow = new BrowserWindow({
    width: 380, height: 260, title: '设置', parent: mainWindow, modal: false,
  })
  settingsWindow.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
    '<html><body style="font-family:-apple-system;padding:16px">' +
    '<h3>设置</h3><div>这是一个独立的 Electron 子窗口。</div>' +
    '<div style="margin-top:8px">用于验证多窗口与父子关系。</div></body></html>'))
  settingsWindow.on('closed', () => { settingsWindow = null })
}

function createModalDialog() {
  if (dialogWindow) { dialogWindow.focus(); return }
  dialogWindow = new BrowserWindow({
    width: 360, height: 180, title: '确认', parent: mainWindow, modal: true, resizable: false,
  })
  dialogWindow.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
    '<html><body style="font-family:-apple-system;padding:16px;text-align:center">' +
    '<h3>确认操作</h3><div>模态对话框</div></body></html>'))
  dialogWindow.on('closed', () => { dialogWindow = null })
}

// 状态文件：供跨进程断言读取
function writeState() {
  if (!stateFile) return
  const payload = {
    bundleID: 'dev.m2m.electrondemo',
    displayName: 'M2M Electron Demo',
    pid: process.pid,
    launchID: `electron-${process.pid}`,
    contentScale: 2,
    windows: BrowserWindow.getAllWindows().map((w, i) => {
      const b = w.getContentBounds()
      return {
        uid: `electron:${w.id}`, title: w.getTitle(), role: 'main',
        width: b.width, height: b.height,
        minWidth: 420, minHeight: 320,
        resizable: w.isResizable(), minimized: w.isMinimized(),
        modal: w.isModal(), parentUID: null, focusable: true, zOrder: i,
      }
    }),
    text: {
      buffer: state.inputText,
      caret: state.caret,
      selection: 0,
      focusedWindowUID: mainWindow ? `electron:${mainWindow.id}` : null,
      caretRectValid: true,
      caretX: 0, caretY: 0,
      acceptsInput: true,
    },
    electron: {
      messages: state.messages.length,
      settingsOpen: settingsWindow != null,
      lastCommand: state.lastCommand,
    },
  }
  try { fs.writeFileSync(stateFile, JSON.stringify(payload, null, 2)) } catch (_) {}
}

// 控制文件：外部驱动（打开窗口、设置文本等）
let lastControlMtime = 0
function pollControl() {
  if (!controlFile) return
  try {
    const st = fs.statSync(controlFile)
    if (st.mtimeMs > lastControlMtime) {
      lastControlMtime = st.mtimeMs
      const batch = JSON.parse(fs.readFileSync(controlFile, 'utf8'))
      for (const req of batch.requests || []) {
        state.lastCommand = req.kind
        if (req.kind === 'openSettings') createSettingsWindow()
        if (req.kind === 'openModal') createModalDialog()
        if (req.kind === 'close' && settingsWindow) { settingsWindow.close() }
        if (req.kind === 'setContent' && mainWindow) {
          state.inputText = req.text || ''
          mainWindow.webContents.send('set-input', state.inputText)
        }
        if (req.kind === 'focusInput' && mainWindow) {
          // 自我激活：Chromium 只在应用处于前台时才通过 AXFocusedUIElement
          // 报告焦点控件，而后台进程无法强制激活别的应用。
          // 专用远端机上应用本就应是前台应用，这里显式还原该前提。
          app.focus({ steal: true })
          mainWindow.show()
          mainWindow.focus()
          mainWindow.webContents.focus()
          mainWindow.webContents.send('focus-input')
        }
        if (req.kind === 'activateSelfForFocus' || req.kind === 'activateSelf') {
          app.focus({ steal: true })
          if (mainWindow) { mainWindow.show(); mainWindow.focus(); mainWindow.webContents.focus() }
        }
      }
    }
  } catch (_) {}
}

ipcMain.on('state-update', (_e, patch) => {
  Object.assign(state, patch)
})

app.whenReady().then(() => {
  createMainWindow()
  writeState()
  setInterval(() => { writeState(); pollControl() }, 120)
})

app.on('window-all-closed', () => { app.quit() })
