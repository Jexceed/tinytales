import { useEffect, useRef, useState } from 'react';
import { MessageCircle, BookOpen, Image, ArrowUp, ArrowUpRight, ArrowRight, Mic, Square, Volume2, VolumeX, Leaf, LockKeyhole, Sparkles, ChevronRight, Plus, Sun, X, LoaderCircle, RotateCcw, ShieldCheck, Clock3, Sprout, Check, Cloud, Laptop, Trash2 } from 'lucide-react';
import type { Bootstrap, Message, Mode, Scene, Story, TurnResponse } from '../shared/types';
import { scenes } from '../shared/scenes';
import { api, ApiError, body } from './api';
import { Fox } from './Fox';
import { Dialog } from './Dialog';
import { ParentPanel } from './ParentPanel';
import { useVoice } from './useVoice';

interface Challenge { id: string; a: number; b: number }
const modes = [
  { id: 'chat' as const, title: '来聊聊天', subtitle: '小小日常，也很有趣', icon: MessageCircle },
  { id: 'story' as const, title: '一起编故事', subtitle: '你一句，我一句', icon: BookOpen },
  { id: 'picture' as const, title: '看图说故事', subtitle: '让想象有个小起点', icon: Image },
];
const starterIdeas: Record<Mode, string[]> = { chat: ['我今天有件开心的事', '我最喜欢恐龙', '如果我能飞就好了'], story: ['一只想飞的小恐龙', '会说话的月亮', '藏在森林里的小门'], picture: ['我先说说我看到了什么', '它们为什么会在这里？', '我想给它们编个故事'] };
const initialWelcome: Record<Mode, string> = { chat: '你好呀，我是小狐狸栗栗，一个 AI 故事伙伴。今天有什么小小的发现，想讲给我听吗？', story: '故事的小门开啦。我们可以一起编一个故事，你来决定主角，我来接着想。你想让谁来当主角呢？', picture: '一张小小的画，藏着好多故事。你先看看，你最先注意到了什么？' };

