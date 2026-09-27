'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, label) {
  const deadline = Date.now() + 10000;
  while (!(await check())) {
    if (Date.now() >= deadline) throw new Error('Timed out: ' + label);
    await pause(80);
  }
}

// The published Windows x64 executable runs this with isolated synthetic data.
// No school requests, existing sessions or OS startup preferences are touched.
exports.run = async ({app, ballWindow, panelWindow, ensurePortalWindow, smokeOutput, hideBallAtEdge, setFixture}) => {
  const report = {passed:false, version:app.getVersion(), arch:process.arch, checks:[]};
  const capture = async (window, name) => fs.writeFileSync(path.join(smokeOutput, name + '.png'), (await window.webContents.capturePage()).toPNG());
  const inspect = (window, script) => window.webContents.executeJavaScript(script, true);
  const record = label => report.checks.push(label);
  try {
    const portal = ensurePortalWindow(false);
    const windows = [ballWindow, panelWindow, portal];
    for (const window of windows) {
      await until(() => !window.webContents.isLoading() && window.webContents.getURL(), 'renderer load');
      const preferences = window.webContents.getLastWebPreferences();
      assert.equal(preferences.nodeIntegration, false);
      assert.equal(preferences.contextIsolation, true);
      assert.equal(preferences.sandbox, true);
      assert.equal(await inspect(window, 'typeof require'), 'undefined');
    }
    assert.equal(portal.webContents.getURL(), 'about:blank');
    assert.match(app.getPath('userData'), /isolated-user-data$/);
    record('sandboxed local UI and isolated persistent session');
    await until(() => inspect(ballWindow, 'Boolean(document.querySelector(".floating-ball"))'), 'initial ball');
    await until(() => inspect(panelWindow, 'Boolean(document.querySelector(".schedule-panel"))'), 'initial panel');
    setFixture({term:'2026-2027-1', maxWeek:19, currentWeek:4, currentWeekResolved:true,
      profile:{name:'演示同学', studentNumber:'DEMO', gpa:'3.50'}, syncWarnings:[],
      courses:[{name:'演示课程 · 数学', teacher:'演示教师', location:'演示教室', weekday:(new Date().getDay()+6)%7+1, section:'3-4', weeks:'1-19周'}],
      grades:[{id:'demo', term:'2026-2027-1', courseName:'演示课程 · 物理', score:'0', credit:'2', gradePoint:'0', category:'主修'}],
      gradeCategoriesSynced:['主修','辅修','微专业']});
    await until(() => inspect(ballWindow, 'Boolean(document.querySelector(".floating-ball"))'), 'ball');
    await inspect(ballWindow, 'document.querySelector(".floating-ball").click()');
    await until(() => panelWindow.isVisible(), 'single-click opening');
    await until(() => inspect(panelWindow, 'document.body.textContent.includes("演示课程 · 数学")'), 'timetable fixture');
    assert.equal(await inspect(panelWindow, 'document.querySelectorAll(".tab").length'), 5);
    record('one click opens timetable with course times');
    await capture(panelWindow, 'timetable');
    await inspect(panelWindow, 'Array.from(document.querySelectorAll(".tab")).find(button => button.textContent === "成绩查询").click()');
    await until(() => inspect(panelWindow, 'Boolean(document.querySelector(".grade-score"))'), 'grades');
    assert.equal(await inspect(panelWindow, 'document.querySelector(".grade-score").textContent'), '0');
    record('grade view preserves zero scores and semester filters');
    await capture(panelWindow, 'grades');
    await inspect(panelWindow, 'document.querySelector(".close-button").click()');
    await until(() => !panelWindow.isVisible(), 'close panel');
    assert.equal(ballWindow.isVisible(), true);
    hideBallAtEdge('right');
    await until(() => inspect(ballWindow, 'Boolean(document.querySelector(".edge-handle"))'), 'edge handle');
    await inspect(ballWindow, 'document.querySelector(".edge-handle").dispatchEvent(new MouseEvent("mouseenter"))');
    await pause(200);
    assert.equal(ballWindow.getBounds().width, 12, 'Hover must keep the click target under the cursor');
    await inspect(ballWindow, 'document.querySelector(".edge-handle").click()');
    await until(() => panelWindow.isVisible(), 'single edge click opening');
    assert.equal(ballWindow.getBounds().width, 60);
    record('hover preserves the edge click target; one click opens the panel; closing keeps the ball');
    assert.equal(await inspect(panelWindow, 'getComputedStyle(document.querySelector(".primary-button")).backgroundColor'), 'rgb(125, 103, 175)');
    await inspect(panelWindow, 'document.querySelector(".profile-button").click()');
    await until(() => portal.isVisible(), 'profile homepage shortcut');
    record('gray-purple palette and profile shortcut');
    report.passed = true;
  } catch (error) {
    report.error = error.stack || String(error);
    try { await capture(panelWindow, 'failure'); } catch {}
  } finally {
    fs.writeFileSync(path.join(smokeOutput, 'smoke.json'), JSON.stringify(report, null, 2));
    app.isQuitting = true;
    app.exit(report.passed ? 0 : 1);
  }
};
