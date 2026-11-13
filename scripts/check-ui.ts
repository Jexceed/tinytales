import { chromium } from 'playwright-core';
import { mkdir, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import express from 'express';
import { createServer } from 'vite';
import { createApp } from '../server/app';
import { Store } from '../server/store';

// A separate fixture database and ephemeral port: this command cannot clear the user's data.
const fixtureDir = await mkdtemp(join(tmpdir(),'tinytales-ui-'));
const store = new Store(join(fixtureDir,'ui.sqlite'));
const app = createApp(store);
app.use('/scenes',express.static(resolve('public/scenes')));
const vite = await createServer({configFile:false,server:{middlewareMode:true,hmr:false},appType:'spa'});
app.use(vite.middlewares);
const server = app.listen(0,'127.0.0.1'); await once(server,'listening');
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
await mkdir('artifacts',{recursive:true});
const errors: string[] = [];
const context = await browser.newContext({viewport:{width:1440,height:1100}, reducedMotion:'reduce'});
const page = await context.newPage(); page.on('pageerror',e=>errors.push(e.message));
try {
  await page.goto(base,{waitUntil:'networkidle'});
  const gate=page.getByRole('dialog',{name:'欢迎来到小小故事屋'});await gate.waitFor();
  const arithmetic=await gate.locator('.challenge-label span').textContent();const values=arithmetic!.match(/\d+/g)!.map(Number);
  await gate.getByLabel('大人验证').fill(String(values[0]+values[1]));await gate.getByRole('checkbox').check();await gate.getByRole('button',{name:'打开故事小门'}).click();await gate.waitFor({state:'hidden'});
  await page.getByText('你的 AI 故事伙伴',{exact:true}).waitFor();
  await page.screenshot({path:'artifacts/ui-desktop.png',fullPage:true});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Desktop overflow');
  // Exercise a visible demo interaction, then approve its extracted candidate via the parent UI.
  await page.getByRole('textbox',{name:'想说的话'}).fill('我喜欢小企鹅');await page.getByRole('button',{name:'发送',exact:true}).click();await page.getByText('本地演示回复',{exact:true}).waitFor();
  await page.getByRole('button',{name:/大人请进/}).first().click();
  const parentGate=page.getByRole('dialog',{name:'请大人来开这扇门'});await parentGate.locator('.challenge-label span').filter({hasText:/\d+ \+ \d+/}).waitFor();const challenge=(await parentGate.locator('.challenge-label span').textContent())!.match(/\d+/g)!.map(Number);
  await parentGate.getByLabel('大人验证').fill(String(challenge[0]+challenge[1]));await parentGate.getByRole('button',{name:'进入大人的小角落'}).click();
  const parent=page.getByRole('dialog',{name:'大人的小角落'});await parent.waitFor();await parent.getByRole('button',{name:'记住',exact:true}).first().click();await parent.getByText('已确认 · 下次聊天可以用到',{exact:true}).waitFor();
  await page.screenshot({path:'artifacts/ui-parent.png',fullPage:true});
  await parent.getByRole('button',{name:'关闭',exact:true}).click();
  await page.getByRole('button',{name:/一起编故事 你一句/}).click();await page.getByRole('textbox',{name:'想说的话'}).fill('一只想飞的小恐龙');await page.getByRole('button',{name:'发送',exact:true}).click();await page.getByText('本地演示回复',{exact:true}).waitFor();
  await page.getByRole('button',{name:/看图说故事 让想象/}).click();await page.locator('.picture-strip img').waitFor();
  assert.ok(await page.locator('.picture-strip img').evaluate((el:HTMLImageElement)=>el.complete&&el.naturalWidth===1000));
  await page.screenshot({path:'artifacts/ui-picture.png',fullPage:true});
  await page.getByRole('button',{name:'选择图片：月亮来做客'}).click();await page.locator('.picture-strip h3').getByText('月亮来做客').waitFor();
  await page.setViewportSize({width:390,height:844});await page.screenshot({path:'artifacts/ui-mobile.png',fullPage:true});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Mobile overflow');
  // Use the same-cookie local API only to remove synthetic test records, never real user data.
  // This script must run against a dedicated fresh preview database (documented in README).
  await context.request.delete(new URL('/api/data',page.url()).href);
  await context.request.patch(new URL('/api/settings',page.url()).href,{data:{sessionMinutes:10,english:false,voice:'device',memoryEnabled:true}});
  await page.reload({waitUntil:'networkidle'});await page.getByText('你的 AI 故事伙伴',{exact:true}).waitFor();
  await page.getByRole('button',{name:/来聊聊天/}).first().click();
  // Read a DOM hit box and enforce that the voice target remains tappable on a small screen.
  const mic=await page.getByRole('button',{name:'开始说话',exact:true}).boundingBox();assert.ok(mic&&mic.width>=44&&mic.height>=44);
  assert.deepEqual(errors,[]);
  await writeFile('artifacts/ui-check.json',JSON.stringify({success:true,checks:['adult gate','offline text interaction','parent memory approval','story checkpoint','actual picture load','scene switch','390px layout','44px microphone target','no uncaught browser errors'],screenshots:['ui-desktop.png','ui-parent.png','ui-picture.png','ui-mobile.png']},null,2));
  console.log('UI checks passed; desktop, picture, parent and mobile screenshots saved.');
} finally { await browser.close(); server.closeAllConnections(); await new Promise<void>(r=>server.close(()=>r())); await vite.close(); store.close(); await rm(fixtureDir,{recursive:true,force:true}); }
