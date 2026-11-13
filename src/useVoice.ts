import { useCallback, useEffect, useRef, useState } from 'react';
import { api, body } from './api';
import type { Settings } from '../shared/types';

export function useVoice(onTranscript: (text: string) => void, onError: (text: string) => void) {
  const [recording, setRecording] = useState(false); const [transcribing, setTranscribing] = useState(false); const [speaking, setSpeaking] = useState(false); const [preparing, setPreparing] = useState(false);
  const recorder = useRef<MediaRecorder | null>(null), stream = useRef<MediaStream | null>(null), timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const player = useRef<HTMLAudioElement | null>(null), objectUrl = useRef<string | null>(null), abort = useRef<AbortController | null>(null);
  const generation = useRef(0), narration = useRef(0);
  const transcriptCallback = useRef(onTranscript), errorCallback = useRef(onError);
  transcriptCallback.current = onTranscript; errorCallback.current = onError;
  const stopSpeaking = useCallback(() => {
    narration.current++; abort.current?.abort(); abort.current = null;
    if ('speechSynthesis' in window) speechSynthesis.cancel();
    if (player.current) { player.current.pause(); player.current = null; }
    if (objectUrl.current) { URL.revokeObjectURL(objectUrl.current); objectUrl.current = null; }
    setSpeaking(false); setPreparing(false);
  }, []);
  const cancel = useCallback(() => {
    generation.current++; stopSpeaking();
    if (timer.current) clearTimeout(timer.current);
    if (recorder.current?.state === 'recording') recorder.current.stop();
    stream.current?.getTracks().forEach(t => t.stop()); stream.current = null; recorder.current = null;
    setRecording(false); setTranscribing(false);
  }, [stopSpeaking]);
  useEffect(() => () => cancel(), [cancel]);
  const deviceSpeak = (text: string, id: number) => {
    if (!('speechSynthesis' in window)) { errorCallback.current('当前设备没有可用的朗读声音，可以安静地读文字。'); return; }
    const speech = new SpeechSynthesisUtterance(text); speech.lang = 'zh-CN'; speech.rate = 0.88;
    const voice = speechSynthesis.getVoices().find(v => v.lang.startsWith('zh')); if (voice) speech.voice = voice;
    speech.onend = () => { if (narration.current === id) setSpeaking(false); };
    speech.onerror = e => { if (narration.current === id) { setSpeaking(false); if (e.error !== 'interrupted' && e.error !== 'canceled') errorCallback.current('本机声音暂不可用，可以继续读文字。'); } };
    setSpeaking(true); speechSynthesis.speak(speech);
  };
  async function speak(text: string, sessionId: string, turnId: string | undefined, voice: Settings['voice'], cloud: boolean) {
    stopSpeaking(); if (voice === 'off') return;
    const id = narration.current;
    if (voice === 'cloud' && cloud && turnId) {
      const controller = new AbortController(); abort.current = controller; setPreparing(true);
      try {
        const res = await fetch('/api/speech', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body({ sessionId, turnId }), signal: controller.signal });
        if (!res.ok) { const d = await res.json(); throw new Error(d.error); }
        const blob = await res.blob(); if (narration.current !== id) return;
        const url = URL.createObjectURL(blob); objectUrl.current = url;
        const audio = new Audio(url); player.current = audio;
        audio.onended = () => { if (narration.current === id) { setSpeaking(false); URL.revokeObjectURL(url); objectUrl.current = null; } };
        await audio.play(); if (narration.current !== id) { audio.pause(); return; } setSpeaking(true); setPreparing(false); return;
      } catch (e) {
        if (narration.current !== id || (e as Error).name === 'AbortError') return;
        errorCallback.current(`${(e as Error).message} 正在尝试本机声音。`);
      } finally { if (narration.current === id) setPreparing(false); }
    }
    if (narration.current === id) deviceSpeak(text, id);
  }
  async function record(sessionId: string) {
    if (recording) { if (recorder.current?.state === 'recording') recorder.current.stop(); return; }
    if (transcribing) return;
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') { errorCallback.current('当前浏览器不支持录音，请使用最新版 Chrome、Safari 或 Edge，也可以用文字。'); return; }
    stopSpeaking(); const id = ++generation.current;
    try {
      const media = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true }, video: false });
      if (generation.current !== id) { media.getTracks().forEach(t => t.stop()); return; }
      stream.current = media;
      const mime = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/webm'].find(v => MediaRecorder.isTypeSupported(v));
      const current = new MediaRecorder(media, mime ? { mimeType: mime } : undefined); recorder.current = current;
      const chunks: Blob[] = [];
      current.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
      current.onerror = () => { cancel(); errorCallback.current('录音暂时中断了，检查麦克风后再试试。'); };
      current.onstop = async () => {
        if (timer.current) clearTimeout(timer.current);
        media.getTracks().forEach(t => t.stop()); if (generation.current !== id) return;
        setRecording(false); setTranscribing(true);
        try {
          const blob = new Blob(chunks, { type: current.mimeType || 'audio/webm' });
          if (blob.size > 2 * 1024 * 1024) throw new Error('刚才这段有点长，试着说一句短的。');
          const result = await api<{ text: string; notice?: string }>('/transcribe', { method: 'POST', headers: { 'Content-Type': blob.type, 'X-Session-Id': sessionId }, body: blob });
          if (generation.current !== id) return;
          if (result.notice) errorCallback.current(result.notice); else transcriptCallback.current(result.text);
        } catch (e) { if (generation.current === id) errorCallback.current((e as Error).message); }
        finally {
          chunks.length = 0;
          current.ondataavailable = null; current.onstop = null; current.onerror = null;
          if (recorder.current === current) recorder.current = null;
          if (stream.current === media) stream.current = null;
          if (generation.current === id) setTranscribing(false);
        }
      };
      current.start(); setRecording(true); timer.current = setTimeout(() => { if (current.state === 'recording') current.stop(); }, 45000);
    } catch (e) { if (generation.current === id) { cancel(); errorCallback.current((e as Error).name === 'NotAllowedError' ? '麦克风还没有打开。可以在浏览器地址栏允许使用，或者先用文字聊聊。' : '没有找到可用的麦克风，可以先用文字聊聊。'); } }
  }
  return { recording, transcribing, speaking, preparing, speak, record, stopSpeaking, cancel };
}
