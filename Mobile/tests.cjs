'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const Core = require('./core.js');
const now = new Date('2026-09-28T09:00:00+08:00');
const demo = {
  schemaVersion:1,term:'演示学期',currentWeek:1,weekAnchorDate:'2026-09-07',maxWeek:19,
  updatedAt:'2026-09-27T05:00:00Z',exportedAt:'2026-09-27T06:00:00Z',gradesUpdatedAt:'2026-09-27T05:00:00Z',gpa:'3.8',
  courses:[
    {id:'a',name:'示例 · 数字系统设计基础与实验',teacher:'演示教师',location:'示例教学楼 A-305',weekday:1,startSection:1,endSection:2,weeks:'1-19周',activeWeeks:null},
    {id:'b',name:'示例 · 大学物理',teacher:'演示教师',location:'示例理学楼 204',weekday:1,startSection:3,endSection:4,weeks:'1-19周',activeWeeks:null},
    {id:'c',name:'示例 · 项目实践',teacher:'演示教师',location:'示例实验楼 302',weekday:2,startSection:5,endSection:6,weeks:'2-18周(双)',activeWeeks:null},
    {id:'d',name:'示例 · 单周课程',teacher:'演示教师',location:'示例教学楼 210',weekday:1,startSection:7,endSection:8,weeks:'1-19周(单)',activeWeeks:null}
  ],
  grades:[{id:'g',term:'演示学期',courseName:'示例 · 已完成课程',score:0,credit:'2',gradePoint:'0',courseNature:'必修',examType:'正常考试'}]
};
let checks = 0;
function check(name, work){work();checks++;console.log('PASS '+name);}
check('学校日期不随旅行时区改变',()=>assert.equal(Core.dayKey(new Date('2026-09-27T16:01:00Z')),'2026-09-28'));
check('教学周在周一边界推进',()=>{assert.equal(Core.weekAt(demo,'2026-09-27'),3);assert.equal(Core.weekAt(demo,'2026-09-28'),4);});
check('学期结束和未确认周次不猜测',()=>{assert.equal(Core.weekAt(demo,'2027-05-03'),null);assert.equal(Core.weekAt({...demo,currentWeek:null},'2026-09-28'),null);});
check('单双周与中文分隔符',()=>assert.deepEqual(Core.parseWeeks('1-5单周，2-6双周;9'),[1,2,3,4,5,6,9]));
check('只选择当天有效课程',()=>assert.deepEqual(Core.coursesOn(demo,'2026-09-28').map(c=>c.id),['a','b']));
check('当前课程持续显示至下课',()=>assert.equal(Core.nextCourse(demo,now).course.id,'a'));
check('下课时刻选择下一节',()=>assert.equal(Core.nextCourse(demo,new Date('2026-09-28T10:00:00+08:00')).course.id,'b'));
check('第二天课程按该日教学周筛选',()=>assert.equal(Core.nextCourse(demo,new Date('2026-09-28T12:01:00+08:00')).course.id,'c'));
check('没有课与未知周次区分',()=>{assert.deepEqual(Core.coursesOn({...demo,currentWeek:null},'2026-09-28'),[]);assert.equal(Core.nextCourse({...demo,currentWeek:null},now),null);});
check('上课、下课与午夜申请刷新',()=>{assert.equal(Core.nextRefresh(demo,now).toISOString(),'2026-09-28T01:30:01.000Z');assert.equal(Core.nextRefresh(demo,new Date('2026-09-28T23:55:00+08:00')).toISOString(),'2026-09-28T16:00:01.000Z');});
check('零分保留，非法日期锚点清除',()=>{assert.equal(Core.validate(demo).grades[0].score,'0');assert.equal(Core.validate({...demo,weekAnchorDate:'2026-02-31'}).currentWeek,null);});
check('合法空课表和错误输入',()=>{assert.equal(Core.validate({...demo,courses:[]}).courses.length,0);assert.throws(()=>Core.validate({schemaVersion:1,courses:[{}]}));assert.throws(()=>Core.validate({...demo,schemaVersion:2}));});

