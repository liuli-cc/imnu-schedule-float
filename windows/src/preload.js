const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('assistantAPI', {
  getState: () => ipcRenderer.invoke('state:get'),
  onState: (callback) => ipcRenderer.on('state:update', (_event, value) => callback(value)),
  onBallMode: (callback) => ipcRenderer.on('ball:mode', (_event, value) => callback(value)),
  dragStart: (x, y) => ipcRenderer.send('ball:drag-start', { x, y }),
  dragMove: (x, y) => ipcRenderer.send('ball:drag-move', { x, y }),
  dragEnd: () => ipcRenderer.send('ball:drag-end'),
  activateBall: () => ipcRenderer.send('ball:activate'),
  revealBall: () => ipcRenderer.send('ball:reveal'),
  hidePanel: () => ipcRenderer.send('panel:hide'),
  authorize: () => ipcRenderer.send('action:authorize'),
  sync: () => ipcRenderer.send('action:sync'),
  clear: () => ipcRenderer.invoke('action:clear'),
  quit: () => ipcRenderer.send('action:quit')
});

function reportNetworkState() {
  ipcRenderer.send('network:changed', navigator.onLine);
}

window.addEventListener('online', reportNetworkState);
window.addEventListener('offline', reportNetworkState);
window.addEventListener('DOMContentLoaded', reportNetworkState);
