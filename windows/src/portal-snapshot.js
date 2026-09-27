// Generated from WebSession.swift by Release/sync-portal-parser.py.
// PortalSnapshotRegression.cjs verifies native / Windows parser parity.
module.exports = `(async () => {
  const timedFetch = async (url, options = {}) => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    try { return await fetch(url, {...options, signal: controller.signal}); }
    catch (error) {
      if (error.name === 'AbortError') throw new Error('NETWORK_TIMED_OUT');
      throw error;
    } finally { clearTimeout(timeout); }
  };
  const isLogin = response => response &&
    ([401,403].includes(response.status) || /\\/login|caslogin|\\/cas\\//i.test(response.url));
  const optionalJSON = async response => response && response.ok && !isLogin(response)
    ? await response.json().catch(() => null) : null;
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
  const pageResponse = await timedFetch('/admin/xsd/pkgl/xskb/queryKbForXsd', {credentials:'include'});
  if (isLogin(pageResponse)) throw new Error('AUTH_REQUIRED');
  if (!pageResponse.ok) throw new Error('课表页面暂时不可用（HTTP ' + pageResponse.status + '）');
  const pageHTML = await pageResponse.text();
  const page = new DOMParser().parseFromString(pageHTML, 'text/html');
  const field = id => page.querySelector(\`#\${id}\`)?.getAttribute('value') || page.querySelector(\`#\${id}\`)?.textContent?.trim() || '';
  const term = field('xnxq');
  const xhid = field('xhid');
  const campus = field('xqdm');
  if (!term) {
    if (page.querySelector('input[type="password"], #loginForm, .login-form') || /扫码登录|统一身份认证/.test(page.title)) throw new Error('AUTH_REQUIRED');
    throw new Error('课表页面缺少学期信息，请稍后重试');
  }

  const form = new URLSearchParams({xnxq:term, xhid, xqdm:campus, zdzc:'', zxzc:'', xskbxslx:'0'});
  const gradeCategories = [{value:'0', label:'主修'}, {value:'1', label:'辅修'}, {value:'9', label:'微专业'}];
  const gradeRequests = gradeCategories.map(item => timedFetch(
    '/admin/xsd/xsdcjcx/xsdQueryXscjList?fxbz=' + item.value + '&gridtype=jqgrid&_search=false&page.size=500&page.pn=1&sort=xnxq&order=desc&startXnxq=001&endXnxq=001',
    {credentials:'include', headers:{'X-Requested-With':'XMLHttpRequest', 'Accept':'application/json, text/javascript, */*; q=0.01'}}
  ).catch(() => null));
  const [courseResponse, profileResponse, gpaResponse, weeksResponse, currentWeekResponse, gradeResponses] = await Promise.all([
    timedFetch('/admin/xsd/pkgl/xskb/sdpkkbList', {method:'POST', credentials:'include', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'}, body:form}),
    timedFetch('/admin/xsd/xskp/xskp?xhid=' + encodeURIComponent(xhid), {credentials:'include'}).catch(() => null),
    timedFetch('/admin/xsd/xsdzgcjcx/getXspjxfjd', {credentials:'include'}).catch(() => null),
    timedFetch('/admin/getCurrentPkZc', {credentials:'include'}).catch(() => null),
    timedFetch('/admin/api/getXlzc', {credentials:'include'}).catch(() => null),
    Promise.all(gradeRequests)
  ]);
  if (isLogin(courseResponse)) throw new Error('AUTH_REQUIRED');
  if (!courseResponse.ok) throw new Error('课表请求暂时失败（HTTP ' + courseResponse.status + '）');
  const [courseJSON, profileJSON, gpaJSON, weeksJSON, currentWeekJSON, gradeJSONs] = await Promise.all([
    courseResponse.json(), optionalJSON(profileResponse), optionalJSON(gpaResponse),
    optionalJSON(weeksResponse), optionalJSON(currentWeekResponse),
    Promise.all(gradeResponses.map(optionalJSON))
  ]);
  if (courseJSON.ret !== 0) throw new Error(courseJSON.msg || 'COURSE_RESPONSE');
  if (!Array.isArray(courseJSON.data)) throw new Error('课表数据格式已变化，请稍后重试');
  const rawProfile = profileJSON && profileJSON.data || {};
  const identityRow = Array.from(document.querySelectorAll('.header_left li')).find(node => /姓名\\s*\\/\\s*学号/.test(node.textContent || ''));
  const identity = text(identityRow?.querySelector('.value')?.textContent).split('/');
  const profileName = text(rawProfile.xm) || text(identity[0]);
  const profileNumber = text(rawProfile.xh) || text(identity[1]);
  const profileGPA = text(gpaJSON && gpaJSON.data) || text(document.querySelector('#pjxfjd')?.textContent);
  const rawCourses = Array.isArray(courseJSON.data) ? courseJSON.data : [];
  const courses = rawCourses.map(item => {
    const building = plain(item.jxlmc);
    const room = plain(item.croommc || item.croombh);
    return {
      name: plain(item.kcmc),
      teacher: plain(item.tmc || item.jsmc || item.teacher || item.jsxq),
      location: Array.from(new Set([building, room].filter(Boolean))).join(' · '),
      weekday: weekday(item.xingqi || item.xq),
      section: text(item.djc || item.djs || item.jc),
      weeks: text(item.zcstr || item.zc)
    };
  }).filter(item => item.name && item.weekday > 0);
  const allWeeks = Array.isArray(weeksJSON?.data) ? weeksJSON.data.map(Number).filter(value => Number.isInteger(value) && value > 0 && value <= 60) : [];
  const weekValue = currentWeekJSON?.data?.xlzc ?? currentWeekJSON?.data?.zc;
  const currentWeekResolved = weekValue != null && Number.isFinite(Number(weekValue));
  const currentWeek = currentWeekResolved && Number(weekValue) > 0 ? Number(weekValue) : null;
  const successfulGradeResponses = gradeJSONs
    .map((payload, categoryIndex) => ({payload, categoryIndex}))
    .filter(item => item.payload && item.payload.ret === 0 && Array.isArray(item.payload.results));
  const grades = successfulGradeResponses.length ? successfulGradeResponses.flatMap(({payload, categoryIndex}) => {
    const records = Array.isArray(payload.results) ? payload.results : [];
    const category = gradeCategories[categoryIndex]?.label || '主修';
    return records.map((item, index) => ({
      id: category + '|' + (text(item.id) || [text(item.xnxq), text(item.kcbh), index].join('|')),
      term: text(item.xnxq),
      courseName: plain(item.kcmc).replace(/^\\[[^\\]]+\\]\\s*/, ''),
      score: text(item.zhcj ?? item.yscj),
      credit: text(item.xf),
      gradePoint: text(item.jd),
      courseNature: text(item.kcxzmc || item.kcxz),
      examType: text(item.ksxs),
      category
    })).filter(item => item.courseName);
  }) : null;
  const gradeCategoriesSynced = successfulGradeResponses.map(({categoryIndex}) => gradeCategories[categoryIndex].label);
  const syncWarnings = [];
  if (gradeCategoriesSynced.length !== gradeCategories.length) syncWarnings.push('部分成绩暂未更新，保留已有缓存');
  if (!currentWeekResolved) syncWarnings.push('本次未获取官方教学周');
  if (!profileJSON || !gpaJSON) syncWarnings.push('部分个人信息暂未更新，保留已有缓存');
  return JSON.stringify({
    term,
    maxWeek: allWeeks.length ? Math.max(...allWeeks) : 19,
    currentWeek,
    currentWeekResolved,
    profile: {
      studentNumber: profileNumber,
      name: profileName,
      gpa: profileGPA
    },
    courses,
    grades,
    gradeCategoriesSynced,
    syncWarnings
  });
})().catch(error => JSON.stringify({__error:String(error && error.message || error)}))`;
