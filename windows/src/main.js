const { app, BrowserWindow, ipcMain, Menu, Tray, nativeImage, powerMonitor, screen } = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');

const smokeTest = process.argv.includes('--smoke-test');
const smokeOutput = process.env.IMNU_SMOKE_OUTPUT || path.join(os.tmpdir(), 'imnu-smoke-' + process.pid);
if (smokeTest) {
  fs.mkdirSync(smokeOutput, { recursive: true });
  app.setPath('userData', path.join(smokeOutput, 'isolated-user-data'));
}

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
let clockTimer;
let cacheGeneration = 0;
let syncInProgress = false;
let networkOnline = true;
let dragOrigin = null;
let settings = {};
let state = {
  syncStatus: 'sample',
  message: '尚未同步真实课表',
  courses: [],
  profile: { name: '', studentNumber: '', gpa: '' },
  grades: [],
  gradesUpdatedAt: null,
  term: '',
  maxWeek: 19,
  currentWeek: null,
  updatedAt: null
};

const SNAPSHOT_SCRIPT = require('./portal-snapshot');
const { teachingWeek, weekNumbers, mergeSnapshot } = require('./schedule-data');

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
  if (!cached || !Array.isArray(cached.courses)) return;
  state = {
    ...state,
    ...cached,
    currentWeek: teachingWeek(cached),
    weekAnchor: cached.weekAnchor ?? cached.currentWeek,
    currentWeekAnchorDate: cached.currentWeekAnchorDate || cached.updatedAt,
    syncStatus: 'ready',
    message: '已缓存，正在连接教务系统',
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
    'err_connection', 'err_timed_out', 'network_timed_out', 'failed to fetch', 'network error',
    'networkerror', 'offline', 'internet connection', 'could not connect'
  ].some(fragment => message.includes(fragment));
}

