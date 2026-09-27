const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Run the actual embedded browser parser against isolated synthetic responses.
// This never connects to the school or reads user data.
const source = fs.readFileSync(path.join(__dirname, '../Sources/IMNUScheduleFloat/WebSession.swift'), 'utf8');
const nativeScript = source.match(/let script = #"""\n([\s\S]*?)\n        """#/)[1];
const script = require('../windows/src/portal-snapshot');
assert.equal(script.trim(), nativeScript.replace(/^ {8}/gm, '').trim(), 'Mac and Windows portal parsers must match');
const gradePrefix = '/admin/xsd/xsdcjcx/xsdQueryXscjList';
async function run(options = {}) {
  const fields = { xnxq: options.missingTerm ? '' : 'fixture-term', xhid: 'fixture', xqdm: 'fixture' };
  const document = {
    querySelectorAll: () => [], querySelector: () => null,
    createElement: () => { throw Error('Unexpected HTML fixture'); }
  };
  const context = {
    document, AbortController, URLSearchParams, setTimeout, clearTimeout,
    DOMParser: class {
      parseFromString() {
        return {title: options.pageTitle || '', querySelector(selector) {
          const value = fields[selector.slice(1)];
          return value == null ? null : {getAttribute: () => value, textContent: value};
        }};
      }
    },
    fetch: async (url) => {
      let data, status = 200, responseURL = 'https://jwxt.imnu.edu.cn' + url;
      if (url.includes('queryKbForXsd')) {
        status = options.pageStatus || 200;
        if (options.loginRedirect) responseURL = 'https://jwxt.imnu.edu.cn/login';
        data = '';
      } else if (url.includes('sdpkkbList')) {
        data = {ret:0, data: options.emptyCourses ? [] : [{kcmc:'Fixture', xingqi:'1', djc:'1-2', zcstr:'1-19'}]};
      } else if (url.includes('/xskp?')) {
        if (options.profileFailure) throw new Error('NetworkError');
        data = {ret:0, data:{xm:'Fixture', xh:'fixture'}};
      } else if (url.includes('getXspjxfjd')) data = {ret:0, data:'3.5'};
      else if (url.includes('getCurrentPkZc')) data = {ret:0, data:[1,2,3,4,19]};
      else if (url.includes('getXlzc')) data = {ret:0, data:{xlzc:options.vacation ? 0 : 4}};
      else if (url.startsWith(gradePrefix)) {
        const category = new URL('https://fixture.invalid'+url).searchParams.get('fxbz');
        if (options.partialGrades && category !== '0') throw new Error('NetworkError');
        data = {ret:0, results:category === '0' ? [{id:'fixture', xnxq:'fixture-term', kcmc:'Fixture', zhcj:0, xf:2}] : []};
      } else throw new Error('Unknown endpoint fixture');
      return {ok:status >= 200 && status < 300, status, url:responseURL,
        text:async () => data, json:async () => data};
    }
  };
  return JSON.parse(await vm.runInNewContext(script, context));
}
(async () => {
  const full = await run();
  assert.equal(full.courses.length, 1);
  assert.equal(full.grades[0].score, '0', 'Zero scores must not be discarded');
  assert.deepEqual(full.gradeCategoriesSynced, ['主修','辅修','微专业']);
  assert.equal(full.currentWeek, 4);
  const partial = await run({partialGrades:true, profileFailure:true});
  assert.equal(partial.courses.length, 1, 'Optional outages cannot discard the timetable');
  assert.deepEqual(partial.gradeCategoriesSynced, ['主修']);
  assert.equal(partial.syncWarnings.length, 2);
  assert.match((await run({pageStatus:500})).__error, /500/);
  assert.doesNotMatch((await run({pageStatus:500})).__error, /AUTH_REQUIRED/);
  assert.equal((await run({pageStatus:401})).__error, 'AUTH_REQUIRED');
  assert.equal((await run({loginRedirect:true})).__error, 'AUTH_REQUIRED');
  assert.doesNotMatch((await run({missingTerm:true})).__error, /AUTH_REQUIRED/);
  assert.equal((await run({missingTerm:true, pageTitle:'统一身份认证'})).__error, 'AUTH_REQUIRED');
  const vacation = await run({vacation:true, emptyCourses:true});
  assert.equal(vacation.currentWeek, null);
  assert.equal(vacation.currentWeekResolved, true);
  assert.deepEqual(vacation.courses, []);
  console.log('Portal parser regression: 16 checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
