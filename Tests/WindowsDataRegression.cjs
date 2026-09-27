const assert = require('node:assert/strict');
const { teachingWeek, weekNumbers, mergeSnapshot } = require('../windows/src/schedule-data');
const sunday = new Date(2026, 8, 27, 12);
const monday = new Date(2026, 8, 28, 12);
const anchor = {currentWeek:4, currentWeekAnchorDate:sunday.toISOString(), maxWeek:19};
assert.equal(teachingWeek(anchor, sunday), 4);
assert.equal(teachingWeek(anchor, monday), 5);
assert.equal(teachingWeek({updatedAt:sunday.toISOString()}, monday), null);
assert.equal(teachingWeek({...anchor, currentWeek:19}, monday), null);
assert.equal(teachingWeek(anchor, new Date(2026, 8, 20)), null);
assert.deepEqual(weekNumbers('1-8单，10-16双'), [1,3,5,7,10,12,14,16]);
assert.deepEqual(weekNumbers('2、5、7'), [2,5,7]);
assert.deepEqual(weekNumbers('1-4周'), [1,2,3,4]);
assert.equal(weekNumbers('1-999999'), null);
const previous = {
  ...anchor, weekAnchor:4, term:'fixture-term', updatedAt:sunday.toISOString(),
  profile:{name:'Fixture', studentNumber:'fixture', gpa:'3.5'},
  grades:[{category:'主修', score:'90'}, {category:'辅修', score:'80'}],
  gradesUpdatedAt:sunday.toISOString()
};
const snapshot = {
  term:'fixture-term', maxWeek:19, profile:{}, courses:[],
  grades:[{category:'主修', score:'0'}], gradeCategoriesSynced:['主修'],
  syncWarnings:['部分成绩暂未更新']
};
const partial = mergeSnapshot(previous, snapshot, [], monday);
assert.equal(partial.currentWeek, 5);
assert.equal(partial.profile.name, 'Fixture');
assert.equal(partial.profile.gpa, '3.5');
assert.equal(partial.grades.length, 2);
assert.equal(partial.grades.find(item => item.category === '辅修').score, '80');
assert.equal(partial.grades.find(item => item.category === '主修').score, '0');
assert.equal(partial.gradesUpdatedAt, previous.gradesUpdatedAt);
assert.deepEqual(partial.courses, []);
assert.equal(partial.syncStatus, 'ready');
assert.equal(partial.syncWarnings.length, 1);
const vacation = mergeSnapshot(previous, {...snapshot, currentWeek:null, currentWeekResolved:true}, [], monday);
assert.equal(vacation.currentWeek, null);
assert.equal(vacation.weekAnchor, null);
const full = mergeSnapshot(previous, {...snapshot, grades:[], gradeCategoriesSynced:['主修','辅修','微专业']}, [], monday);
assert.deepEqual(full.grades, []);
assert.equal(full.gradesUpdatedAt, monday.toISOString());
const changed = mergeSnapshot(previous, {...snapshot, profile:{studentNumber:'other-fixture'}, grades:null}, [], monday);
assert.deepEqual(changed.grades, []);
assert.equal(changed.profile.name, '');
assert.equal(changed.currentWeek, null);
console.log('Windows data regression: 26 checks passed');
