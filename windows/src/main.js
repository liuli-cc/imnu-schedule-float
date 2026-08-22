const { app, BrowserWindow, ipcMain, Menu, Tray, nativeImage, powerMonitor, screen } = require('electron');
const fs = require('fs');
const path = require('path');

const PORTAL_URL = 'https://jwxt.imnu.edu.cn';
const REFRESH_INTERVAL = 45 * 60 * 1000;
const BALL_SIZE = 60;
const HANDLE_WIDTH = 12;
const HANDLE_HEIGHT = 48;
const PANEL_WIDTH = 410;
const PANEL_HEIGHT = 610;

let ballWindow;
let panelWindow;
let portalWindow;
let tray;
let refreshTimer;
let syncInProgress = false;
let networkOnline = true;
let dragOrigin = null;
let settings = {};
let state = {
  syncStatus: 'sample',
  message: '尚未同步真实课表',
  courses: [],
  profile: { name: '', studentNumber: '', gpa: '' },
  term: '',
  maxWeek: 19,
  currentWeek: null,
  updatedAt: null
};

const SNAPSHOT_SCRIPT = `
(async () => {
  const text = value => {
    if (value == null) return '';
    if (Array.isArray(value)) return value.map(text).filter(Boolean).join('、');
    if (typeof value === 'object') return text(value.xm || value.name || value.jsmc || value.tmc || '');
    const output = String(value).trim();
    return output === '-' ? '' : output;
  };
  const plain = value => {
    const raw = text(value);
    if (!raw.includes('<') && !raw.includes('&lt;')) return raw;
    const holder = document.createElement('div');
    holder.innerHTML = raw;
    return (holder.textContent || '').replace(/\\s+/g, ' ').trim();
  };
  const weekday = value => {
    const raw = text(value);
    const names = {'星期一':1,'星期二':2,'星期三':3,'星期四':4,'星期五':5,'星期六':6,'星期日':7,'周一':1,'周二':2,'周三':3,'周四':4,'周五':5,'周六':6,'周日':7};
    return names[raw] || Number.parseInt(raw, 10) || 0;
  };
  const pageResponse = await fetch('/admin/xsd/pkgl/xskb/queryKbForXsd', {credentials:'include'});
  if (!pageResponse.ok || /\\/login|caslogin/.test(pageResponse.url)) throw new Error('AUTH_REQUIRED');
  const pageHTML = await pageResponse.text();
  const page = new DOMParser().parseFromString(pageHTML, 'text/html');
  const field = id => page.querySelector('#' + id)?.getAttribute('value') || page.querySelector('#' + id)?.textContent?.trim() || '';
  const term = field('xnxq');
  const xhid = field('xhid');
  const campus = field('xqdm');
  if (!term) throw new Error('AUTH_REQUIRED');

  const form = new URLSearchParams({xnxq:term, xhid, xqdm:campus, zdzc:'', zxzc:'', xskbxslx:'0'});
  const [courseResponse, profileResponse, gpaResponse, weeksResponse, currentWeekResponse] = await Promise.all([
    fetch('/admin/xsd/pkgl/xskb/sdpkkbList', {method:'POST', credentials:'include', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'}, body:form}),
    fetch('/admin/xsd/xskp/xskp?xhid=' + encodeURIComponent(xhid), {credentials:'include'}),
    fetch('/admin/xsd/xsdzgcjcx/getXspjxfjd', {credentials:'include'}),
    fetch('/admin/getCurrentPkZc', {credentials:'include'}),
    fetch('/admin/api/getXlzc', {credentials:'include'})
  ]);
  if (!courseResponse.ok) throw new Error('COURSE_HTTP_' + courseResponse.status);
  const [courseJSON, profileJSON, gpaJSON, weeksJSON, currentWeekJSON] = await Promise.all([
    courseResponse.json(), profileResponse.json().catch(() => ({})), gpaResponse.json().catch(() => ({})),
    weeksResponse.json().catch(() => ({})), currentWeekResponse.json().catch(() => ({}))
  ]);
  if (courseJSON.ret !== 0) throw new Error(courseJSON.msg || 'COURSE_RESPONSE');
  const rawProfile = profileJSON?.data || {};
  const identityRow = Array.from(document.querySelectorAll('.header_left li')).find(node => /姓名\\s*\\/\\s*学号/.test(node.textContent || ''));
  const identity = text(identityRow?.querySelector('.value')?.textContent).split('/');
  const rawCourses = Array.isArray(courseJSON.data) ? courseJSON.data : [];
  const courses = rawCourses.map(item => {
    const building = plain(item.jxlmc);
    const room = plain(item.croommc || item.croombh);
    return {
      name: plain(item.kcmc),
      teacher: plain(item.tmc || item.jsmc || item.teacher || item.jsxq),
      location: [...new Set([building, room].filter(Boolean))].join(' · '),
      weekday: weekday(item.xingqi || item.xq),
      section: text(item.djc || item.djs || item.jc),
      weeks: text(item.zcstr || item.zc)
    };
  }).filter(item => item.name && item.weekday > 0);
  const allWeeks = Array.isArray(weeksJSON.data) ? weeksJSON.data.map(Number).filter(Number.isFinite) : [];
  const currentWeek = Number(currentWeekJSON?.data?.xlzc || currentWeekJSON?.data?.zc || 0) || null;
  return JSON.stringify({
    term,
    maxWeek: allWeeks.length ? Math.max(...allWeeks) : 19,
    currentWeek,
    profile: {
      studentNumber: text(rawProfile.xh) || text(identity[1]),
      name: text(rawProfile.xm) || text(identity[0]),
      gpa: text(gpaJSON?.data) || text(document.querySelector('#pjxfjd')?.textContent)
    },
    courses
  });
})().catch(error => JSON.stringify({__error:String(error?.message || error)}));`;

