const appRoot = document.getElementById('app');
const mode = new URLSearchParams(location.search).get('mode') || 'panel';
const weekdayLabels = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
let appState = {
  syncStatus: 'sample', message: '尚未同步真实课表', courses: [],
  profile: { name: '', studentNumber: '', gpa: '' }, grades: [], gradesUpdatedAt: null,
  term: '', maxWeek: 19, currentWeek: null
};
let selectedView = 'today';
let selectedWeek = 1;
let selectedGradeTerm = 'all';
const CLASS_TIME_BLOCKS = [
  { startSection: 1, endSection: 2, start: '08:20', end: '10:00' },
  { startSection: 3, endSection: 4, start: '10:20', end: '12:00' },
  { startSection: 5, endSection: 6, start: '14:00', end: '15:40' },
  { startSection: 7, endSection: 8, start: '16:00', end: '17:40' },
  { startSection: 9, endSection: 10, start: '19:00', end: '20:40' }
];

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function iconCalendar() {
  const node = element('div', 'calendar-icon');
  node.innerHTML = '<span></span><span></span><span></span><span></span><span></span><span></span>';
  return node;
}

function renderBall(ballMode = 'ball') {
  appRoot.replaceChildren();
  document.body.className = ballMode === 'handle' ? 'ball-page handle-page' : 'ball-page';
  const control = element('button', ballMode === 'handle' ? 'edge-handle' : 'floating-ball');
  control.type = 'button';
  control.setAttribute('aria-label', ballMode === 'handle' ? '显示教务悬浮球' : `教务悬浮助手，${appState.message}`);
  if (ballMode === 'handle') {
    control.addEventListener('mouseenter', () => window.assistantAPI.revealBall());
    control.addEventListener('click', () => window.assistantAPI.revealBall());
  } else {
    control.append(iconCalendar());
    control.append(element('span', `status-dot status-${appState.syncStatus}`));
    let start = null;
    let dragged = false;
    control.addEventListener('pointerdown', event => {
      start = { x: event.screenX, y: event.screenY };
      dragged = false;
      control.setPointerCapture(event.pointerId);
      window.assistantAPI.dragStart(event.screenX, event.screenY);
    });
    control.addEventListener('pointermove', event => {
      if (!start) return;
      if (Math.abs(event.screenX - start.x) > 2 || Math.abs(event.screenY - start.y) > 2) dragged = true;
      if (dragged) window.assistantAPI.dragMove(event.screenX, event.screenY);
    });
    control.addEventListener('pointerup', event => {
      if (!start) return;
      control.releasePointerCapture(event.pointerId);
      window.assistantAPI.dragEnd();
      if (!dragged) window.assistantAPI.activateBall();
      start = null;
    });
    control.addEventListener('pointercancel', () => { start = null; window.assistantAPI.dragEnd(); });
  }
  appRoot.append(control);
}

function tabButton(label, value) {
  const button = element('button', `tab ${selectedView === value ? 'active' : ''}`, label);
  button.type = 'button';
  button.addEventListener('click', () => {
    selectedView = value;
    if (value === 'semester') selectedWeek = Math.min(Math.max(appState.currentWeek || 1, 1), appState.maxWeek || 19);
    renderPanel();
  });
  return button;
}

function coursesForWeek(week) {
  if (!week) return [];
  return appState.courses.filter(course => !Array.isArray(course.activeWeeks) || course.activeWeeks.length === 0 || course.activeWeeks.includes(week));
}

function currentWeekday() {
  const day = new Date().getDay();
  return day === 0 ? 7 : day;
}

function classTimeText(course) {
  const first = CLASS_TIME_BLOCKS.find(block => course.startSection >= block.startSection && course.startSection <= block.endSection);
  const last = CLASS_TIME_BLOCKS.find(block => course.endSection >= block.startSection && course.endSection <= block.endSection);
  return first && last ? `${first.start}–${last.end}` : '';
}

function courseCard(course) {
  const card = element('article', 'course-card');
  card.append(element('span', `course-accent color-${course.colorIndex % 6}`));
  const content = element('div', 'course-content');
  const heading = element('div', 'course-heading');
  heading.append(element('strong', 'course-name', course.name));
  const section = course.startSection === course.endSection ? `第${course.startSection}节` : `第${course.startSection}-${course.endSection}节`;
  const sectionMeta = element('span', 'course-section-meta');
  sectionMeta.append(element('span', 'course-section', section));
  const time = classTimeText(course);
  if (time) sectionMeta.append(element('span', 'course-time', time));
  heading.append(sectionMeta);
  content.append(heading);
  const meta = [course.teacher, course.location].filter(Boolean).join(' · ');
  if (meta) content.append(element('div', 'course-meta', meta));
  if (course.weeks) content.append(element('div', 'course-weeks', course.weeks));
  card.append(content);
  return card;
}