function markOffline() {
  setStatus('offline', '网络不可用，正在使用已缓存的课表和成绩');
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
  ensurePortalWindow(false);
  const currentURL = portalWindow.webContents.getURL();
  if (!isPortalHome(currentURL)) {
    if (showLogin) { portalWindow.show(); portalWindow.focus(); }
    if (isAuthenticationPage(currentURL)) {
      setStatus('needsAuthorization', '登录已失效，请重新授权');
      if (showLogin) { portalWindow.show(); portalWindow.focus(); }
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
  const generation = cacheGeneration;
  setStatus('syncing', '正在读取课表和全部成绩');
  try {
    const result = await portalWindow.webContents.executeJavaScript(SNAPSHOT_SCRIPT, true);
    const snapshot = JSON.parse(result);
    if (snapshot.__error) {
      if (snapshot.__error.includes('AUTH_REQUIRED')) throw new Error('AUTH_REQUIRED');
      throw new Error(snapshot.__error);
    }
    const courses = normalizeCourses(snapshot.courses || []);
    if (!Array.isArray(snapshot.courses) || (snapshot.courses.length && !courses.length)) throw new Error('没有识别到课程数据');
    if (generation !== cacheGeneration) return;
    state = mergeSnapshot(state, snapshot, courses);
    writeJSON(dataPath('schedule-cache.json'), state);
    broadcastState();
    if (portalWindow.isVisible()) portalWindow.hide();
  } catch (error) {
    if (generation !== cacheGeneration) return;
    if (String(error.message).includes('AUTH_REQUIRED')) {
      setStatus('needsAuthorization', '登录已失效，请重新授权');
      if (showLogin) portalWindow.show();
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
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.setMenuBarVisibility(false);
  return window;
}

function createBallWindow() {
  const display = screen.getPrimaryDisplay().workArea;
  const saved = {x: settings.ballX || display.x, y: settings.ballY || display.y, width: BALL_SIZE, height: BALL_SIZE};
  const work = screen.getDisplayMatching(saved).workArea;
  const initialX = Math.max(work.x + 6, Math.min(Number.isFinite(settings.ballX) ? settings.ballX : work.x + work.width - BALL_SIZE - 22, work.x + work.width - BALL_SIZE - 6));
  const initialY = Math.max(work.y + 6, Math.min(Number.isFinite(settings.ballY) ? settings.ballY : work.y + (work.height - BALL_SIZE) / 2, work.y + work.height - BALL_SIZE - 6));
  ballWindow = createLocalWindow({
    width: BALL_SIZE,
    height: BALL_SIZE,
    x: initialX,
    y: Math.round(initialY),
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
  const acrylic = process.platform === 'win32' && Number(os.release().split('.')[2]) >= 22621;
  panelWindow = createLocalWindow({
    width: PANEL_WIDTH,
    height: PANEL_HEIGHT,
    frame: false,
    transparent: !acrylic,
    ...(acrylic ? {backgroundMaterial: 'acrylic'} : {}),
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    hasShadow: true,
    backgroundColor: '#00000000'
  }, 'panel');
  panelWindow.setAlwaysOnTop(true, 'floating');
  panelWindow.setVisibleOnAllWorkspaces(true);
  panelWindow.on('blur', () => { if (!smokeTest) panelWindow.hide(); });
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
    if (smokeTest) return;
    const currentURL = portalWindow.webContents.getURL();
    networkOnline = true;
    if (isPortalHome(currentURL)) syncSchedule();
    else if (isAuthenticationPage(currentURL)) setStatus('needsAuthorization', '登录已失效，请重新授权');
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
  portalWindow.loadURL(smokeTest ? 'about:blank' : PORTAL_URL);
  return portalWindow;
}

function openPortalHome() {
  const window = ensurePortalWindow(true);
  if (smokeTest) return;
  let pathname = '';
  try { pathname = new URL(window.webContents.getURL()).pathname; } catch {}
  if (!['/admin', '/admin/'].includes(pathname)) {
    window.loadURL(PORTAL_URL).catch(error => {
      if (isNetworkError(error)) markOffline();
      else setStatus('failed', `打开教务系统首页失败：${error.message}`);
    });
  }
}

function showPanel() {
  if (!panelWindow || !ballWindow) return;
  revealBall();
  const ball = ballWindow.getBounds();
  const display = screen.getDisplayMatching(ball).workArea;
  const width = Math.min(PANEL_WIDTH, display.width - 16);
  const height = Math.min(PANEL_HEIGHT, display.height - 16);
  panelWindow.setSize(width, height, false);
  let x = ball.x - width + ball.width;
  if (x < display.x + 8) x = ball.x + ball.width + 8;
  x = Math.max(display.x + 8, Math.min(x, display.x + display.width - width - 8));
  let y = Math.round(ball.y + ball.height / 2 - height / 2);
  y = Math.max(display.y + 8, Math.min(y, display.y + display.height - height - 8));
  panelWindow.setPosition(Math.round(x), Math.round(y), false);
  panelWindow.show();
  panelWindow.focus();
  broadcastState();
  panelWindow.webContents.send('panel:opened');
}

function togglePanel() {
  if (settings.edge) { revealBall(); showPanel(); return; }
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
  updateTrayMenu();
  tray.on('double-click', togglePanel);
}

function updateTrayMenu() {
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: '显示 / 收起课表', click: togglePanel },
    { label: '立即同步', click: () => syncSchedule({ showLogin: true }) },
    { label: '首次授权或重新登录', click: () => ensurePortalWindow(true) },
    { label: '打开教务系统首页', click: openPortalHome },
    { label: '登录后自动显示悬浮球', type: 'checkbox', checked: !smokeTest && app.getLoginItemSettings().openAtLogin,
      enabled: app.isPackaged && !smokeTest, click: item => {
        app.setLoginItemSettings({openAtLogin: item.checked, name: 'cn.liuli.imnu-schedule-float'});
        settings.startAtLogin = item.checked;
        saveSettings();
        updateTrayMenu();
      } },
    { type: 'separator' },
    { label: '退出教务悬浮助手', click: () => { app.isQuitting = true; app.quit(); } }
  ]));
}

function registerIPC() {
  const allowed = event => [ballWindow, panelWindow].some(window => window && !window.isDestroyed() && window.webContents === event.sender && event.senderFrame === event.sender.mainFrame);
  const on = (channel, handler) => ipcMain.on(channel, (event, ...args) => { if (allowed(event)) return handler(event, ...args); });
  const handle = (channel, handler) => ipcMain.handle(channel, (event, ...args) => { if (!allowed(event)) throw new Error('Untrusted sender'); return handler(event, ...args); });
  handle('state:get', () => state);
  on('ball:activate', togglePanel);
  on('ball:reveal', revealBall);
  on('ball:drag-start', (_event, point) => {
    if (settings.edge || !ballWindow || !Number.isFinite(point?.x) || !Number.isFinite(point?.y)) return;
    dragOrigin = { pointerX: point.x, pointerY: point.y, bounds: ballWindow.getBounds() };
  });
  on('ball:drag-move', (_event, point) => {
    if (!dragOrigin || !ballWindow || !Number.isFinite(point?.x) || !Number.isFinite(point?.y)) return;
    const x = Math.round(dragOrigin.bounds.x + point.x - dragOrigin.pointerX);
    const y = Math.round(dragOrigin.bounds.y + point.y - dragOrigin.pointerY);
    ballWindow.setPosition(x, y, false);
    if (panelWindow?.isVisible()) showPanel();
  });
  on('ball:drag-end', finishBallDrag);
  on('panel:hide', () => panelWindow?.hide());
  on('action:authorize', () => ensurePortalWindow(true));
  on('action:portal-home', openPortalHome);
  on('action:sync', () => syncSchedule({ showLogin: true }));
  on('network:changed', (_event, online) => {
    networkOnline = Boolean(online);
    if (!networkOnline) {
      markOffline();
    } else if (state.syncStatus === 'offline') {
      reloadPortalAfterNetworkRecovery();
    }
  });
  handle('action:clear', async () => {
    cacheGeneration += 1;
    try { fs.unlinkSync(dataPath('schedule-cache.json')); } catch {}
    if (portalWindow && !portalWindow.isDestroyed()) {
      await portalWindow.webContents.session.clearStorageData();
      await portalWindow.webContents.session.clearCache();
    }
    state = {
      syncStatus: 'sample', message: '尚未同步真实课表', courses: [],
      profile: { name: '', studentNumber: '', gpa: '' }, grades: [], gradesUpdatedAt: null, term: '', maxWeek: 19,
      currentWeek: null, updatedAt: null
    };
    broadcastState();
    ensurePortalWindow(true).loadURL(PORTAL_URL);
    return true;
  });
  on('action:quit', () => { app.isQuitting = true; app.quit(); });
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) app.quit();
else {
  app.on('second-instance', () => {
    revealBall();
    showPanel();
  });

  app.whenReady().then(async () => {
    loadLocalState();
    registerIPC();
    createBallWindow();
    createPanelWindow();
    if (!smokeTest && app.isPackaged && settings.startAtLogin === undefined) {
      app.setLoginItemSettings({openAtLogin: true, name: 'cn.liuli.imnu-schedule-float'});
      settings.startAtLogin = true;
      saveSettings();
    }
    createTray();
    if (smokeTest) {
      await require('./smoke-test').run({app, ballWindow, panelWindow, ensurePortalWindow, smokeOutput,
        hideBallAtEdge, setFixture: value => { state = mergeSnapshot(state, value, normalizeCourses(value.courses)); broadcastState(); }});
      return;
    }
    clockTimer = setInterval(() => {
      const week = teachingWeek(state);
      if (week !== state.currentWeek) { state.currentWeek = week; broadcastState(); }
    }, 30000);
    ensurePortalWindow(!state.updatedAt);
    refreshTimer = setInterval(() => syncSchedule(), REFRESH_INTERVAL);
    powerMonitor.on('resume', () => syncSchedule());
  });
}

app.on('window-all-closed', () => {});
app.on('before-quit', () => {
  app.isQuitting = true;
  if (refreshTimer) clearInterval(refreshTimer);
  if (clockTimer) clearInterval(clockTimer);
});
