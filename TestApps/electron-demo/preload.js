// 渲染进程与主进程之间的最小通信（本 demo 不使用 contextIsolation 的高级用法）
const { ipcRenderer } = require('electron')
window.__m2m = {
  report: (patch) => ipcRenderer.send('state-update', patch),
  onSetInput: (fn) => ipcRenderer.on('set-input', (_e, text) => fn(text)),
  onFocusInput: (fn) => ipcRenderer.on('focus-input', () => fn()),
}