function emptyState(title, description) {
  const box = element('div', 'empty-state');
  box.append(iconCalendar());
  box.append(element('h2', null, title));
  box.append(element('p', null, description));
  return box;
}

function groupedCourseList(courses, title) {
  const wrap = element('div', 'course-list');
  if (title) wrap.append(element('h2', 'list-title', title));
  if (!courses.length) {
    wrap.append(emptyState('这一周没有课程', '可在上方切换其他教学周。'));
    return wrap;
  }
  for (let day = 1; day <= 7; day += 1) {
    const rows = courses.filter(course => course.weekday === day).sort((a, b) => a.startSection - b.startSection);
    if (!rows.length) continue;
    wrap.append(element('h3', 'day-heading', weekdayLabels[day - 1]));
    rows.forEach(course => wrap.append(courseCard(course)));
  }
  return wrap;
}

function renderViewContent(container) {
  if (selectedView === 'today') {
    const formatter = new Intl.DateTimeFormat('zh-CN', { month: 'numeric', day: 'numeric', weekday: 'long' });
    container.append(element('h2', 'list-title', `今天 · ${formatter.format(new Date())}`));
    const todayCourses = coursesForWeek(appState.currentWeek)
      .filter(course => course.weekday === currentWeekday())
      .sort((a, b) => a.startSection - b.startSection);
    if (!todayCourses.length) container.append(emptyState('今天没有课程', '可切换到“本学期”并选择教学周。'));
    else todayCourses.forEach(course => container.append(courseCard(course)));
    return;
  }

  if (selectedView === 'week') {
    if (!appState.currentWeek) {
      container.append(emptyState('当前不在教学周', `请切换到“本学期”选择第 1–${appState.maxWeek} 周查看。`));
      return;
    }
    container.append(groupedCourseList(coursesForWeek(appState.currentWeek), `本周 · 第 ${appState.currentWeek} 周`));
    return;
  }

  if (selectedView === 'grades') {
    renderGrades(container);
    return;
  }

  const semesterHeader = element('div', 'semester-header');
  semesterHeader.append(element('span', null, appState.term || '本学期课表'));
  semesterHeader.append(element('strong', null, `第 ${selectedWeek} 周`));
  container.append(semesterHeader);
  const weeks = element('div', 'week-scroll');
  for (let week = 1; week <= Math.max(appState.maxWeek || 19, 1); week += 1) {
    const button = element('button', `week-button ${week === selectedWeek ? 'active' : ''}`, String(week));
    button.type = 'button';
    button.title = `查看第 ${week} 周`;
    button.addEventListener('click', () => { selectedWeek = week; renderPanel(); });
    weeks.append(button);
  }
  container.append(weeks);
  container.append(groupedCourseList(coursesForWeek(selectedWeek)));
}

function termLabel(term) {
  const value = String(term || '').trim();
  const parts = value.split('-');
  return parts.length >= 3 ? `${parts[0]}-${parts[1]}学年第${parts[2]}学期` : (value || '未知学期');
}

function gradeTerms() {
  return [...new Set((Array.isArray(appState.grades) ? appState.grades : [])
    .map(item => String(item.term || '').trim()).filter(Boolean))]
    .sort((a, b) => b.localeCompare(a, 'zh-CN'));
}

