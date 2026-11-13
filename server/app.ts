import express from 'express';
import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { ModeSchema, MemoryKindSchema, ReplySchema, type Mode, type Reply, type Story } from '../shared/types';
import { scenes } from '../shared/scenes';
import { Store } from './store';
import { instructions } from './prompt';
import { demoReply } from './demo';
import { AppError, safeApiError, containsPrivateData, localRisk, PRIVATE_REPLY, SAFE_REPLY, acceptableMemory } from './safety';
import type { Provider } from './provider';

interface Session { id: string; owner: string; mode: Mode; source: 'demo' | 'cloud'; sceneId?: string; storyId?: string; history: { role: 'user' | 'assistant'; content: string }[]; expires: number; busy: boolean; turns: Map<string, { text: string; spoken: boolean }> }
const safeReply = (text: string): Reply => ({ reply: text, suggestions: ['来讲一个温暖的故事', '聊聊喜欢的小动物'], memoryCandidates: [], story: null, word: null, observation: null });

export function createApp(store: Store, provider?: Provider, options: { dailyLimit?: number; model?: string; now?: () => number } = {}) {
  const app = express();
  const now = options.now || Date.now;
  const dailyLimit = options.dailyLimit ?? Number(process.env.DAILY_CLOUD_TURNS || 60);
  const adults = new Map<string, number>(); const challenges = new Map<string, { answer: number; expires: number }>();
  const sessions = new Map<string, Session>(); const locks = new Set<string>();
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    res.set({ 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Permissions-Policy': 'camera=(), microphone=(self)' });
    const host = req.headers.host || '';
    if (!/^(localhost|127\.0\.0\.1)(:\d+)?$/.test(host)) { res.status(403).json({ error: '仅支持本机访问。', code: 'local_only' }); return; }
    if ((req.headers.origin && req.headers.origin !== `http://${host}`) || req.headers['sec-fetch-site'] === 'cross-site') { res.status(403).json({ error: '请从本机小屋页面访问。', code: 'origin' }); return; }
    next();
  });
  app.use(express.json({ limit: '16kb' }));
  const prune = () => {
    for (const [id, expiry] of adults) if (expiry < now()) adults.delete(id);
    for (const [id, c] of challenges) if (c.expires < now()) challenges.delete(id);
    for (const [id, s] of sessions) if (s.expires < now() || !adults.has(s.owner)) sessions.delete(id);
  };
  app.get('/api/status', (_req, res) => {
    prune(); if (challenges.size > 50) challenges.clear();
    const id = randomUUID(), a = randomInt(12, 29), b = randomInt(13, 25);
    challenges.set(id, { answer: a + b, expires: now() + 300000 });
    res.json({ cloudAvailable: !!provider, challenge: { id, a, b }, preview: 'adult-synthetic-only' });
  });
  app.post('/api/preview', (req, res) => {
    prune(); const input = z.object({ challengeId: z.string(), answer: z.number(), adult: z.literal(true), synthetic: z.literal(true) }).parse(req.body);
    const challenge = challenges.get(input.challengeId); challenges.delete(input.challengeId);
    if (!challenge || challenge.expires < now() || challenge.answer !== input.answer) throw new AppError(403, 'adult_gate', '请让大人算好这道题，再来开启体验。');
    if (adults.size >= 20) throw new AppError(429, 'sessions', '打开的体验页面有点多，请稍后再试。');
    const token = randomBytes(32).toString('hex'); adults.set(token, now() + 3600000);
    res.cookie('tt_preview', token, { httpOnly: true, sameSite: 'strict', maxAge: 3600000, path: '/' });
    res.json({ ok: true });
  });
  app.use('/api', (req, _res, next) => {
    prune(); const token = req.headers.cookie?.split(';').map(s => s.trim()).find(s => s.startsWith('tt_preview='))?.slice(11);
    if (!token || !adults.has(token)) { next(new AppError(401, 'preview_required', '请先由大人开启研究体验。')); return; }
    resOwner(req, token); next();
  });
  app.get('/api/bootstrap', (_req, res) => res.json({ memories: store.memories(), stories: store.stories(), settings: store.settings(), usage: store.usage(), cloudAvailable: !!provider, model: options.model || process.env.OPENAI_TEXT_MODEL || 'gpt-6-luna', dailyLimit, scenes, observations: store.observations() }));
  app.patch('/api/settings', (req, res) => {
    const v = z.object({ sessionMinutes: z.union([z.literal(5), z.literal(10), z.literal(15)]), english: z.boolean(), voice: z.enum(['device','cloud','off']), memoryEnabled: z.boolean() }).strict().parse(req.body);
    if (v.memoryEnabled !== store.settings().memoryEnabled) sessions.clear();
    store.setSettings(v); res.json(v);
  });
  app.post('/api/sessions', (req, res) => {
    prune();
    const v = z.object({ mode: ModeSchema, source: z.enum(['demo','cloud']), sceneId: z.enum(['rain','moon','seed']).optional(), storyId: z.string().uuid().optional() }).strict().parse(req.body);
    if (sessions.size >= 30) throw new AppError(429, 'session_limit', '请先结束其他对话。');
    if (v.source === 'cloud' && !provider) throw new AppError(503, 'unconfigured', '云端还没有连接，可以先体验本地演示。');
    const story = v.storyId ? store.story(v.storyId) : undefined;
    if (v.storyId && !story) throw new AppError(404, 'story_missing', '这个故事已经收进别处了，来开一个新故事吧。');
    if (story && story.source !== v.source) throw new AppError(400, 'source_mismatch', '请在故事原来的体验模式中继续。');
    const id = randomUUID();
    sessions.set(id, { id, owner: getOwner(req), mode: v.mode, source: v.source, sceneId: v.sceneId, storyId: story?.id, history: [], expires: now() + store.settings().sessionMinutes * 60000, busy: false, turns: new Map() });
    res.json({ id, expiresAt: sessions.get(id)!.expires, story: story || null });
  });
  const getSession = (req: express.Request, id: string) => {
    const s = sessions.get(id);
    if (!s || s.owner !== getOwner(req) || s.expires <= now()) throw new AppError(410, 'session_ended', '我们休息一会儿吧。故事进度已经留在小屋里了。');
    return s;
  };
  const reserveCloud = () => {
    if (store.usage().cloudOperations >= dailyLimit) throw new AppError(429, 'daily_limit', '今天的云端体验次数用完啦。可以休息一下，或者切换本地演示。');
    // Reserve before awaiting the network. Failed requests count conservatively.
    store.addUsage({ cloudOperations: 1 });
  };
  app.delete('/api/sessions/:id', (req, res) => { const s = getSession(req, req.params.id); sessions.delete(s.id); res.json({ ok: true }); });
  app.post('/api/turn', async (req, res) => {
    const v = z.object({ sessionId: z.string().uuid(), text: z.string().trim().min(1).max(600) }).strict().parse(req.body);
    const s = getSession(req, v.sessionId);
    if (s.busy) throw new AppError(409, 'busy', '我还在想上一句话，请稍等一下。');
    if (s.history.length >= 40) throw new AppError(429, 'turn_limit', '今天这一段聊了好多啦。休息一下，再开启新的对话吧。');
    s.busy = true; const start = now();
    try {
      let result: Reply; let source: 'demo' | 'cloud' | 'safety' = s.source;
      if (containsPrivateData(v.text)) { result = safeReply(PRIVATE_REPLY); source = 'safety'; }
      else if (localRisk(v.text)) { result = safeReply(SAFE_REPLY); source = 'safety'; }
      else if (s.source === 'demo') result = demoReply(v.text, s.mode, s.sceneId, s.storyId ? store.story(s.storyId) : undefined);
      else {
        reserveCloud();
        if (!await provider!.moderate(v.text)) { result = safeReply(SAFE_REPLY); source = 'safety'; }
        else {
          const scene = s.mode === 'picture' ? scenes.find(v => v.id === s.sceneId) || scenes[0] : undefined;
          const data = await provider!.respond(instructions(s.mode, store.settings(), store.memories(), s.storyId ? store.story(s.storyId) : undefined), [...s.history.slice(-12), { role: 'user', content: v.text }], scene?.image);
          store.addUsage({ turns: 1, inputTokens: data.inputTokens, outputTokens: data.outputTokens });
          const parsed = ReplySchema.parse(data.reply);
          if (parsed.reply.length > 450 || containsPrivateData(parsed.reply) || localRisk(parsed.reply) || !await provider!.moderate(JSON.stringify(parsed))) { result = safeReply(SAFE_REPLY); source = 'safety'; }
          else result = parsed;
        }
      }
      // Deletion/expiry while the provider is responding must not restore data.
      if (!sessions.has(s.id) || s.expires <= now()) throw new AppError(410, 'session_ended', '这一段体验已经结束，来休息一下吧。');
      if (source !== 'safety') {
        s.history.push({ role: 'user', content: v.text }, { role: 'assistant', content: result.reply });
        if (store.settings().memoryEnabled) result.memoryCandidates.forEach(c => store.addCandidate(c));
        if (s.mode === 'story' && result.story) {
          s.storyId ||= randomUUID();
          store.saveStory({ ...result.story, id: s.storyId, source: s.source, updatedAt: new Date(now()).toISOString() });
        }
        if (s.mode === 'picture' && result.observation && store.settings().memoryEnabled) store.observe(result.observation);
      }
      const turnId = randomUUID(); s.turns.set(turnId, { text: result.reply, spoken: false });
      res.json({ ...result, storyId: s.storyId || null, turnId, source, latencyMs: now() - start });
    } finally { s.busy = false; }
  });
  app.post('/api/transcribe', express.raw({ type: ['audio/webm','audio/mp4','audio/wav','audio/ogg'], limit: '2mb' }), async (req, res) => {
    const id = z.string().uuid().parse(req.headers['x-session-id']); const s = getSession(req, id);
    if (s.source !== 'cloud' || !provider) throw new AppError(400, 'cloud_only', '语音识别需要云端研究体验，本地演示可以用文字。');
    if (!Buffer.isBuffer(req.body) || req.body.length < 300) throw new AppError(400, 'recording_empty', '刚才没有听清，换个安静的地方再试试。');
    const lock = `transcribe:${s.id}`; if (locks.has(lock) || s.busy) throw new AppError(409, 'busy', '上一段声音还在处理中。');
    reserveCloud(); locks.add(lock);
    try {
      const text = await provider.transcribe(req.body, (req.headers['content-type'] || 'audio/webm').split(';')[0]);
      store.addUsage({ transcriptionSeconds: 45 }); // Conservative upper-bound reservation, not measured billing.
      if (!sessions.has(s.id) || s.expires <= now()) throw new AppError(410, 'session_ended', '这一段体验已经结束。');
      if (!text || text.length > 600) throw new AppError(400, 'transcript_length', '刚才这段有点长或太轻，再说一句短的试试。');
      if (containsPrivateData(text)) { res.json({ text: '', notice: PRIVATE_REPLY }); return; }
      if (localRisk(text) || !await provider.moderate(text)) { res.json({ text: '', notice: SAFE_REPLY }); return; }
      res.json({ text });
    } finally { locks.delete(lock); }
  });
  app.post('/api/speech', async (req, res) => {
    const v = z.object({ sessionId: z.string().uuid(), turnId: z.string().uuid() }).strict().parse(req.body);
    const s = getSession(req, v.sessionId), turn = s.turns.get(v.turnId);
    if (!turn || s.source !== 'cloud' || !provider) throw new AppError(400, 'speech_turn', '这句话可以用本机声音朗读。');
    if (turn.spoken) throw new AppError(409, 'already_spoken', '这句话已经朗读过了。');
    reserveCloud(); turn.spoken = true;
    const audio = await provider.speech(turn.text); store.addUsage({ speechSeconds: audio.seconds });
    if (!sessions.has(s.id) || s.expires <= now()) throw new AppError(410, 'session_ended', '这一段体验已经结束。');
    res.type('audio/wav').send(audio.audio);
  });
  app.post('/api/memories', (req, res) => {
    const v = z.object({ kind: MemoryKindSchema, text: z.string().trim().min(1).max(100) }).strict().parse(req.body);
    if (!acceptableMemory(v.text)) throw new AppError(400, 'memory_private', '请只填写非隐私的兴趣或学过的词，不填写身份信息和能力标签。');
    store.addCandidate({ ...v, evidence: '由大人手动补充' }); res.json({ ok: true });
  });
  app.patch('/api/memories/:id', (req, res) => {
    const v = z.object({ text: z.string().trim().min(1).max(100), status: z.enum(['pending','approved']) }).strict().parse(req.body);
    if (!acceptableMemory(v.text)) throw new AppError(400, 'memory_private', '这条记忆包含不适合保存的信息，请修改。');
    store.updateMemory(req.params.id, v.text, v.status); sessions.clear(); res.json({ ok: true });
  });
  app.delete('/api/memories/:id', (req, res) => { store.deleteMemory(req.params.id); sessions.clear(); res.json({ ok: true }); });
  app.delete('/api/stories/:id', (req, res) => { store.deleteStory(req.params.id); for (const [id, s] of sessions) if (s.storyId === req.params.id) sessions.delete(id); res.json({ ok: true }); });
  app.get('/api/export', (_req, res) => res.json({ version: 1, exportedAt: new Date(now()).toISOString(), memories: store.memories(), stories: store.stories(), settings: store.settings(), observations: store.observations() }));
  app.delete('/api/data', (_req, res) => { sessions.clear(); locks.clear(); store.clear(); res.json({ ok: true }); });
  app.use('/api', (_req, _res, next) => next(new AppError(404, 'not_found', '没有找到这个功能。')));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    if (error instanceof z.ZodError) { res.status(400).json({ error: '这次提交的内容不完整，请检查后再试。', code: 'validation' }); return; }
    if ((error as { type?: string }).type === 'entity.too.large') { res.status(413).json({ error: '这段内容太长了，请缩短后再试。', code: 'too_large' }); return; }
    if (error instanceof SyntaxError) { res.status(400).json({ error: '内容格式不正确，请重新提交。', code: 'validation' }); return; }
    const safe = safeApiError(error); res.status(safe.status).json({ error: safe.message, code: safe.code });
    // Deliberately no request bodies, transcripts, raw upstream errors, or keys in logs.
  });
  return app;
}

function resOwner(req: express.Request, token: string) { (req as express.Request & { previewOwner: string }).previewOwner = token; }
function getOwner(req: express.Request) { return (req as express.Request & { previewOwner: string }).previewOwner; }
