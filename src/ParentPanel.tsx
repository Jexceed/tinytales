import { useState } from 'react';
import { Check, Trash2, Pencil, Download, Leaf, ShieldCheck, SlidersHorizontal, BookOpen, Plus, CircleCheck } from 'lucide-react';
import { api, body } from './api';
import { Dialog } from './Dialog';
import type { Bootstrap, Memory, Settings } from '../shared/types';

export function ParentPanel({ data, refresh, onClose, onDataCleared }: { data: Bootstrap; refresh: () => Promise<void>; onClose: () => void; onDataCleared: () => void }) {
  const [tab, setTab] = useState<'memory' | 'settings' | 'data'>('memory');
  const [error, setError] = useState(''); const [working, setWorking] = useState(false); const [confirmDelete, setConfirmDelete] = useState(false);
  const [newMemory, setNewMemory] = useState('');
  async function action(fn: () => Promise<unknown>) {
    if (working) return; setWorking(true); setError('');
    try { await fn(); await refresh(); } catch (e) { setError((e as Error).message); } finally { setWorking(false); }
  }
  async function setting(patch: Partial<Settings>) { await action(async () => { await api('/settings', { method: 'PATCH', body: body({ ...data.settings, ...patch }) }); if (patch.memoryEnabled !== undefined) onDataCleared(); }); }
  async function exportData() {
    await action(async () => {
      const value = await api('/export'); const url = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], { type: 'application/json' }));
      const link = document.createElement('a'); link.href = url; link.download = 'tinytales-local-data.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    });
  }
  return <Dialog title="大人的小角落" wide onClose={onClose}>
    <p className="dialog-intro">把值得记住的留下，让每次开口都轻松一点。</p>
    <nav className="parent-tabs" aria-label="家长管理"><button onClick={() => setTab('memory')} className={tab === 'memory' ? 'active' : ''}><Leaf size={17}/>记忆小花园{data.memories.some(m => m.status === 'pending') && <i/>}</button><button className={tab === 'settings' ? 'active' : ''} onClick={() => setTab('settings')}><SlidersHorizontal size={17}/>体验设置</button><button className={tab === 'data' ? 'active' : ''} onClick={() => setTab('data')}><ShieldCheck size={17}/>数据与边界</button></nav>
    <div className="parent-content" aria-busy={working}>
      {error && <p className="error-banner" role="alert">{error}</p>}
      {tab === 'memory' && <>
        <div className="soft-note"><Leaf size={20}/><span>候选记忆经你确认后，栗栗才会在以后的聊天中使用。只保存兴趣和接触过的词，不给表达能力贴标签。</span></div>
        <div className="section-label">等待确认 <span>{data.memories.filter(m => m.status === 'pending').length}</span></div>
        {data.memories.filter(m => m.status === 'pending').map(m => <MemoryRow key={m.id} memory={m} disabled={working} onSave={(text, status) => action(async () => { await api(`/memories/${m.id}`, { method: 'PATCH', body: body({ text, status }) }); onDataCleared(); })} onDelete={() => action(async () => { await api(`/memories/${m.id}`, { method: 'DELETE' }); onDataCleared(); })}/>)}
        {!data.memories.some(m => m.status === 'pending') && <p className="empty-line">还没有待确认的记忆。可以在聊天里试着说“我喜欢恐龙”。</p>}
        <div className="section-label">已经记住 <span>{data.memories.filter(m => m.status === 'approved').length}</span></div>
        {data.memories.filter(m => m.status === 'approved').map(m => <MemoryRow key={m.id} memory={m} disabled={working} onSave={(text, status) => action(async () => { await api(`/memories/${m.id}`, { method: 'PATCH', body: body({ text, status }) }); onDataCleared(); })} onDelete={() => action(async () => { await api(`/memories/${m.id}`, { method: 'DELETE' }); onDataCleared(); })}/>)}
        {!data.memories.some(m => m.status === 'approved') && <p className="empty-line">这里还是一片空白，慢慢了解就好。</p>}
        <form className="add-memory" onSubmit={e => { e.preventDefault(); void action(async () => { await api('/memories', { method: 'POST', body: body({ kind: 'interest', text: newMemory }) }); setNewMemory(''); }); }}><input aria-label="手动补充记忆" maxLength={100} placeholder="手动补充一个非隐私的兴趣……" value={newMemory} onChange={e => setNewMemory(e.target.value)}/><button className="secondary-button" disabled={!newMemory.trim() || working}><Plus size={16}/>添加候选</button></form>
        <div className="section-label">讲述小观察</div>
        {data.observations.length ? data.observations.map((o,i) => <p className="observation" key={i}><BookOpen size={16}/>{o.text}</p>) : <p className="empty-line">在“看图说故事”中聊一聊后，这里会出现本次讲述的观察。它不是儿童发展测评。</p>}
      </>}
      {tab === 'settings' && <>
        <Setting title="每段对话的时间" subtitle="时间到了就轻轻停下来，故事进度会留下。"><select aria-label="每段对话的时间" disabled={working} value={data.settings.sessionMinutes} onChange={e => void setting({ sessionMinutes: Number(e.target.value) })}><option value={5}>5 分钟</option><option value={10}>10 分钟</option><option value={15}>15 分钟</option></select></Setting>
        <Setting title="一点点英语" subtitle="自然加入相关的英文词，不做口语考试。"><Toggle label="英语启蒙" checked={data.settings.english} disabled={working} onChange={v => void setting({ english: v })}/></Setting>
        <Setting title="声音的选择" subtitle="栗栗是 AI，声音也由机器生成。本机声音依设备而定。"><select aria-label="声音的选择" disabled={working} value={data.settings.voice} onChange={e => void setting({ voice: e.target.value as Settings['voice'] })}><option value="device">本机声音 · 免费</option><option value="cloud" disabled={!data.cloudAvailable}>云端声音 · 消耗额度</option><option value="off">安静阅读</option></select></Setting>
        <Setting title="提取记忆与讲述观察" subtitle="关闭后停止新增候选与观察，也不再向 AI 提供已有记忆。"><Toggle label="提取记忆与讲述观察" checked={data.settings.memoryEnabled} disabled={working} onChange={v => void setting({ memoryEnabled: v })}/></Setting>
        <div className="usage-card"><div><span>今日云端调用</span><strong>{data.usage.cloudOperations}<small> / {data.dailyLimit}</small></strong></div><p>含对话、转写和云端朗读。失败调用也占用本地限额；额度余额以 OpenAI 平台为准。</p><dl><div><dt>文本输入</dt><dd>{data.usage.inputTokens.toLocaleString()} tokens</dd></div><div><dt>文本输出</dt><dd>{data.usage.outputTokens.toLocaleString()} tokens</dd></div></dl></div>
        <p className="caption">时间设置对新对话生效。当前研究模型：{data.model}。</p>
      </>}
      {tab === 'data' && <>
        <div className="soft-note amber"><ShieldCheck size={22}/><span><strong>当前仅供成人使用虚构内容测试。</strong><br/>在核实 OpenAI 项目的零数据保留及其他适用条件前，不输入真实儿童的语音、身份、学校或生活隐私。此预览没有儿童使用开关。</span></div>
        <div className="data-fact"><CircleCheck size={17}/><p><strong>只在这台电脑上保存</strong><span>经确认的记忆、待确认候选、虚构故事摘要和少量讲述观察，保存在本机数据库。</span></p></div>
        <div className="data-fact"><CircleCheck size={17}/><p><strong>原始录音不落盘</strong><span>录音仅在转写时暂存内存。聊天原文仅保留在有时限的临时会话，关闭服务后清空。云端提供商的留存独立于本机设置。</span></p></div>
        <div className="data-fact"><CircleCheck size={17}/><p><strong>成人算术验证是交互门槛</strong><span>它不是账号认证。服务仅监听本机，不适合共享、联网部署或多人使用。</span></p></div>
        <div className="data-actions"><button className="secondary-button" disabled={working} onClick={() => void exportData()}><Download size={16}/>导出本机数据</button><button className="danger-button" disabled={working} onClick={() => setConfirmDelete(true)}><Trash2 size={16}/>清空记忆与故事</button></div>
        {confirmDelete && <div className="delete-confirm"><p>这会删除所有记忆、故事摘要和观察，并结束当前对话。今日调用计数会保留。</p><div><button className="secondary-button" onClick={() => setConfirmDelete(false)}>先留着</button><button className="danger-button" disabled={working} onClick={() => void action(async () => { await api('/data', { method: 'DELETE' }); onDataCleared(); setConfirmDelete(false); })}>确认清空</button></div></div>}
      </>}
    </div>
  </Dialog>;
}
function Setting({ title, subtitle, children }: { title: string; subtitle: string; children: React.ReactNode }) { return <div className="setting-row"><div><strong>{title}</strong><p>{subtitle}</p></div>{children}</div>; }
function Toggle({ label, checked, onChange, disabled }: { label: string; checked: boolean; onChange: (v:boolean) => void; disabled: boolean }) { return <button role="switch" aria-label={label} aria-checked={checked} disabled={disabled} className={`toggle ${checked ? 'on' : ''}`} onClick={() => onChange(!checked)}><span/></button>; }
function MemoryRow({ memory, onSave, onDelete, disabled }: { memory: Memory; onSave: (text: string, status: Memory['status']) => Promise<void>; onDelete: () => Promise<void>; disabled: boolean }) {
  const [editing, setEditing] = useState(false); const [text, setText] = useState(memory.text);
  return <div className="memory-row"><span className={`memory-dot ${memory.status}`}/><div className="memory-text">{editing ? <input aria-label="修改记忆" value={text} maxLength={100} onChange={e => setText(e.target.value)}/> : <strong>{memory.text}</strong>}<small>{memory.status === 'approved' ? '已确认 · 下次聊天可以用到' : `依据：${memory.evidence}`}</small></div><div className="memory-actions">{editing ? <button aria-label="保存记忆" className="icon-button" disabled={disabled || !text.trim()} onClick={() => void onSave(text, memory.status).then(() => setEditing(false))}><Check size={17}/></button> : <><button className="icon-button" aria-label="修改记忆" disabled={disabled} onClick={() => setEditing(true)}><Pencil size={16}/></button>{memory.status === 'pending' && <button className="approve-button" disabled={disabled} onClick={() => void onSave(memory.text, 'approved')}><Check size={15}/>记住</button>}</>}<button className="icon-button" disabled={disabled} aria-label="删除记忆" onClick={() => void onDelete()}><Trash2 size={16}/></button></div></div>;
}
