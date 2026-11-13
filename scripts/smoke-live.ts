import assert from 'node:assert/strict';
import { mkdir, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { Store } from '../server/store';
import { createApp } from '../server/app';
import { OpenAIProvider } from '../server/provider';
import { safeApiError } from '../server/safety';
import type { TurnResponse } from '../shared/types';

if (!process.env.OPENAI_API_KEY) throw new Error('OPENAI_API_KEY is required in the server environment.');
const dir = await mkdtemp(join(tmpdir(),'tinytales-live-'));
const store = new Store(join(dir,'smoke.sqlite'));
const provider = new OpenAIProvider(process.env.OPENAI_API_KEY);
const server = createApp(store,provider,{dailyLimit:15}).listen(0,'127.0.0.1');await once(server,'listening');
const base=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;
let cookie='';
const results: Record<string,unknown>[]=[];
async function json(path:string, method='GET', data?:unknown) {
  const r=await fetch(base+'/api'+path,{method,headers:{Cookie:cookie,...(data?{'Content-Type':'application/json'}:{})},...(data?{body:JSON.stringify(data)}:{})});
  const value=await r.json();if(!r.ok)throw Object.assign(new Error(`${path}: ${value.code}: ${value.error}`),{status:r.status});
  return {value,response:r};
}
async function session(mode='chat',storyId?:string){const {value}=await json('/sessions','POST',{mode,source:'cloud',sceneId:'rain',...(storyId?{storyId}:{})});return value.id as string;}
async function turn(id:string,text:string,label:string) {
  const start=performance.now();const {value}=await json('/turn','POST',{sessionId:id,text});const r=value as TurnResponse;
  assert.ok(r.reply);assert.equal(r.source,'cloud');results.push({test:label,elapsedMs:Math.round(performance.now()-start),reply:r.reply,word:r.word,story:r.story,memoryCandidates:r.memoryCandidates});console.log(`${label}: passed (${results.at(-1)!.elapsedMs} ms)`);return r;
}
await mkdir('artifacts',{recursive:true});
try {
  const c=(await json('/status')).value.challenge;
  const access=await json('/preview','POST',{challengeId:c.id,answer:c.a+c.b,adult:true,synthetic:true});cookie=access.response.headers.get('set-cookie')!.split(';')[0];
  const chat=await session();await turn(chat,'我最喜欢恐龙，特别是脖子长长的那种。','Chinese chat and memory proposal');
  let memory=store.memories().find(v=>v.kind==='interest');
  assert.ok(memory,'Expected a stable-interest candidate');
  await json('/memories/'+memory.id,'PATCH',{text:memory.text,status:'approved'});
  assert.equal(store.memories().find(v=>v.id===memory!.id)?.status,'approved');
  const fresh=await session();await turn(fresh,'我们以前聊过我喜欢什么吗？','Approved memory in a new conversation');
  const story=await session('story');const opening=await turn(story,'编一个小恐龙在森林里发现一扇会发光的门的故事，我想决定门后面有什么。','Interactive story checkpoint');assert.ok(opening.storyId);assert.ok(store.story(opening.storyId));
  const continuation=await session('story',opening.storyId!);await turn(continuation,'我们接着上次的故事。我想让门后面是一片星星花园。','Story continuation in a fresh session');
  const picture=await session('picture');await turn(picture,'我看到小兔子和小刺猬，小兔子把雨伞拿给它一起躲雨。','Actual-image picture expression');
  const english=await session();await turn(english,'雨伞用英语怎么说呀？','English word in context');
  const usageBefore=store.usage().cloudOperations;const sensitive=(await json('/turn','POST',{sessionId:english,text:'我的学校是虚构测试幼儿园'})).value;assert.equal(sensitive.source,'safety');assert.equal(store.usage().cloudOperations,usageBefore);results.push({test:'Sensitive text intercepted locally',passed:true});
  const phrase='小恐龙在花园里找到一颗会发光的种子。';
  const speechStart=performance.now();const audio=await provider.speech(phrase);await writeFile('artifacts/synthetic-voice.wav',audio.audio);
  results.push({test:'Current Realtime model reads approved text',elapsedMs:Math.round(performance.now()-speechStart),audioSeconds:audio.seconds});console.log('Realtime speech generation: passed');
  const transcribeStart=performance.now();const r=await fetch(base+'/api/transcribe',{method:'POST',headers:{Cookie:cookie,'Content-Type':'audio/wav','X-Session-Id':english},body:new Uint8Array(audio.audio)});const transcript=await r.json();assert.equal(r.status,200);assert.ok(transcript.text.includes('恐龙'));assert.ok(transcript.text.includes('种子'));
  results.push({test:'Synthetic Chinese audio transcription',elapsedMs:Math.round(performance.now()-transcribeStart),text:transcript.text});console.log('Synthetic audio transcription: passed');
  await json('/data','DELETE');assert.equal(store.stories().length,0);assert.equal(store.memories().length,0);assert.ok(store.usage().cloudOperations>0);results.push({test:'Data deletion preserves only request accounting',passed:true});
  const usage=store.usage();
  await writeFile('artifacts/live-smoke.json',JSON.stringify({date:'2026-11-10',adultSyntheticOnly:true,models:{text:provider.textModel,transcription:process.env.OPENAI_TRANSCRIBE_MODEL||'gpt-transcribe',voice:process.env.OPENAI_VOICE_MODEL||'gpt-realtime-2.1-mini'},results,usage,success:true},null,2));
  console.log('Live smoke passed; synthetic evidence is in artifacts/.');
} catch(error) {
  // The normal application intentionally redacts upstream payloads. Retain only safe metadata here too.
  const message=(error as Error).message;
  const safe=/^\/(?:turn|sessions|preview|status|transcribe)/.test(message)?message:safeApiError(error).message;
  await writeFile('artifacts/live-smoke.json',JSON.stringify({date:'2026-11-10',adultSyntheticOnly:true,success:false,results,error:safe,usage:store.usage()},null,2));
  console.error('Live smoke failed:',safe);process.exitCode=1;
} finally { server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));store.close();await rm(dir,{recursive:true,force:true}); }