export function App() {
  const [data, setData] = useState<Bootstrap | null>(null), [mode, setMode] = useState<Mode>('chat'), [source, setSource] = useState<'demo' | 'cloud'>('demo');
  const [scene, setScene] = useState<Scene>(scenes[0]), [messages, setMessages] = useState<Message[]>([]), [text, setText] = useState('');
  const [session, setSession] = useState<{ id: string; expiresAt: number } | null>(null), [busy, setBusy] = useState(false), [starting, setStarting] = useState(false), [expired, setExpired] = useState(false);
  const [error, setError] = useState(''), [notice, setNotice] = useState(''), [parent, setParent] = useState(false), [gate, setGate] = useState<'loading' | 'initial' | 'parent' | null>('loading');
  const [challenge, setChallenge] = useState<Challenge | null>(null), [answer, setAnswer] = useState(''), [consent, setConsent] = useState(false), [gateBusy, setGateBusy] = useState(false);
  const [gateError, setGateError] = useState(''), [clock, setClock] = useState(Date.now());
  const activeSession = useRef<string | null>(null), generation = useRef(0), turnAbort = useRef<AbortController | null>(null), end = useRef<HTMLDivElement | null>(null), input = useRef<HTMLInputElement | null>(null);
  const voice = useVoice(t => { setText(t); setNotice('听到啦。可以改一改，再点箭头发送。'); input.current?.focus(); }, setError);
  async function refresh() { const next = await api<Bootstrap>('/bootstrap'); setData(next); return next; }
  async function loadChallenge() {
    const status = await api<{ challenge: Challenge }>('/status'); setChallenge(status.challenge); setAnswer('');
  }
  useEffect(() => {
    let alive = true;
    void (async () => {
      try {
        const status = await api<{ challenge: Challenge }>('/status'); if (!alive) return; setChallenge(status.challenge);
        try {
          const next = await api<Bootstrap>('/bootstrap'); if (!alive) return;
          setData(next); setGate(null); await startSession('chat', 'demo');
        } catch (e) { if (alive) { if (e instanceof ApiError && e.status === 401) setGate('initial'); else { setGate('initial'); setGateError((e as Error).message); } } }
      } catch (e) { if (alive) { setGate('initial'); setGateError('暂时没有连上本机服务。请确认服务正在运行，再重试。'); } }
    })();
    const interval = setInterval(() => setClock(Date.now()), 1000);
    return () => { alive = false; clearInterval(interval); turnAbort.current?.abort(); generation.current++; };
  }, []);
  useEffect(() => { end.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }, [messages, busy]);
  useEffect(() => { if (session && clock >= session.expiresAt && !expired) { setExpired(true); voice.cancel(); } }, [clock, session, expired]);
  async function startSession(nextMode = mode, nextSource = source, nextScene = scene, story?: Story) {
    const id = ++generation.current; turnAbort.current?.abort(); voice.cancel(); setError(''); setNotice(''); setText(''); setBusy(false); setExpired(false); setStarting(true);
    const previous = activeSession.current; activeSession.current = null; setSession(null);
    if (previous) void api(`/sessions/${previous}`, { method: 'DELETE' }).catch(() => {});
    setMode(nextMode); setSource(nextSource); setScene(nextScene); setMessages([]);
    try {
      const result = await api<{ id: string; expiresAt: number }>('/sessions', { method: 'POST', body: body({ mode: nextMode, source: nextSource, sceneId: nextScene.id, ...(story ? { storyId: story.id } : {}) }) });
      if (generation.current !== id) { void api(`/sessions/${result.id}`, { method: 'DELETE' }).catch(() => {}); return; }
      activeSession.current = result.id; setSession(result); setClock(Date.now());
      setMessages([{ id: crypto.randomUUID(), role: 'assistant', text: story ? `“${story.title}”还在这里呢。上次的故事：${story.summary} 你想从哪里接着讲？` : initialWelcome[nextMode], suggestions: story ? ['我们继续上次的故事', '我想给故事一个新转折'] : starterIdeas[nextMode] }]);
    } catch (e) { if (generation.current === id) handleError(e); } finally { if (generation.current === id) setStarting(false); }
  }
  function handleError(e: unknown) {
    if ((e as Error).name === 'AbortError') return;
    setError((e as Error).message || '小屋暂时没连上，请稍后再试。');
    if (e instanceof ApiError) {
      if (e.code === 'session_ended') { setExpired(true); voice.cancel(); }
      if (e.status === 401) { setGate('initial'); setConsent(false); void loadChallenge(); }
    }
  }
  async function send(value = text) {
    if (!value.trim() || !session || busy || starting || expired || voice.recording || voice.transcribing) return;
    voice.stopSpeaking(); setBusy(true); setError(''); setNotice(''); setText('');
    const id = generation.current, sessionId = session.id;
    const userMessageId = crypto.randomUUID();
    setMessages(m => [...m, { id: userMessageId, role: 'user', text: value.trim() }]);
    const controller = new AbortController(); turnAbort.current = controller;
    try {
      const result = await api<TurnResponse>('/turn', { method: 'POST', body: body({ sessionId, text: value.trim() }), signal: controller.signal });
      if (generation.current !== id) return;
      setMessages(m => [...m, { id: crypto.randomUUID(), role: 'assistant', text: result.reply, turnId: result.turnId, source: result.source, word: result.word, suggestions: result.suggestions }]);
      setBusy(false);
      void voice.speak(result.reply, sessionId, result.turnId, data?.settings.voice || 'device', source === 'cloud');
      void refresh().catch(() => {});
    } catch (e) {
      if (generation.current === id) {
        handleError(e); setText(value);
        setMessages(m => m.filter(v => v.id !== userMessageId));
      }
    } finally { if (generation.current === id) setBusy(false); }
  }
  async function openParent() { voice.cancel(); setGate('parent'); setChallenge(null); setGateError(''); setAnswer(''); try { await loadChallenge(); } catch(e) { setGateError((e as Error).message); } }
  async function unlock(e: React.FormEvent) {
    e.preventDefault(); if (!challenge || gateBusy) return; setGateBusy(true); setGateError('');
    try {
      if (gate === 'parent') {
        if (Number(answer) !== challenge.a + challenge.b) { setGateError('再算一算，让大人来帮忙吧。'); return; }
        await refresh(); setParent(true); setGate(null); return;
      }
      await api('/preview', { method: 'POST', body: body({ challengeId: challenge.id, answer: Number(answer), adult: true, synthetic: true }) });
      await refresh(); setGate(null); await startSession('chat', 'demo');
    } catch(e) { setGateError((e as Error).message); await loadChallenge().catch(() => {}); } finally { setGateBusy(false); }
  }
  function clearConversation() {
    generation.current++; turnAbort.current?.abort(); voice.cancel(); activeSession.current = null; setSession(null); setMessages([]); setExpired(true); setNotice('本机数据已更新，请开启一段新的对话。');
  }
  const selectedMode = modes.find(m => m.id === mode)!;
  const lastAssistant = [...messages].reverse().find(m => m.role === 'assistant');
  const word = lastAssistant?.word || (mode === 'picture' ? scene.word : null);
  const remaining = session ? Math.max(0, Math.ceil((session.expiresAt - clock) / 60000)) : 0;
  const pending = data?.memories.filter(m => m.status === 'pending').length || 0;
  const disabled = !session || busy || starting || expired || voice.transcribing;
  return <div className="app-shell">
    <aside className="sidebar">
      <a className="brand" href="/" aria-label="小小故事屋首页"><div className="brand-mark"><Fox small/></div><div><strong>小小故事屋</strong><span>TinyTales</span></div></a>
      <div className="sidebar-label">属于你的小天地</div>
      <nav className="main-nav" aria-label="故事活动">{modes.map(item => <button key={item.id} className={mode === item.id ? 'active' : ''} onClick={() => void startSession(item.id)} disabled={starting || !!gate}><item.icon size={21} strokeWidth={1.7}/><span>{item.title}<small>{item.subtitle}</small></span>{mode === item.id && <span className="nav-dot"/>}</button>)}</nav>
      <div className="sidebar-divider"/>
      <div className="sidebar-small-title"><BookOpen size={15}/>我们的故事</div>
      <div className="mini-stories">{data?.stories.length ? data.stories.slice(0,3).map(story => <button key={story.id} onClick={() => void startSession('story',story.source,scene,story)}><span className="book-spine"/>{story.title}<ChevronRight size={13}/></button>) : <p>还没讲完的故事，<br/>都会在这里等你。</p>}</div>
      <div className="sidebar-bottom"><div className="little-plant"><Sprout size={36} strokeWidth={1.2}/></div><p>慢慢说，我在听。<br/><span>每一个想法都值得被珍藏。</span></p><button onClick={() => void openParent()} className="parent-link"><LockKeyhole size={15}/>大人请进{pending > 0 && <span className="pending-dot">{pending}</span>}<ArrowUpRight size={15}/></button></div>
    </aside>
    <main className="main-shell">
      <header className="topbar"><span className="welcome-date"><Sun size={17}/>小小的声音，大大的故事</span><div className="topbar-right"><div className="source-switch" aria-label="体验来源"><button className={source === 'demo' ? 'active' : ''} disabled={starting || !!gate} onClick={() => void startSession(mode,'demo')}><Laptop size={14}/>本地演示</button><button className={source === 'cloud' ? 'active' : ''} disabled={!data?.cloudAvailable || starting || !!gate} title={!data?.cloudAvailable ? '服务端还未配置密钥' : '使用 OpenAI 云端模型'} onClick={() => void startSession(mode,'cloud')}><Cloud size={14}/>云端体验</button></div><button className="mobile-parent icon-button" aria-label="大人请进" onClick={() => void openParent()}><LockKeyhole size={20}/></button></div></header>
      <div className="research-strip"><span/>成人研究预览 · 请使用虚构内容<span className="research-end">{source === 'demo' ? '本地脚本演示 · 不调用 AI' : 'OpenAI 云端体验'}</span></div>
      <section className="page-heading"><div><div className="eyebrow">A LITTLE ROOM FOR BIG IMAGINATIONS</div><h1>{mode === 'chat' ? <>每个小小的想法，<br/>都值得被听见<span>。</span></> : mode === 'story' ? <>把一个小小的想法，<br/>变成我们的故事<span>。</span></> : <>画里有一个世界，<br/>等你来讲给我听<span>。</span></>}</h1><p>{mode === 'chat' ? '聊聊今天的趣事，或者，天马行空地想一想。' : mode === 'story' ? '没有标准结局，你的想象就是下一个冒险。' : '看看发生了什么，也想想接下来会发生什么。'}</p></div><div className="hero-art"><span className="hero-orbit"/><Fox/><span className="hello-note">今天也有好多话想听你说</span></div></section>
      <div className="content-grid">
        <section className="conversation-card" aria-label={selectedMode.title}>
          <header className="conversation-header"><div className="avatar"><Fox small/></div><div><h2>栗栗在这里<span className="status-dot"/></h2><p>{busy ? '正在认真想你说的话……' : voice.recording ? '我在听，你慢慢说' : voice.speaking ? '栗栗正在说话，随时可以停下' : '你的 AI 故事伙伴'}</p></div><div className="conversation-actions">{session && <span className="time-pill"><Clock3 size={12}/>{remaining} 分钟</span>}<button className="icon-button" aria-label="开启新对话" title="开启新对话" disabled={starting || !!gate} onClick={() => void startSession()}><RotateCcw size={17}/></button></div></header>
          {mode === 'picture' && <div className="picture-strip"><img src={scene.image} alt={scene.subtitle}/><div><span className="eyebrow">今天的想象起点</span><h3>{scene.title}</h3><p>{scene.subtitle}</p><div className="scene-dots">{scenes.map(s => <button className={s.id === scene.id ? 'active' : ''} key={s.id} aria-label={`选择图片：${s.title}`} onClick={() => void startSession('picture',source,s)} disabled={starting || !!gate}/>)}</div></div></div>}
          <div className={`message-list ${mode === 'picture' ? 'with-picture' : ''}`} aria-live="polite" aria-relevant="additions" aria-busy={busy || starting}>
            <div className="chat-day"><span/>{mode === 'story' ? '故事从这里开始' : '今天的小小对话'}<span/></div>
            {messages.map(m => <div key={m.id} className={`message ${m.role}`}><span className="message-name">{m.role === 'assistant' ? '栗栗' : '小小讲述者'}</span><div className="message-bubble">{m.text}</div>{m.role === 'assistant' && m.source && <small className="message-source">{m.source === 'demo' ? '本地演示回复' : m.source === 'safety' ? '温和提醒' : 'AI 生成'}</small>}</div>)}
            {(busy || starting) && <div className="thinking"><i/><i/><i/><span>{starting ? '打开故事小门……' : '给想法一点点时间'}</span></div>}
            {messages.length === 1 && !busy && mode !== 'picture' && <div className="starter-grid">{(lastAssistant?.suggestions || starterIdeas[mode]).map((s,i) => <button key={s} onClick={() => void send(s)} disabled={disabled}><span>{['✦','☀','☁'][i]}</span>{s}<ArrowUpRight size={15}/></button>)}</div>}
            <div ref={end}/>
          </div>
          {messages.length > 1 && !busy && !expired && <div className="suggestion-row">{lastAssistant?.suggestions?.map(s => <button key={s} onClick={() => void send(s)} disabled={disabled || voice.recording}>{s}<Plus size={12}/></button>)}</div>}
          {error && <div className="error-banner" role="alert"><span>{error}</span><button className="icon-button" aria-label="关闭提示" onClick={() => setError('')}><X size={14}/></button></div>}
          {notice && !error && <p className="inline-notice" role="status">{notice}</p>}
          <div className="composer-area">
            {expired ? <div className="rest-note"><Leaf size={21}/><div><strong>让想象休息一小会儿</strong><p>故事进度留在小屋里，准备好了再回来。</p></div><button className="secondary-button" onClick={() => void startSession()}>开启新对话<ArrowRight size={14}/></button></div> : <><div className="voice-row"><button className={`mic-button ${voice.recording ? 'recording' : ''}`} aria-label={voice.recording ? '结束录音' : '开始说话'} disabled={disabled || source !== 'cloud'} onClick={() => session && void voice.record(session.id)}>{voice.transcribing ? <LoaderCircle className="spin" size={22}/> : voice.recording ? <Square fill="currentColor" size={19}/> : <Mic size={25} strokeWidth={1.7}/>}</button><div><strong>{voice.recording ? '我在听，慢慢说' : voice.transcribing ? '正在听清你的话……' : '点一下，把想法说出来'}</strong><p>{source === 'demo' ? '本地演示请用文字；切换云端可以试语音' : voice.recording ? '再点一下结束 · 最长 45 秒' : '说完再点一下，确认后发送'}</p></div>{(voice.speaking || voice.preparing) && <button className="stop-speech" onClick={voice.stopSpeaking}><VolumeX size={15}/>{voice.preparing ? '取消朗读' : '停一下'}</button>}</div>
            <form className="text-composer" onSubmit={e => { e.preventDefault(); void send(); }}><input ref={input} aria-label="想说的话" value={text} maxLength={600} onChange={e => setText(e.target.value)} placeholder={mode === 'story' ? '让故事从你的一个想法开始……' : '也可以把想法写在这里……'} disabled={disabled || voice.recording}/><button aria-label="发送" disabled={disabled || !text.trim() || voice.recording}><ArrowUp size={20}/></button></form></>}
            <div className="composer-footnote"><span><ShieldCheck size={12}/>栗栗是 AI，重要的事记得和大人聊聊</span><button disabled={!lastAssistant || !session || busy} onClick={() => session && lastAssistant && void voice.speak(lastAssistant.text,session.id,undefined,'device',false)} aria-label="用本机声音再听一遍"><Volume2 size={13}/>再听一遍</button></div>
          </div>
        </section>
        <aside className="right-column">
          <section className="shelf-card"><div className="card-label"><BookOpen size={17}/><h2>故事小书架</h2><span>{data?.stories.length || '0'}</span></div><p className="card-subtitle">还没讲完的冒险，下次接着来。</p>
            {data?.stories.length ? <div className="shelf-stories">{data.stories.slice(0,3).map((s,i) => <div className="shelf-story" key={s.id}><button onClick={() => void startSession('story',s.source,scene,s)}><div className={`book-cover cover-${i%3}`}><Sparkles size={17}/></div><div><strong>{s.title}</strong><p>{s.summary.slice(0,28)}…</p><small>{s.source === 'demo' ? '本地演示' : '云端故事'} · 接着讲<ArrowRight size={11}/></small></div></button><button className="delete-story" aria-label={`删除故事：${s.title}`} onClick={() => { void api(`/stories/${s.id}`, { method: 'DELETE' }).then(() => { if (mode === 'story') clearConversation(); return refresh(); }).catch(handleError); }}><Trash2 size={13}/></button></div>)}</div> : <div className="empty-shelf"><div className="book-illustration"><span/><span/><span/></div><p>第一篇故事，等你来开启</p></div>}
            <button className="text-link" onClick={() => void startSession('story')} disabled={starting || !!gate}><Plus size={14}/>开启一个新故事<ArrowUpRight size={14}/></button>
          </section>
          <section className="picture-invite"><div className="card-label"><Image size={17}/><h2>{mode === 'picture' ? '换一张，换个想象' : '一张图，好多种想象'}</h2></div><button onClick={() => void startSession('picture',source,scenes[(scenes.findIndex(s => s.id === scene.id)+(mode === 'picture' ? 1:0))%scenes.length])} disabled={starting || !!gate}><img src={mode === 'picture' ? scenes[(scenes.findIndex(s => s.id === scene.id)+1)%scenes.length].image : scenes[0].image} alt="森林里的小伙伴，一起分享小小的善意"/><div><span>{mode === 'picture' ? '去发现另一个故事' : '一把伞的旅行'}</span><ArrowUpRight size={18}/></div></button></section>
          {word ? <section className="word-card"><span className="eyebrow">故事里遇见的小词</span><span className="pinyin">{word.pinyin}</span><strong>{word.hanzi}</strong><p>{word.english}</p><Leaf size={36} strokeWidth={1} className="word-leaf"/></section> : <section className="gentle-card"><Leaf size={24} strokeWidth={1.2}/><h3>表达，没有标准答案。</h3><p>停顿、想象、天马行空，<br/>都是故事生长的样子。</p><span>TAKE YOUR TIME, LITTLE ONE.</span></section>}
        </aside>
      </div>
      <footer className="page-footer"><span>Little voices, big stories.</span><span>给想象一点空间，给成长一点时间 <Leaf size={12}/></span></footer>
    </main>
    {gate && <Dialog title={gate === 'parent' ? '请大人来开这扇门' : '欢迎来到小小故事屋'} onClose={gate === 'parent' ? () => setGate(null) : undefined}>
      <div className="gate-fox"><Fox small/></div><p className="gate-heading">{gate === 'parent' ? '这里有一些交给大人的小设置。' : '先请大人来试一试。'}</p>
      {gate !== 'parent' && <p className="gate-description">这是一个早期研究原型。请由成人使用虚构内容体验聊天、讲故事和语音，暂不让孩子直接使用或输入真实儿童数据。</p>}
      <form onSubmit={e => void unlock(e)}>
        <label className="challenge-label" htmlFor="adult-answer">大人验证{challenge ? <span>{challenge.a} + {challenge.b} = ?</span> : <span>正在准备……</span>}</label><input id="adult-answer" className="answer-input" inputMode="numeric" autoComplete="off" placeholder="填写答案" value={answer} onChange={e => setAnswer(e.target.value.replace(/\D/g,''))} maxLength={3} required/>
        {gate !== 'parent' && <label className="consent"><input type="checkbox" checked={consent} onChange={e => setConsent(e.target.checked)}/><span>我是成人，仅使用虚构内容研究体验，不上传真实儿童语音及个人信息。</span></label>}
        {gateError && <p className="error-text" role="alert">{gateError}</p>}
        <button className="primary-button gate-submit" disabled={!challenge || !answer || gateBusy || (gate !== 'parent' && !consent)}>{gateBusy ? <LoaderCircle size={17} className="spin"/> : <>{gate === 'parent' ? '进入大人的小角落' : '打开故事小门'}<ArrowRight size={17}/></>}</button>
        {!challenge && <button type="button" className="text-link" onClick={() => void loadChallenge().catch(e => setGateError((e as Error).message))}>重新连接</button>}
      </form><p className="gate-footnote"><LockKeyhole size={12}/>本机预览 · 算术验证不能替代账号认证</p>
    </Dialog>}
    {parent && data && <ParentPanel data={data} refresh={async () => { await refresh(); }} onClose={() => setParent(false)} onDataCleared={clearConversation}/>}
  </div>;
}
