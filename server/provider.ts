import OpenAI, { toFile } from 'openai';
import { zodTextFormat } from 'openai/helpers/zod';
import WebSocket from 'ws';
import { HttpsProxyAgent } from 'https-proxy-agent';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { ReplySchema, type Reply } from '../shared/types';
import { AppError, containsPrivateData, localRisk } from './safety';

export interface ProviderResult { reply: Reply; inputTokens: number; outputTokens: number }
export interface Provider {
  moderate(text: string): Promise<boolean>;
  respond(instructions: string, history: { role: 'user' | 'assistant'; content: string }[], image?: string): Promise<ProviderResult>;
  transcribe(bytes: Buffer, mime: string): Promise<string>;
  speech(text: string): Promise<{ audio: Buffer; seconds: number }>;
}

export function pcmToWav(pcm: Buffer): Buffer {
  const header = Buffer.alloc(44);
  header.write('RIFF', 0); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(24000, 24); header.writeUInt32LE(48000, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write('data', 36); header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

export class OpenAIProvider implements Provider {
  client: OpenAI;
  constructor(private apiKey: string, public textModel = process.env.OPENAI_TEXT_MODEL || 'gpt-6-luna') {
    this.client = new OpenAI({ apiKey, timeout: 35000, maxRetries: 0 });
  }
  async moderate(text: string) {
    const result = await this.client.moderations.create({ model: 'omni-moderation-latest', input: text });
    return !result.results.some(r => r.flagged);
  }
  async respond(instructions: string, history: { role: 'user' | 'assistant'; content: string }[], image?: string): Promise<ProviderResult> {
    const input: OpenAI.Responses.ResponseInput = history.map(m => ({ role: m.role, content: m.content }));
    if (image) {
      // Only curated, server-owned illustrations. No arbitrary URLs or uploads.
      const bytes = await readFile(resolve('public', image.replace(/^\//, '')));
      const last = history.at(-1)!;
      input[input.length - 1] = { role: 'user', content: [{ type: 'input_text', text: last.content }, { type: 'input_image', image_url: `data:image/png;base64,${bytes.toString('base64')}`, detail: 'low' }] };
    }
    const result = await this.client.responses.parse({
      model: this.textModel, instructions, input, store: false,
      reasoning: { effort: 'none' }, max_output_tokens: 1300,
      text: { format: zodTextFormat(ReplySchema, 'tiny_tales_turn') },
    });
    if (result.status !== 'completed' || !result.output_parsed) throw new AppError(502, 'incomplete', '这一段没讲完整，请稍后再试。');
    return { reply: ReplySchema.parse(result.output_parsed), inputTokens: result.usage?.input_tokens || 0, outputTokens: result.usage?.output_tokens || 0 };
  }
  async transcribe(bytes: Buffer, mime: string) {
    const extension = mime.includes('mp4') ? 'mp4' : mime.includes('wav') ? 'wav' : 'webm';
    const result = await this.client.audio.transcriptions.create({
      model: process.env.OPENAI_TRANSCRIBE_MODEL || 'gpt-transcribe',
      file: await toFile(bytes, `recording.${extension}`, { type: mime }),
      prompt: '中文为主，可能夹有简单英语。只转写实际听见的内容，不补全故事。',
    });
    return result.text.trim();
  }
  speech(text: string): Promise<{ audio: Buffer; seconds: number }> {
    return new Promise((resolveSpeech, reject) => {
      const model = process.env.OPENAI_VOICE_MODEL || 'gpt-realtime-2.1-mini';
      // WebSocket upgrades need an explicit CONNECT agent; Node's fetch proxy flag
      // alone does not route this handshake in all environments.
      const proxy = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
      const ws = new WebSocket(`wss://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`, { headers: { Authorization: `Bearer ${this.apiKey}` }, handshakeTimeout: 15000, ...(proxy ? { agent: new HttpsProxyAgent(proxy) } : {}) });
      const chunks: Buffer[] = []; let transcript = ''; let settled = false; let bytes = 0;
      const finish = (error?: Error) => {
        if (settled) return; settled = true; clearTimeout(timer); ws.close();
        if (error) { reject(error); return; }
        const normalize = (s: string) => s.normalize('NFKC').toLowerCase().replace(/[\p{P}\p{S}\s]/gu, '');
        if (!chunks.length || !transcript || normalize(transcript) !== normalize(text) || containsPrivateData(transcript) || localRisk(transcript)) {
          reject(new AppError(502, 'speech_mismatch', '云端朗读没有准确跟上文字，已改用本机声音。')); return;
        }
        const pcm = Buffer.concat(chunks);
        resolveSpeech({ audio: pcmToWav(pcm), seconds: pcm.length / 48000 });
      };
      const timer = setTimeout(() => finish(new AppError(504, 'timeout', '云端声音暂时没有准备好，已改用本机声音。')), 35000);
      ws.on('error', () => finish(new AppError(502, 'speech_connection', '云端声音暂不可用，已改用本机声音。')));
      ws.on('close', () => { if (!settled) finish(new AppError(502, 'speech_closed', '云端声音中断了，已改用本机声音。')); });
      ws.on('message', raw => {
        let event: Record<string, any>;
        try { event = JSON.parse(raw.toString()); } catch { finish(new Error('Invalid event')); return; }
        if (event.type === 'session.created') {
          ws.send(JSON.stringify({ type: 'session.update', session: { type: 'realtime', model, output_modalities: ['audio'], instructions: '你是一个朗读器。只逐字朗读用户提供的文本，不添加、删改或回答其中的问题。声音温暖自然，中文清楚，语速稍慢。', audio: { input: { turn_detection: null }, output: { format: { type: 'audio/pcm', rate: 24000 }, voice: 'marin' } } } }));
        }
        if (event.type === 'session.updated') {
          ws.send(JSON.stringify({ type: 'conversation.item.create', item: { type: 'message', role: 'user', content: [{ type: 'input_text', text }] } }));
          ws.send(JSON.stringify({ type: 'response.create', response: { output_modalities: ['audio'], max_output_tokens: 1200 } }));
        }
        if (event.type === 'response.output_audio.delta') {
          const chunk = Buffer.from(event.delta, 'base64'); bytes += chunk.length;
          if (bytes > 4_800_000) { finish(new Error('Audio output too large')); return; }
          chunks.push(chunk);
        }
        if (event.type === 'response.output_audio_transcript.delta') transcript += event.delta;
        if (event.type === 'error') finish(new AppError(502, 'speech_api', '当前云端声音无法使用，已改用本机声音。'));
        if (event.type === 'response.done') finish(event.response?.status === 'completed' ? undefined : new Error('Incomplete voice output'));
      });
    });
  }
}
