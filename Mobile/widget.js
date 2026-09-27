// Variables used by Scriptable.
// These must be at the very top of the file. Do not edit.
// icon-color: purple; icon-glyph: calendar-alt;

/* __MOBILE_CORE__ */
const EMBEDDED_DATA = /* __MOBILE_DATA__ */;
const PHONE_HTML = /* __MOBILE_HTML__ */;
const BACKGROUND = /* __MOBILE_BACKGROUND__ */;
const Core = IMNUScheduleCore;
const local = FileManager.local();
const store = local.joinPath(local.documentsDirectory(), 'IMNU-widget');
const dataPath = local.joinPath(store, 'schedule.json');
const backgroundPath = local.joinPath(store, 'background.png');
let data = null;
let customBackground = null;

function saveData(raw) {
  const valid = Core.validate(raw);
  if (!local.fileExists(store)) local.createDirectory(store, true);
  local.writeString(dataPath, JSON.stringify(valid));
  return valid;
}
function readData(fm, path) {
  if (!fm.fileExists(path)) return null;
  return Core.validate(JSON.parse(fm.readString(path).replace(/^\uFEFF/, '')));
}
function revision(raw) { return Date.parse(raw.exportedAt || raw.updatedAt) || 0; }
async function loadData() {
  const candidates = [];
  try { const cached = readData(local, dataPath); if (cached) candidates.push(cached); } catch (_) {}
  try { if (EMBEDDED_DATA) candidates.push(Core.validate(EMBEDDED_DATA)); } catch (_) {}
  // Optional private iCloud transport; never request a public endpoint.
  try {
    const cloud = FileManager.iCloud();
    for (const filename of ['schedule.json', 'schedule-cache.json']) {
      try {
        const path = cloud.joinPath(cloud.documentsDirectory(), 'IMNU-widget/' + filename);
        if (cloud.fileExists(path)) {
          if (!cloud.isFileDownloaded(path)) await cloud.downloadFileFromiCloud(path);
          const synced = readData(cloud, path); if (synced) candidates.push(synced);
        }
      } catch (_) {}
    }
  } catch (_) {}
  candidates.sort((a, b) => revision(b) - revision(a));
  if (!candidates.length) return null;
  return saveData(candidates[0]);
}
async function loadBackground() {
  try {
    const cloud = FileManager.iCloud();
    const path = cloud.joinPath(cloud.documentsDirectory(), 'IMNU-widget/background.png');
    if (cloud.fileExists(path)) {
      if (!cloud.isFileDownloaded(path)) await cloud.downloadFileFromiCloud(path);
      const image = cloud.readImage(path);
      if (image) {
        if (!local.fileExists(store)) local.createDirectory(store, true);
        local.writeImage(backgroundPath, image); customBackground = image; return;
      }
    }
  } catch (_) {}
  try { if (local.fileExists(backgroundPath)) customBackground = local.readImage(backgroundPath); } catch (_) {}
}
function color(light, dark) { return Color.dynamic(new Color(light), new Color(dark)); }
function ink() { return color('#252a30', '#f5f2ec'); }
function muted() { return color('#555e68', '#c2cbd3'); }
function accent() { return color('#355b77', '#a9c9e3'); }
function text(stack, value, size, weight, tint, lines = 1) {
  const item = stack.addText(String(value));
  item.font = weight === 'bold' ? Font.boldSystemFont(size) : weight === 'medium' ? Font.mediumSystemFont(size) : Font.systemFont(size);
  item.textColor = tint || ink(); item.lineLimit = lines; item.minimumScaleFactor = 0.8;
  return item;
}
function nextLessonText(raw, primary, today) {
  const following = raw && primary ? Core.followingCourse(raw, primary) : null;
  if (!following) return [raw && primary ? '暂无后续课程' : '课表待更新', ''];
  const time = Core.times(following.course);
  const day = following.key === primary.key ? '' : Core.labelFor(following.key, today) + ' ';
  return ['下节 ' + day + (time ? time.start : '时间待确认') + ' · ' + following.course.name,
    following.course.location || '教室待公布'];
}
function buildWidget(raw, family, now = new Date(), parameter = '') {
  const widget = new ListWidget();
  widget.url = URLScheme.forRunningScript();
  const accessory = family.startsWith('accessory');
  widget.setPadding(accessory ? 2 : 15, accessory ? 3 : 15, accessory ? 2 : 14, accessory ? 3 : 15);
  if (accessory) widget.addAccessoryWidgetBackground = true;
  else {
    const gradient = new LinearGradient();
    gradient.colors = [color('#f7f4ee','#303740'), color('#e8edf0','#1e252d')];
    gradient.locations = [0, 1]; gradient.startPoint = new Point(0, 0); gradient.endPoint = new Point(1, 1);
    widget.backgroundGradient = gradient;
  }
  const today = Core.dayKey(now), target = parameter === 'tomorrow' || parameter === '明天' ? Core.addDays(today, 1) : today;
  const week = raw ? Core.weekAt(raw, target) : null;
  const next = raw && target === today ? Core.nextCourse(raw, now) : null;
  const todayRows = raw ? Core.coursesOn(raw, target) : [];
  const primary = target !== today ? (todayRows[0] ? {course:todayRows[0],key:target,inProgress:false} : null) : next;
  const time = primary ? Core.times(primary.course) : null;
  const title = !raw ? '导入课表' : week === null ? '教学周待确认' : !primary ? '暂无课程' : primary.course.name;
  const hint = !raw ? '点击设置' : week === null ? '点击更新课表' : !primary ? '打开完整课表' : time ? time.start + '–' + time.end : '时间待确认';
  let illustration = family === 'medium' ? customBackground : null;
  if (family === 'medium' && !illustration && BACKGROUND) {
    try { illustration = Image.fromData(Data.fromBase64String(BACKGROUND)); } catch (_) {}
  }
  if (illustration) {
    // The supplied horizontal artwork already has a blurred, light text area.
    // Keep text inside its left half and use fixed dark ink even in dark mode.
    widget.backgroundImage = illustration;
    widget.backgroundGradient = null;
    const screen = Device.screenSize();
    const width = Math.min(205, Math.max(145, (Math.min(screen.width, screen.height) - 56) * 0.53 - 15));
    const row = widget.addStack();
    const column = row.addStack(); column.layoutVertically(); column.size = new Size(width, 0);
    row.addSpacer();
    const dark = new Color('#252a30'), blue = new Color('#355b77'), secondary = new Color('#4b5662');
    text(column, (target === today ? '课表' : '明天') + '  ·  ' + (week === null ? '待更新' : '第 ' + week + ' 周'), 11, 'medium', secondary);
    column.addSpacer(7);
    const clock = column.addStack(); clock.centerAlignContent();
    text(clock, time ? time.start : '—', 28, 'bold', blue);
    clock.addSpacer(7);
    text(clock, primary ? primary.inProgress ? '正在上课' : Core.labelFor(primary.key,today) : '', 10, 'medium', secondary);
    column.addSpacer(4);
    text(column, title, 16, 'bold', dark, 2);
    column.addSpacer(4);
    text(column, primary ? primary.course.location || '教室待公布' : hint, 11, 'medium', secondary);
    column.addSpacer(8);
    const following = nextLessonText(raw, primary, today);
    text(column, following[0], 10, 'regular', secondary);
    if (following[1]) { column.addSpacer(2); text(column, following[1], 10, 'regular', secondary, 2); }
    widget.addSpacer();
  } else if (family === 'accessoryInline') {
    text(widget, primary ? (time ? time.start + ' ' : '') + title + ' · ' + (primary.course.location || '教室待公布') : title, 12, 'medium', Color.white());
  } else if (family === 'accessoryCircular') {
    const stack = widget.addStack(); stack.layoutVertically(); stack.centerAlignContent();
    const t = text(stack, primary && time ? time.start : week !== null ? String(week) : '课表', 16, 'bold', Color.white()); t.centerAlignText();
    const s = text(stack, primary ? Core.labelFor(primary.key,today) : week !== null ? '教学周' : '点此打开', 11, 'regular', Color.white()); s.centerAlignText();
  } else if (family === 'accessoryRectangular') {
    text(widget, primary ? (primary.inProgress ? '正在上课' : Core.labelFor(primary.key,today)) + ' · ' + hint : hint, 11, 'medium', Color.white());
    text(widget, title, 14, 'bold', Color.white());
    text(widget, primary ? primary.course.location || '教室待公布' : '教务助手', 11, 'regular', Color.white());
  } else {
    const head = widget.addStack(); head.centerAlignContent();
    const symbol = head.addImage(SFSymbol.named('calendar').image); symbol.imageSize = new Size(13,13); symbol.tintColor = accent();
    head.addSpacer(6); text(head, target === today ? '课表' : '明天', 12, 'medium', muted()); head.addSpacer();
    text(head, week === null ? '待更新' : '第 ' + week + ' 周', 11, 'medium', muted());
    widget.addSpacer(12);
    if (family === 'small') {
      text(widget, primary ? primary.inProgress ? '正在上课' : Core.labelFor(primary.key,today) + ' · 下一节' : hint, 11, 'medium', accent());
      widget.addSpacer(5); text(widget, title, 17, 'bold', ink(), 2); widget.addSpacer(5);
      text(widget, primary ? primary.course.location || '教室待公布' : '点此打开课表', 11, 'regular', muted(), 1);
      widget.addSpacer(); text(widget, primary ? hint : new Date(now.getTime()+8*3600000).toISOString().slice(5,10).replace('-',' / '), 12, 'medium', primary ? accent() : muted());
    } else {
      const row = widget.addStack(); row.centerAlignContent();
      const details = row.addStack(); details.layoutVertically();
      text(details, primary ? primary.inProgress ? '正在上课' : Core.labelFor(primary.key,today) + ' · 下一节' : hint, 11, 'medium', accent());
      details.addSpacer(4); text(details, title, 18, 'bold', ink(), 1);
      details.addSpacer(4); text(details, primary ? primary.course.location || '教室待公布' : '点此查看完整课表', 12, 'regular', muted());
      row.addSpacer(12);
      const clock = row.addStack(); clock.layoutVertically();
      const start = text(clock, time ? time.start : '—', 24, 'bold', accent()); start.rightAlignText();
      if (family !== 'medium') { const end = text(clock, time ? '至 ' + time.end : '教务助手', 11, 'regular', muted()); end.rightAlignText(); }
      if (family === 'large') {
        widget.addSpacer(19);
        text(widget, target === today ? '今天的课程' : '明天的课程', 12, 'medium', muted()); widget.addSpacer(8);
        const rows = target === today ? todayRows.filter(c => {const r=Core.interval(c,target);return !r || r.end>now;}) : todayRows;
        if (!rows.length) text(widget, week === null ? '更新数据后查看' : todayRows.length ? '今天的课程已结束' : '这一天没有课', 13, 'regular', muted());
        rows.slice(0,4).forEach(c => {const line=widget.addStack();line.centerAlignContent();const t=Core.times(c);text(line,t?t.start:'—',12,'medium',accent());line.addSpacer(10);text(line,c.name,13,'medium',ink());line.addSpacer();widget.addSpacer(5);text(widget,c.location||'教室待公布',11,'regular',muted());widget.addSpacer(9);});
      }
      widget.addSpacer();
      const age = raw ? Core.staleDays(raw,now) : null;
      if (family === 'medium') {
        const following = nextLessonText(raw, primary, today);
        text(widget, following.filter(Boolean).join('\n'), 10, 'regular', muted(), 3);
      } else text(widget, !raw || week === null ? '点此导入或更新课表' : age !== null && age >= 7 ? age + ' 天未更新 · 点此查看' : (target===today?'今天 ':'明天 ') + todayRows.length + ' 节课 · 点此查看完整课表', 11, 'regular', muted());
    }
  }
  widget.refreshAfterDate = raw ? Core.nextRefresh(raw, now) : new Date(now.getTime()+30*60000);
  return widget;
}
async function alertMessage(title, message) { const a = new Alert(); a.title = title; a.message = message; a.addAction('好'); await a.presentAlert(); }
async function importData() {
  try {
    const path = await DocumentPicker.openFile();
    if (!path) return false;
    const imported = Core.validate(JSON.parse(local.readString(path).replace(/^\uFEFF/, '')));
    data = saveData({...imported, exportedAt: new Date().toISOString()});
    await alertMessage('课表已更新', '主屏幕和锁屏小组件将在 iOS 安排刷新时显示新课表。');
    return true;
  } catch (_) { await alertMessage('没有更新课表', '请重新选择电脑导出的“内师大课表.json”。原有课表仍然保留。'); return false; }
}
async function preview() {
  const menu = new Alert(); menu.title = '预览小组件'; menu.addAction('小号 · 下一节课'); menu.addAction('中号 · 课表概览'); menu.addAction('大号 · 今天课程'); menu.addCancelAction('取消');
  const choice = await menu.presentSheet(); if(choice<0)return;
  const widget=buildWidget(data,['small','medium','large'][choice]);
  if(choice===0)await widget.presentSmall();if(choice===1)await widget.presentMedium();if(choice===2)await widget.presentLarge();
}
async function phoneView() {
  if (!data) { await alertMessage('先导入课表', '选择电脑导出的“内师大课表.json”，即可离线查看并添加小组件。'); if(!await importData())return; }
  const view = new WebView(); let busy = false;
  async function load() {
    const serialized=JSON.stringify(data).replace(/</g,'\\u003c').replace(/\u2028/g,'\\u2028').replace(/\u2029/g,'\\u2029');
    await view.loadHTML(PHONE_HTML.replace('/* __MOBILE_DATA__ */',()=>serialized));
  }
  view.shouldAllowRequest = request => {
    if(request.url.startsWith('imnuwidget://')) {
      if(!busy){busy=true;(async()=>{try{const action=request.url.slice('imnuwidget://'.length).split(/[/?#]/)[0];if(action==='import'){if(await importData())await load();}if(action==='preview')await preview();if(action==='portal')Safari.open('https://jwxt.imnu.edu.cn');}finally{busy=false;}})();}
      return false;
    }
    return request.url==='about:blank' || request.url.startsWith('data:') || request.url.startsWith('file:');
  };
  await load(); await view.present(false);
}
async function main() {
  data = await loadData();
  await loadBackground();
  if(config.runsInWidget){Script.setWidget(buildWidget(data,config.widgetFamily||'medium',new Date(),args.widgetParameter||''));Script.complete();return;}
  if(args.fileURLs && args.fileURLs.length){try{const imported=Core.validate(JSON.parse(local.readString(args.fileURLs[0]).replace(/^\uFEFF/,'')));data=saveData({...imported,exportedAt:new Date().toISOString()});}catch(_){await alertMessage('导入失败','请选择教务助手保存的课表 JSON。');}}
  await phoneView(); Script.complete();
}
await main();
