/* Shared by Scriptable and the offline phone view. No network or platform APIs. */
const IMNUScheduleCore = (() => {
  const DAY = 86400000;
  const OFFSET = 8 * 3600000;
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  const blocks = [
    [1, 2, '08:20', '10:00'], [3, 4, '10:20', '12:00'],
    [5, 6, '14:00', '15:40'], [7, 8, '16:00', '17:40'],
    [9, 10, '19:00', '20:40']
  ];
  function dayKey(date) { return new Date(new Date(date).getTime() + OFFSET).toISOString().slice(0, 10); }
  function dayNumber(key) { return Date.parse(key + 'T00:00:00Z') / DAY; }
  function weekday(key) { const d = new Date(key + 'T00:00:00Z').getUTCDay(); return d === 0 ? 7 : d; }
  function monday(key) { return dayNumber(key) - weekday(key) + 1; }
  function addDays(key, count) { return new Date((dayNumber(key) + count) * DAY).toISOString().slice(0, 10); }
  function weekAt(data, key) {
    if (!Number.isInteger(data.currentWeek) || !data.weekAnchorDate) return null;
    const week = data.currentWeek + Math.round((monday(key) - monday(data.weekAnchorDate)) / 7);
    return week >= 1 && week <= data.maxWeek ? week : null;
  }
  function parseWeeks(raw) {
    const weeks = new Set();
    String(raw || '').replace(/[，、;；]/g, ',').split(',').forEach(part => {
      const nums = part.match(/\d+/g); if (!nums) return;
      const a = Number(nums[0]), b = Number(nums[1] || nums[0]);
      if (a < 1 || b < 1 || a > 60 || b > 60) return;
      for (let w = Math.min(a, b); w <= Math.max(a, b); w++) {
        if (part.includes('单') && w % 2 === 0 || part.includes('双') && w % 2 !== 0) continue;
        weeks.add(w);
      }
    });
    return [...weeks].sort((a, b) => a - b);
  }
  function times(course) {
    const first = blocks.find(b => course.startSection >= b[0] && course.startSection <= b[1]);
    const last = blocks.find(b => course.endSection >= b[0] && course.endSection <= b[1]);
    return first && last ? { start: first[2], end: last[3] } : null;
  }
  function occurs(course, week) {
    const active = Array.isArray(course.activeWeeks) ? course.activeWeeks : parseWeeks(course.weeks);
    return week !== null && active.includes(week);
  }
  function coursesOn(data, key) {
    const week = weekAt(data, key), day = weekday(key);
    return data.courses.filter(c => c.weekday === day && occurs(c, week))
      .slice().sort((a, b) => a.startSection - b.startSection || a.name.localeCompare(b.name));
  }
  function interval(course, key) {
    const t = times(course);
    return t ? { start: new Date(key + 'T' + t.start + ':00+08:00'), end: new Date(key + 'T' + t.end + ':00+08:00') } : null;
  }
  function nextCourse(data, now) {
    const today = dayKey(now);
    // Unknown teaching week must not silently hide behind a guessed next course.
    if (weekAt(data, today) === null) return null;
    for (let offset = 0; offset <= 14; offset++) {
      const key = addDays(today, offset);
      for (const course of coursesOn(data, key)) {
        const range = interval(course, key);
        if (range && range.end > now) return { course, key, start: range.start, end: range.end, inProgress: range.start <= now };
      }
    }
    return null;
  }
  function validate(raw) {
    if (!raw || raw.schemaVersion !== 1 || !Array.isArray(raw.courses) || raw.courses.length > 1000)
      throw new Error('请选择教务助手导出的课表 JSON 文件');
    const text = (v, max = 300) => typeof v === 'string' ? v.slice(0, max) : '';
    const courses = raw.courses.map((c, index) => {
      if (!c || !text(c.name) || !Number.isInteger(c.weekday) || c.weekday < 1 || c.weekday > 7 ||
          !Number.isInteger(c.startSection) || !Number.isInteger(c.endSection) || c.startSection < 1 ||
          c.endSection > 30 || c.endSection < c.startSection) throw new Error('课表格式不完整，请重新从电脑导出');
      return { id: text(c.id) || 'course-' + index, name: text(c.name), teacher: text(c.teacher), location: text(c.location),
        weekday: c.weekday, startSection: c.startSection, endSection: c.endSection, weeks: text(c.weeks),
        activeWeeks: Array.isArray(c.activeWeeks) ? [...new Set(c.activeWeeks.filter(w => Number.isInteger(w) && w >= 1 && w <= 60))] : null };
    });
    const maxWeek = Number.isInteger(raw.maxWeek) && raw.maxWeek >= 1 && raw.maxWeek <= 60 ? raw.maxWeek : 20;
    const anchorOK = typeof raw.weekAnchorDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(raw.weekAnchorDate) &&
      Number.isFinite(dayNumber(raw.weekAnchorDate)) && addDays(raw.weekAnchorDate, 0) === raw.weekAnchorDate;
    const currentWeek = anchorOK && Number.isInteger(raw.currentWeek) && raw.currentWeek >= 1 && raw.currentWeek <= maxWeek ? raw.currentWeek : null;
    const grades = (Array.isArray(raw.grades) ? raw.grades : []).slice(0, 5000).filter(g => g && text(g.courseName)).map((g, i) => ({
      id: text(g.id) || 'grade-' + i, term: text(g.term), courseName: text(g.courseName),
      score: typeof g.score === 'number' && Number.isFinite(g.score) ? String(g.score) : text(g.score), credit: String(g.credit ?? ''), gradePoint: String(g.gradePoint ?? ''),
      courseNature: text(g.courseNature), examType: text(g.examType)
    }));
    return { schemaVersion: 1, courses, grades, term: text(raw.term), maxWeek, currentWeek,
      weekAnchorDate: currentWeek === null ? null : raw.weekAnchorDate,
      updatedAt: text(raw.updatedAt), exportedAt: text(raw.exportedAt), gradesUpdatedAt: text(raw.gradesUpdatedAt),
      gpa: text(raw.gpa), timeZone: 'Asia/Shanghai' };
  }
  function labelFor(key, today) {
    return key === today ? '今天' : key === addDays(today, 1) ? '明天' : '周' + weekdays[weekday(key) - 1];
  }
  function staleDays(data, now) {
    const stamp = Date.parse(data.updatedAt);
    return Number.isFinite(stamp) ? Math.max(0, Math.floor((now - stamp) / DAY)) : null;
  }
  function nextRefresh(data, now) {
    const key = dayKey(now), midnight = new Date(addDays(key, 1) + 'T00:00:00+08:00');
    const boundaries = coursesOn(data, key).flatMap(c => {
      const r = interval(c, key); return r ? [r.start, r.end] : [];
    }).filter(d => d > now);
    return new Date(Math.min(now.getTime() + 30 * 60000, midnight.getTime(), ...boundaries.map(d => d.getTime())) + 1000);
  }
  return { weekdays, blocks, dayKey, weekday, monday, addDays, weekAt, parseWeeks, times, occurs,
    coursesOn, interval, nextCourse, validate, labelFor, staleDays, nextRefresh };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = IMNUScheduleCore;