function renderGrades(container) {
  const grades = Array.isArray(appState.grades) ? appState.grades : [];
  const terms = gradeTerms();
  if (selectedGradeTerm !== 'all' && !terms.includes(selectedGradeTerm)) selectedGradeTerm = 'all';

  const toolbar = element('div', 'grade-toolbar');
  const toolbarText = element('div', 'grade-toolbar-text');
  toolbarText.append(element('strong', null, '成绩范围'));
  toolbarText.append(element('span', null, grades.length ? `已同步 ${grades.length} 门课程` : '等待联网同步全部成绩'));
  const menu = element('details', 'grade-menu');
  const summary = element('summary', null, selectedGradeTerm === 'all' ? '全部学期' : termLabel(selectedGradeTerm));
  menu.append(summary);
  const allButton = element('button', selectedGradeTerm === 'all' ? 'selected' : '', '全部学期');
  allButton.type = 'button';
  allButton.addEventListener('click', () => { selectedGradeTerm = 'all'; renderPanel(); });
  menu.append(allButton);
  if (terms.length) {
    menu.append(element('div', 'grade-submenu-label', '按学期查看'));
    terms.forEach((term, index) => {
      const label = index === 0 ? `最近学期 · ${termLabel(term)}` : termLabel(term);
      const button = element('button', selectedGradeTerm === term ? 'selected' : '', label);
      button.type = 'button';
      button.addEventListener('click', () => { selectedGradeTerm = term; renderPanel(); });
      menu.append(button);
    });
  }
  toolbar.append(toolbarText, menu);
  container.append(toolbar);

  if (!grades.length) {
    container.append(emptyState('暂无成绩缓存', '联网后点击“立即同步”，即可读取官网的全部学期成绩。'));
    return;
  }

  const visibleTerms = selectedGradeTerm === 'all' ? terms : [selectedGradeTerm];
  const visibleGrades = visibleTerms.flatMap(term => grades.filter(item => item.term === term));
  const gradeSummary = element('div', 'grade-summary');
  const totalCredits = visibleGrades.reduce((sum, item) => sum + (Number.parseFloat(item.credit) || 0), 0);
  const points = visibleGrades.map(item => Number.parseFloat(item.gradePoint)).filter(Number.isFinite);
  const averagePoint = points.length ? (points.reduce((sum, value) => sum + value, 0) / points.length).toFixed(2) : '—';
  gradeSummary.append(element('span', null, `${visibleGrades.length} 门课程`));
  gradeSummary.append(element('span', null, `学分 ${totalCredits ? totalCredits.toFixed(1) : '—'}`));
  gradeSummary.append(element('span', null, `平均绩点 ${averagePoint}`));
  container.append(gradeSummary);

  visibleTerms.forEach(term => {
    const rows = grades.filter(item => item.term === term);
    if (!rows.length) return;
    container.append(element('h3', 'grade-term-heading', termLabel(term)));
    rows.forEach(grade => {
      const row = element('article', 'grade-row');
      const main = element('div', 'grade-main');
      main.append(element('strong', null, grade.courseName || '未命名课程'));
      const metadata = [grade.category, grade.credit ? `${grade.credit} 学分` : '', grade.courseNature, grade.examType].filter(Boolean).join(' · ');
      if (metadata) main.append(element('span', 'grade-meta', metadata));
      const result = element('div', 'grade-result');
      result.append(element('strong', 'grade-score', grade.score || '—'));
      result.append(element('span', 'grade-point', `绩点 ${grade.gradePoint || '—'}`));
      row.append(main, result);
      container.append(row);
    });
  });
}

function renderPanel() {
  document.body.className = 'panel-page';
  appRoot.replaceChildren();
  const panel = element('section', 'schedule-panel');

  const header = element('header', 'panel-header');
  const brand = element('div', 'brand-icon');
  brand.textContent = '▰';
  header.append(brand);
  const title = element('div', 'title-block');
  title.append(element('h1', null, '教务悬浮助手'));
  title.append(element('p', `sync-label sync-${appState.syncStatus}`, appState.message));
  header.append(title);
  if (appState.profile?.name || appState.profile?.studentNumber) {
    const profile = element('button', 'profile profile-button');
    profile.type = 'button';
    profile.title = '打开教务系统首页';
    profile.append(element('strong', null, [appState.profile.name, appState.profile.studentNumber].filter(Boolean).join(' · ')));
    profile.append(element('span', null, `绩点 ${appState.profile.gpa || '—'}`));
    profile.addEventListener('click', () => window.assistantAPI.portalHome());
    header.append(profile);
  }
  const close = element('button', 'close-button', '×');
  close.type = 'button';
  close.title = '收起';
  close.addEventListener('click', () => window.assistantAPI.hidePanel());
  header.append(close);
  panel.append(header);

  const tabs = element('nav', 'tabs');
  tabs.append(tabButton('今天', 'today'), tabButton('本周', 'week'), tabButton('本学期', 'semester'), tabButton('成绩查询', 'grades'));
  panel.append(tabs);

  const content = element('div', 'panel-content');
  renderViewContent(content);
  panel.append(content);

  const footer = element('footer', 'panel-footer');
  const authorize = element('button', 'secondary-button', '授权登录');
  authorize.addEventListener('click', () => window.assistantAPI.authorize());
  const sync = element('button', 'primary-button', '立即同步');
  sync.disabled = appState.syncStatus === 'syncing';
  sync.addEventListener('click', () => window.assistantAPI.sync());
  const more = element('button', 'more-button', '•••');
  more.title = '清除本机数据（按住 Shift 点击）';
  more.addEventListener('click', async event => {
    if (event.shiftKey && confirm('确认清除本机课表缓存和登录状态吗？')) await window.assistantAPI.clear();
  });
  const quit = element('button', 'quit-button', '退出');
  quit.addEventListener('click', () => window.assistantAPI.quit());
  footer.append(authorize, sync, element('span', 'footer-spacer'), more, quit);
  panel.append(footer);
  appRoot.append(panel);
}

window.assistantAPI.getState().then(value => {
  appState = { ...appState, ...value };
  selectedWeek = Math.min(Math.max(appState.currentWeek || 1, 1), appState.maxWeek || 19);
  mode === 'ball' ? renderBall() : renderPanel();
});

window.assistantAPI.onState(value => {
  appState = { ...appState, ...value };
  mode === 'ball' ? renderBall(document.body.classList.contains('handle-page') ? 'handle' : 'ball') : renderPanel();
});

if (mode === 'ball') window.assistantAPI.onBallMode(value => renderBall(value));
