'use strict';

// Calendar and cache rules are independent of Electron and never read user files.
function teachingWeek(cached, now = new Date()) {
  const anchor = Number(cached.weekAnchor ?? cached.currentWeek);
  const date = new Date(cached.currentWeekAnchorDate || cached.updatedAt || '');
  const limit = Math.max(Number(cached.maxWeek) || 19, 1);
  if (!Number.isInteger(anchor) || anchor < 1 || !Number.isFinite(date.getTime())) return null;
  const monday = value => {
    const day = Date.UTC(value.getFullYear(), value.getMonth(), value.getDate()) / 86400000;
    return day - (value.getDay() + 6) % 7;
  };
  const elapsed = (monday(now) - monday(date)) / 7;
  const week = anchor + elapsed;
  return elapsed >= 0 && week >= 1 && week <= limit ? week : null;
}

function weekNumbers(value) {
  const output = new Set();
  for (const part of String(value || '').split(/[,，、;；]/)) {
    const values = (part.match(/\d+/g) || []).map(Number);
    if (!values.length) continue;
    const lower = Math.min(values[0], values[1] ?? values[0]);
    const upper = Math.max(values[0], values[1] ?? values[0]);
    if (lower < 1 || upper > 60) continue;
    for (let week = lower; week <= upper; week++) {
      if (part.includes('单') && week % 2 !== 1) continue;
      if (part.includes('双') && week % 2 !== 0) continue;
      output.add(week);
    }
  }
  return output.size ? [...output].sort((a, b) => a - b) : null;
}

function mergeSnapshot(previous, snapshot, courses, now = new Date()) {
  const stamp = now.toISOString();
  const incoming = snapshot.profile || {};
  const changedAccount = previous.profile?.studentNumber && incoming.studentNumber &&
    previous.profile.studentNumber !== incoming.studentNumber;
  const profile = changedAccount ? {} : previous.profile || {};
  const sameTerm = !changedAccount && previous.term === snapshot.term;
  const next = {
    ...previous, courses, term: snapshot.term,
    maxWeek: Math.max(Number(snapshot.maxWeek) || 19, 1),
    profile: Object.fromEntries(['name', 'studentNumber', 'gpa'].map(key => [key, incoming[key] || profile[key] || ''])),
    grades: changedAccount ? [] : previous.grades || [],
    gradesUpdatedAt: changedAccount ? null : previous.gradesUpdatedAt,
    syncWarnings: snapshot.syncWarnings || [],
    updatedAt: stamp, syncStatus: 'ready',
    message: snapshot.syncWarnings?.length ? '课表已同步，部分信息使用缓存' : '已同步'
  };
  const official = Number(snapshot.currentWeek);
  if (Number.isInteger(official) && official > 0 && official <= next.maxWeek) {
    next.weekAnchor = official;
    next.currentWeekAnchorDate = stamp;
  } else if (snapshot.currentWeekResolved === true || !sameTerm) {
    next.weekAnchor = null;
    next.currentWeekAnchorDate = null;
  } else {
    next.weekAnchor = previous.weekAnchor ?? previous.currentWeek;
    next.currentWeekAnchorDate = previous.currentWeekAnchorDate || previous.updatedAt;
  }
  // Supplying an explicit null anchor must never fall back to yesterday's week.
  next.currentWeek = next.weekAnchor;
  next.currentWeek = teachingWeek(next, now);
  if (Array.isArray(snapshot.grades)) {
    const categories = snapshot.gradeCategoriesSynced;
    next.grades = Array.isArray(categories)
      ? next.grades.filter(record => !categories.includes(record.category)).concat(snapshot.grades)
      : snapshot.grades;
    if (!Array.isArray(categories) || ['主修', '辅修', '微专业'].every(category => categories.includes(category))) {
      next.gradesUpdatedAt = stamp;
    }
  }
  return next;
}

module.exports = { teachingWeek, weekNumbers, mergeSnapshot };