function dataPath(name) {
  return path.join(app.getPath('userData'), name);
}

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function writeJSON(file, value) {
  const temporary = file + '.tmp';
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function loadLocalState() {
  settings = readJSON(dataPath('settings.json'), {});
  const cached = readJSON(dataPath('schedule-cache.json'), null);
  if (!cached || !Array.isArray(cached.courses) || cached.courses.length === 0) return;
  state = {
    ...state,
    ...cached,
    syncStatus: 'ready',
    message: '已同步',
    profile: { name: '', studentNumber: '', gpa: '', ...(cached.profile || {}) }
  };
}

function saveSettings() {
  writeJSON(dataPath('settings.json'), settings);
}

function broadcastState() {
  for (const window of [ballWindow, panelWindow]) {
    if (window && !window.isDestroyed()) window.webContents.send('state:update', state);
  }
  if (tray) tray.setToolTip(`教务悬浮助手 · ${state.message}`);
}

function setStatus(syncStatus, message) {
  state.syncStatus = syncStatus;
  state.message = message;
  broadcastState();
}

function sectionRange(rawValue) {
  const raw = String(rawValue || '');
  const numbers = raw.split(/[^0-9]+/).filter(Boolean).map(Number);
  if (numbers.length >= 2) return [numbers[0], numbers[1]];
  if (numbers.length === 1) return [numbers[0], numbers[0]];
  return [1, 2];
}

function weekNumbers(rawValue) {
  const text = String(rawValue || '').replaceAll('，', ',');
  const odd = text.includes('单');
  const even = text.includes('双');
  const output = new Set();
  for (const part of text.split(',')) {
    const values = part.split(/[^0-9]+/).filter(Boolean).map(Number);
    if (values.length >= 2) {
      const lower = Math.min(values[0], values[1]);
      const upper = Math.max(values[0], values[1]);
      for (let week = lower; week <= upper; week += 1) {
        if ((!odd || week % 2 === 1) && (!even || week % 2 === 0)) output.add(week);
      }
    } else if (values.length === 1) output.add(values[0]);
  }
  return output.size ? [...output].sort((a, b) => a - b) : null;
}

function normalizeCourses(rows) {
  const parsed = rows.map((payload, index) => {
    const [startSection, endSection] = sectionRange(payload.section);
    return {
      id: `${payload.weekday}-${startSection}-${index}`,
      name: String(payload.name || '').trim(),
      teacher: String(payload.teacher || '').trim(),
      location: String(payload.location || '').trim(),
      weekday: Number(payload.weekday),
      startSection,
      endSection,
      weeks: String(payload.weeks || '').trim(),
      activeWeeks: weekNumbers(payload.weeks),
      colorIndex: index % 6
    };
  }).filter(course => course.name && course.weekday >= 1 && course.weekday <= 7);

  parsed.sort((a, b) => {
    const aKey = [a.name, a.teacher, a.location, a.weekday, a.weeks, String(a.startSection).padStart(3, '0')].join('|');
    const bKey = [b.name, b.teacher, b.location, b.weekday, b.weeks, String(b.startSection).padStart(3, '0')].join('|');
    return aKey.localeCompare(bKey, 'zh-CN');
  });

  const merged = [];
  for (const row of parsed) {
    const previous = merged.at(-1);
    const sameClass = previous && previous.name === row.name && previous.teacher === row.teacher &&
      previous.location === row.location && previous.weekday === row.weekday && previous.weeks === row.weeks;
    if (sameClass && row.startSection <= previous.endSection + 1) {
      previous.endSection = Math.max(previous.endSection, row.endSection);
    } else {
      row.colorIndex = merged.length % 6;
      row.id = `course-${merged.length}-${row.weekday}-${row.startSection}`;
      merged.push(row);
    }
  }
  return merged;
}

function isPortalHome(urlString) {
  try {
    const url = new URL(urlString);
    return url.hostname === 'jwxt.imnu.edu.cn' && (url.pathname === '/admin' || url.pathname.startsWith('/admin/'));
  } catch { return false; }
}

function isAuthenticationPage(urlString) {
  try {
    const url = new URL(urlString);
    return url.hostname === 'auth.imnu.edu.cn' || /\/(login|caslogin)/i.test(url.pathname);
  } catch { return false; }
}

function isNetworkError(error) {
  const message = String(error?.message || error || '').toLowerCase();
  return [
    'err_internet_disconnected', 'err_network_changed', 'err_name_not_resolved',
    'err_connection', 'err_timed_out', 'failed to fetch', 'network error',
    'networkerror', 'offline', 'internet connection', 'could not connect'
  ].some(fragment => message.includes(fragment));
}

function markOffline() {
  setStatus('offline', '网络不可用，正在使用已缓存的课表');
}

function reloadPortalAfterNetworkRecovery() {
  const window = ensurePortalWindow(false);
  if (!window.webContents.isLoading()) {
    window.loadURL(PORTAL_URL).catch(error => {
      if (isNetworkError(error)) markOffline();
      else setStatus('failed', `连接教务系统失败：${error.message}`);
    });
  }
}

async function syncSchedule({ showLogin = false } = {}) {
  if (syncInProgress) return;
  if (!networkOnline) {
    markOffline();
    return;
  }
  ensurePortalWindow(showLogin);
  const currentURL = portalWindow.webContents.getURL();
  if (!isPortalHome(currentURL)) {
    if (isAuthenticationPage(currentURL)) {
      setStatus('needsAuthorization', '登录已失效，请重新授权');
      portalWindow.show();
      portalWindow.focus();
    } else {
      setStatus('syncing', '正在连接教务系统');
      if (!portalWindow.webContents.isLoading()) {
        portalWindow.loadURL(PORTAL_URL).catch(error => {
          if (isNetworkError(error)) markOffline();
          else setStatus('failed', `连接教务系统失败：${error.message}`);
        });
      }
    }
    return;
  }

  syncInProgress = true;
  setStatus('syncing', '正在读取本学期课表');
  try {
    const result = await portalWindow.webContents.executeJavaScript(SNAPSHOT_SCRIPT, true);
    const snapshot = JSON.parse(result);
    if (snapshot.__error) {
      if (snapshot.__error.includes('AUTH_REQUIRED')) throw new Error('AUTH_REQUIRED');
      throw new Error(snapshot.__error);
    }
    const courses = normalizeCourses(snapshot.courses || []);
    if (!courses.length) throw new Error('没有识别到课程数据');
    state = {
      syncStatus: 'ready',
      message: '已同步',
      courses,
      profile: { name: '', studentNumber: '', gpa: '', ...(snapshot.profile || {}) },
      term: snapshot.term || '',
      maxWeek: Math.max(Number(snapshot.maxWeek) || 19, 1),
      currentWeek: Number(snapshot.currentWeek) || null,
      updatedAt: new Date().toISOString()
    };
    writeJSON(dataPath('schedule-cache.json'), state);
    broadcastState();
    if (portalWindow.isVisible()) portalWindow.hide();
  } catch (error) {
    if (String(error.message).includes('AUTH_REQUIRED')) {
      setStatus('needsAuthorization', '登录已失效，请重新授权');
      portalWindow.show();
    } else if (isNetworkError(error)) {
      networkOnline = false;
      markOffline();
    } else {
      setStatus('failed', `读取失败：${error.message}`);
    }
  } finally {
    syncInProgress = false;
  }
}

function createLocalWindow(options, mode) {
  const window = new BrowserWindow({
    ...options,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  window.loadFile(path.join(__dirname, 'index.html'), { query: { mode } });
  window.setMenuBarVisibility(false);
  return window;
}

function createBallWindow() {
  const display = screen.getPrimaryDisplay().workArea;
  const initialX = Number.isFinite(settings.ballX) ? settings.ballX : display.x + display.width - BALL_SIZE - 22;
  const initialY = Number.isFinite(settings.ballY) ? settings.ballY : display.y + Math.round((display.height - BALL_SIZE) / 2);
  ballWindow = createLocalWindow({
    width: BALL_SIZE,
    height: BALL_SIZE,
    x: initialX,
    y: initialY,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    hasShadow: false,
    backgroundColor: '#00000000'
  }, 'ball');
  ballWindow.setAlwaysOnTop(true, 'floating');
  ballWindow.setVisibleOnAllWorkspaces(true);
  ballWindow.once('ready-to-show', () => {
    if (settings.edge === 'left' || settings.edge === 'right') hideBallAtEdge(settings.edge);
    else ballWindow.showInactive();
  });
  ballWindow.on('close', event => {
    if (!app.isQuitting) { event.preventDefault(); ballWindow.hide(); }
  });
}

function createPanelWindow() {
  panelWindow = createLocalWindow({
    width: PANEL_WIDTH,
    height: PANEL_HEIGHT,
    frame: false,
    transparent: true,
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    hasShadow: true,
    backgroundColor: '#00000000'
  }, 'panel');
  panelWindow.setAlwaysOnTop(true, 'floating');
  panelWindow.setVisibleOnAllWorkspaces(true);
  panelWindow.on('blur', () => panelWindow.hide());
  panelWindow.on('close', event => {
    if (!app.isQuitting) { event.preventDefault(); panelWindow.hide(); }
  });
}

function ensurePortalWindow(show = false) {
  if (portalWindow && !portalWindow.isDestroyed()) {
    if (show) { portalWindow.show(); portalWindow.focus(); }
    return portalWindow;
  }
  portalWindow = new BrowserWindow({
    width: 980,
    height: 720,
    minWidth: 760,
    minHeight: 560,
    title: '教务悬浮助手 · 首次授权',
    show,
    autoHideMenuBar: true,
    webPreferences: {
      partition: 'persist:imnu-portal',
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  portalWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  portalWindow.webContents.on('did-finish-load', () => {
    const currentURL = portalWindow.webContents.getURL();
    networkOnline = true;
    if (isPortalHome(currentURL)) syncSchedule();
    else if (isAuthenticationPage(currentURL)) {
      setStatus('needsAuthorization', '登录已失效，请重新授权');
      portalWindow.show();
    } else if (state.courses.length === 0) portalWindow.show();
  });
  portalWindow.webContents.on('did-fail-load', (_event, errorCode, errorDescription, _validatedURL, isMainFrame) => {
    if (!isMainFrame || errorCode === -3) return;
    if (isNetworkError(errorDescription)) {
      networkOnline = false;
      markOffline();
    } else {
      setStatus('failed', `连接教务系统失败：${errorDescription}`);
    }
  });
  portalWindow.on('close', event => {
    if (!app.isQuitting) { event.preventDefault(); portalWindow.hide(); }
  });
  portalWindow.loadURL(PORTAL_URL);
  return portalWindow;
}

function showPanel() {
  if (!panelWindow || !ballWindow) return;
  const ball = ballWindow.getBounds();
  const display = screen.getDisplayMatching(ball).workArea;
  let x = ball.x - PANEL_WIDTH + ball.width;
  if (x < display.x + 8) x = ball.x + ball.width + 8;
  let y = Math.round(ball.y + ball.height / 2 - PANEL_HEIGHT / 2);
  y = Math.max(display.y + 8, Math.min(y, display.y + display.height - PANEL_HEIGHT - 8));
  panelWindow.setPosition(Math.round(x), Math.round(y), false);
  panelWindow.show();
  panelWindow.focus();
  broadcastState();
}

function togglePanel() {
  if (settings.edge) { revealBall(); return; }
  panelWindow.isVisible() ? panelWindow.hide() : showPanel();
}

function hideBallAtEdge(side) {
  if (!ballWindow) return;
  const current = ballWindow.getBounds();
  const work = screen.getDisplayMatching(current).workArea;
  const y = Math.max(work.y + 8, Math.min(current.y + Math.round((BALL_SIZE - HANDLE_HEIGHT) / 2), work.y + work.height - HANDLE_HEIGHT - 8));
  const x = side === 'left' ? work.x : work.x + work.width - HANDLE_WIDTH;
  settings.edge = side;
  settings.ballX = current.x;
  settings.ballY = current.y;
  saveSettings();
  panelWindow?.hide();
  ballWindow.setBounds({ x, y, width: HANDLE_WIDTH, height: HANDLE_HEIGHT }, false);
  ballWindow.webContents.send('ball:mode', 'handle');
  ballWindow.showInactive();
}

function revealBall() {
  if (!settings.edge || !ballWindow) return;
  const side = settings.edge;
  const handle = ballWindow.getBounds();
  const work = screen.getDisplayMatching(handle).workArea;
  const x = side === 'left' ? work.x + 8 : work.x + work.width - BALL_SIZE - 8;
  const y = Math.max(work.y + 8, Math.min(handle.y - Math.round((BALL_SIZE - HANDLE_HEIGHT) / 2), work.y + work.height - BALL_SIZE - 8));
  settings.edge = null;
  settings.ballX = x;
  settings.ballY = y;
  saveSettings();
  ballWindow.setBounds({ x, y, width: BALL_SIZE, height: BALL_SIZE }, false);
  ballWindow.webContents.send('ball:mode', 'ball');
  ballWindow.showInactive();
}

function finishBallDrag() {
  if (!ballWindow) return;
  dragOrigin = null;
  const bounds = ballWindow.getBounds();
  const work = screen.getDisplayMatching(bounds).workArea;
  const x = Math.max(work.x + 6, Math.min(bounds.x, work.x + work.width - BALL_SIZE - 6));
  const y = Math.max(work.y + 6, Math.min(bounds.y, work.y + work.height - BALL_SIZE - 6));
  ballWindow.setPosition(x, y, false);
  settings.ballX = x;
  settings.ballY = y;
  if (x - work.x < 30) hideBallAtEdge('left');
  else if (work.x + work.width - (x + BALL_SIZE) < 30) hideBallAtEdge('right');
  else { settings.edge = null; saveSettings(); }
}

function createTray() {
  const image = nativeImage.createFromPath(path.join(__dirname, '..', 'assets', 'icon.png')).resize({ width: 20, height: 20 });
  tray = new Tray(image);
  tray.setToolTip('教务悬浮助手');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: '显示 / 收起课表', click: togglePanel },
    { label: '立即同步', click: () => syncSchedule({ showLogin: true }) },
    { label: '首次授权或重新登录', click: () => ensurePortalWindow(true) },
    { type: 'separator' },
    { label: '退出教务悬浮助手', click: () => { app.isQuitting = true; app.quit(); } }
  ]));
  tray.on('double-click', togglePanel);
}

function registerIPC() {
  ipcMain.handle('state:get', () => state);
  ipcMain.on('ball:activate', togglePanel);
  ipcMain.on('ball:reveal', revealBall);
  ipcMain.on('ball:drag-start', (_event, point) => {
    if (settings.edge || !ballWindow) return;
    dragOrigin = { pointerX: point.x, pointerY: point.y, bounds: ballWindow.getBounds() };
  });
  ipcMain.on('ball:drag-move', (_event, point) => {
    if (!dragOrigin || !ballWindow) return;
    const x = Math.round(dragOrigin.bounds.x + point.x - dragOrigin.pointerX);
    const y = Math.round(dragOrigin.bounds.y + point.y - dragOrigin.pointerY);
    ballWindow.setPosition(x, y, false);
    if (panelWindow?.isVisible()) showPanel();
  });
  ipcMain.on('ball:drag-end', finishBallDrag);
  ipcMain.on('panel:hide', () => panelWindow?.hide());
  ipcMain.on('action:authorize', () => ensurePortalWindow(true));
  ipcMain.on('action:sync', () => syncSchedule({ showLogin: true }));
  ipcMain.on('network:changed', (_event, online) => {
    networkOnline = Boolean(online);
    if (!networkOnline) {
      markOffline();
    } else if (state.syncStatus === 'offline') {
      reloadPortalAfterNetworkRecovery();
    }
  });
  ipcMain.handle('action:clear', async () => {
    try { fs.unlinkSync(dataPath('schedule-cache.json')); } catch {}
    if (portalWindow && !portalWindow.isDestroyed()) {
      await portalWindow.webContents.session.clearStorageData();
      await portalWindow.webContents.session.clearCache();
    }
    state = {
      syncStatus: 'sample', message: '尚未同步真实课表', courses: [],
      profile: { name: '', studentNumber: '', gpa: '' }, term: '', maxWeek: 19,
      currentWeek: null, updatedAt: null
    };
    broadcastState();
    ensurePortalWindow(true).loadURL(PORTAL_URL);
    return true;
  });
  ipcMain.on('action:quit', () => { app.isQuitting = true; app.quit(); });
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) app.quit();
else {
  app.on('second-instance', () => {
    revealBall();
    showPanel();
  });

  app.whenReady().then(() => {
    loadLocalState();
    registerIPC();
    createBallWindow();
    createPanelWindow();
    createTray();
    ensurePortalWindow(state.courses.length === 0);
    refreshTimer = setInterval(() => syncSchedule(), REFRESH_INTERVAL);
    powerMonitor.on('resume', () => syncSchedule());
  });
}

app.on('window-all-closed', () => {});
app.on('before-quit', () => {
  app.isQuitting = true;
  if (refreshTimer) clearInterval(refreshTimer);
});