// This exercises documented API calls with a strict surface; not an iPhone runtime.
class TextNode{
  constructor(value){this.value=String(value);}
  centerAlignText(){this.align='center';} rightAlignText(){this.align='right';}
}
class Stack{
  constructor(){this.children=[];this.direction='row';}
  addText(value){const t=new TextNode(value);this.children.push(t);return t;}
  addImage(image){const n={image};this.children.push(n);return n;}
  addSpacer(size){this.children.push({spacer:size??null});}
  addStack(){const s=new Stack();this.children.push(s);return s;}
  setPadding(...v){this.padding=v;}
  layoutVertically(){this.direction='column';} centerAlignContent(){this.align='center';}
}
class ListWidget extends Stack{}
class Color{
  constructor(hex){assert.match(hex,/^#[a-f\d]{6}$/i);this.hex=hex;}
  static dynamic(light,dark){return {light:light.hex,dark:dark.hex};}
  static white(){return new Color('#ffffff');}
}
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const script=fs.readFileSync(path.join(__dirname,'widget.js'),'utf8')
  .replace('/* __MOBILE_CORE__ */',fs.readFileSync(path.join(__dirname,'core.js'),'utf8'))
  .replace('/* __MOBILE_DATA__ */',JSON.stringify(demo))
  .replace('/* __MOBILE_BACKGROUND__ */','null')
  .replace('/* __MOBILE_HTML__ */',JSON.stringify(fs.readFileSync(path.join(__dirname,'panel.html'),'utf8')));
check('交付脚本支持顶层 await',()=>new AsyncFunction(script));
let completed=false,currentWidget=null;
const files=new Map();
const manager={documentsDirectory:()=>'/documents',joinPath:(a,b)=>a+'/'+b,fileExists:p=>files.has(p),createDirectory:p=>files.set(p,''),writeString:(p,s)=>files.set(p,s),readString:p=>files.get(p),isFileDownloaded:()=>true};
const sandbox={Date,Set,Math,Number,JSON,Error,Array,String,Promise,console,Color,ListWidget,
  Font:{systemFont:n=>({size:n}),mediumSystemFont:n=>({size:n,weight:'medium'}),boldSystemFont:n=>({size:n,weight:'bold'})},
  Point:class{constructor(x,y){this.x=x;this.y=y;}},Size:class{constructor(width,height){this.width=width;this.height=height;}},
  Device:{screenSize:()=>({width:430,height:932})},Data:{fromBase64String:s=>Buffer.from(s,'base64')},Image:{fromData:d=>({bytes:d})},
  LinearGradient:class{},SFSymbol:{named:()=>({image:'sf-symbol'})},FileManager:{local:()=>manager,iCloud:()=>({...manager,fileExists:()=>false})},
  URLScheme:{forRunningScript:()=> 'scriptable:///run/IMNU'},
  Script:{setWidget:w=>currentWidget=w,complete:()=>completed=true},config:{runsInWidget:true,widgetFamily:'medium'},args:{widgetParameter:''}};
const context=vm.createContext(sandbox);
function allText(node){return [node.value||'',...(node.children||[]).flatMap(allText)].filter(Boolean).join(' ');}
async function main(){
  let previewHTML='';
  await vm.runInContext('(async()=>{'+script.replace('await main();','globalThis.build=buildWidget; globalThis.run=main;')+'})()',context);
  for(const family of ['small','medium','large','accessoryInline','accessoryCircular','accessoryRectangular']){
    const widget=sandbox.build(demo,family,now,'');assert.ok(allText(widget).includes(family==='accessoryCircular'?'08:20':'示例'));assert.ok(widget.url.startsWith('scriptable:'));assert.ok(widget.refreshAfterDate>now);checks++;console.log('PASS Scriptable API 模拟 · '+family);
  }
  assert.ok(allText(sandbox.build(null,'medium',now)).includes('导入课表'));
  assert.ok(!allText(sandbox.build(null,'medium',now)).includes('今天 0'));
  assert.ok(allText(sandbox.build(demo,'small',now,'tomorrow')).includes('项目实践'));checks++;console.log('PASS 空数据提示与明天参数');
  await sandbox.run();assert.ok(completed&&currentWidget);assert.ok(files.get('/documents/IMNU-widget/schedule.json'));checks++;console.log('PASS 小组件执行路径与离线缓存');
  const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'imnu-mobile-test-'));
  try{
    const cache={...demo,profile:{name:'PRIVATE_NAME_TEST',studentNumber:'PRIVATE_ID_TEST',gpa:'3.8'},cookies:'PRIVATE_COOKIE_TEST',password:'PRIVATE_PASSWORD_TEST',
      updatedAt:(Date.parse('2026-09-27T05:00:00Z')-Date.parse('2001-01-01T00:00:00Z'))/1000,currentWeekAnchorDate:(Date.parse('2026-09-07T06:00:00Z')-Date.parse('2001-01-01T00:00:00Z'))/1000};
    const cachePath=path.join(temporary,'cache.json'),output=path.join(temporary,'private');fs.writeFileSync(cachePath,JSON.stringify(cache));
    const run=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--cache',cachePath,'--output',output],{encoding:'utf8'});assert.equal(run.status,0,run.stderr);
    const exported=JSON.parse(fs.readFileSync(path.join(output,'内师大课表.json'),'utf8'));assert.equal(exported.weekAnchorDate,'2026-09-07');assert.equal(exported.updatedAt,'2026-09-27T05:00:00Z');assert.equal(Core.validate(exported).grades[0].score,'0');
    for(const file of fs.readdirSync(output)){const body=fs.readFileSync(path.join(output,file),'utf8');assert.ok(!/PRIVATE_(NAME|ID|COOKIE|PASSWORD)_TEST/.test(body),file);}
    const manifest=JSON.parse(fs.readFileSync(path.join(output,'内师大课表.scriptable'),'utf8'));assert.equal(manifest.always_run_in_app,false);assert.equal(manifest.name,'内师大课表');new AsyncFunction(manifest.script);
    // Exercise the *Python-built artifact* in app mode. Testing the JS template
    // alone misses Python str.replace changing the quoted runtime marker too.
    let presented=false,loadedHTML='';
    const artifactFiles=new Map();
    const artifactManager={...manager,fileExists:p=>artifactFiles.has(p),createDirectory:p=>artifactFiles.set(p,''),writeString:(p,s)=>artifactFiles.set(p,s),readString:p=>artifactFiles.get(p)};
    class AppWebView {
      async loadHTML(html){loadedHTML=html;assert.ok(!html.includes('/* __MOBILE_DATA__ */'),'打包后运行未将课表填入页面');}
      async present(){presented=true;}
    }
    const appSandbox={...sandbox,FileManager:{local:()=>artifactManager,iCloud:()=>({...artifactManager,fileExists:()=>false})},
      WebView:AppWebView,config:{runsInWidget:false,runsInApp:true},args:{fileURLs:[]},Script:{complete(){}}};
    await vm.runInNewContext('(async()=>{'+manifest.script+'})()',appSandbox);
    assert.ok(presented);assert.ok(loadedHTML.includes('const IMNUScheduleCore'));previewHTML=loadedHTML;checks++;console.log('PASS 打包后的手机 App 启动路径');
    const quotedCache={...cache,courses:[{...cache.courses[0],name:"示例 · Teacher's course $& $` $'"}]};
    fs.writeFileSync(cachePath,JSON.stringify(quotedCache));
    const quoteOutput=path.join(temporary,'quoted');
    const quotedRun=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--cache',cachePath,'--output',quoteOutput],{encoding:'utf8'});assert.equal(quotedRun.status,0,quotedRun.stderr);
    const quoted=JSON.parse(fs.readFileSync(path.join(quoteOutput,'内师大课表.scriptable'),'utf8'));new AsyncFunction(quoted.script);
    artifactFiles.clear();await vm.runInNewContext('(async()=>{'+quoted.script+'})()',appSandbox);
    assert.ok(!loadedHTML.includes('/* __MOBILE_DATA__ */'));assert.ok(loadedHTML.includes('示例 · Teacher'));checks++;console.log('PASS 课程名中的引号和替换特殊字符');
    fs.writeFileSync(cachePath,JSON.stringify(cache));
    const refresh=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--cache',cachePath,'--output',output,'--refresh'],{encoding:'utf8'});assert.equal(refresh.status,0,refresh.stderr);
    for(const line of fs.readFileSync(path.join(output,'SHA256SUMS.txt'),'utf8').trim().split('\n')){const [sum,file]=line.split('  ');assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(output,file))).digest('hex'),sum);}
    const refuse=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--generic','--output',output,'--refresh'],{encoding:'utf8'});assert.notEqual(refuse.status,0);
    assert.ok((fs.statSync(path.join(output,'内师大课表.json')).mode&0o777)===0o600);checks++;console.log('PASS Swift 日期转换、凭据过滤与交付脚本');
    const imagePath=path.join(temporary,'background.png');
    // A valid tiny PNG exercises transport; image rendering is verified on iPhone.
    const imageBytes=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK10AAAAASUVORK5CYII=','base64');
    fs.writeFileSync(imagePath,imageBytes);
    const themedOutput=path.join(temporary,'themed');
    const themed=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--cache',cachePath,'--background',imagePath,'--output',themedOutput],{encoding:'utf8'});assert.equal(themed.status,0,themed.stderr);
    const themedScript=JSON.parse(fs.readFileSync(path.join(themedOutput,'内师大课表.scriptable'),'utf8')).script;
    const themedSandbox={...sandbox};await vm.runInNewContext('(async()=>{'+themedScript.replace('await main();','globalThis.build=buildWidget;')+'})()',themedSandbox);
    for (const width of [320,375,393,430]) {
      themedSandbox.Device={screenSize:()=>({width,height:932})};
      const w=themedSandbox.build(demo,'medium',now);assert.deepEqual(w.backgroundImage.bytes,imageBytes);assert.ok(allText(w).includes('08:20'));assert.ok(allText(w).includes('示例'));
    }
    assert.equal(themedSandbox.build(demo,'accessoryInline',now).backgroundImage,undefined);
    checks++;console.log('PASS 横幅嵌入、四种手机宽度与锁屏隔离');
    fs.writeFileSync(imagePath,'not an image');
    const rejected=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--generic','--background',imagePath,'--output',path.join(temporary,'invalid')],{encoding:'utf8'});assert.notEqual(rejected.status,0);assert.ok(!fs.existsSync(path.join(temporary,'invalid')));checks++;console.log('PASS 无效背景不会留下半成品');
    const publicOutput=path.join(temporary,'public');const generic=spawnSync('python3',[path.join(__dirname,'export-mobile.py'),'--generic','--output',publicOutput],{encoding:'utf8'});assert.equal(generic.status,0,generic.stderr);assert.ok(!fs.existsSync(path.join(publicOutput,'内师大课表.json')));checks++;console.log('PASS 公开包无个人课表');
  }finally{fs.rmSync(temporary,{recursive:true,force:true});}
  if(process.argv.includes('--preview')){
    const output=path.resolve(__dirname,'../release-out/mobile-smoke');fs.mkdirSync(output,{recursive:true});
    const preview=previewHTML.replace('let now = new Date(),','let now = new Date("2026-09-28T09:00:00+08:00"),');
    fs.writeFileSync(path.join(output,'phone.html'),preview);fs.writeFileSync(path.join(output,'fixture.json'),JSON.stringify(demo));
  }
  console.log(checks+' mobile checks passed; synthetic / API simulation only.');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
