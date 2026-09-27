/* Own offline UI only, with synthetic data. No logged-in browser profile. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const runtime = process.env.IMNU_PLAYWRIGHT || 'playwright';
const { chromium } = require(runtime);
async function main(){
  const browser = await chromium.launch({channel:'chrome',headless:true});
  const output=path.resolve(__dirname,'../release-out/mobile-smoke');
  const page=await browser.newPage({viewport:{width:393,height:852},deviceScaleFactor:2,isMobile:true,hasTouch:true,colorScheme:'dark'});
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  try{
    await page.goto('file://'+output+'/phone.html');await page.waitForTimeout(250);
    assert.ok(await page.getByText('正在上课',{exact:true}).isVisible());
    await page.screenshot({path:output+'/phone-dark.png'});
    await page.getByRole('tab',{name:'明天'}).click();assert.ok(await page.getByRole('heading',{name:'示例 · 项目实践'}).isVisible());
    await page.getByRole('tab',{name:'本周'}).click();assert.equal(await page.locator('.day').count(),7);
    await page.getByRole('tab',{name:'学期'}).click();await page.getByPlaceholder('课程、教室或教师').fill('项目');assert.equal(await page.locator('.term-course').count(),1);
    await page.getByRole('tab',{name:'成绩'}).click();assert.equal(await page.locator('.score').textContent(),'0');
    await page.waitForTimeout(250);await page.screenshot({path:output+'/phone-grades.png'});
    await page.emulateMedia({colorScheme:'light'});await page.getByRole('tab',{name:'今天'}).click();await page.waitForTimeout(250);await page.screenshot({path:output+'/phone-light.png'});
    for(const width of [320,375,393,430]){
      await page.setViewportSize({width,height:852});
      for(const tab of ['今天','明天','本周','学期','成绩']){
        await page.getByRole('tab',{name:tab}).click();
        assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),width+' / '+tab+' overflow');
      }
    }
    assert.deepEqual(errors,[]);
    fs.writeFileSync(output+'/browser-check.json',JSON.stringify({passed:true,fixture:'synthetic',testedWidths:[320,375,393,430],checks:['5 view navigation','week groups','course search','zero grade','dark and light','no horizontal overflow'],iPhoneRuntime:false},null,2));
    console.log('PASS offline phone UI: 5 views, search, zero grade, light/dark, 4 widths; browser simulation only.');
  }finally{await browser.close();}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
