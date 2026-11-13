import type { Mode, Reply, Story } from '../shared/types';
import { scenes } from '../shared/scenes';

// Explicitly labelled, deterministic offline interaction. No model is called here.
export function demoReply(text: string, mode: Mode, sceneId?: string, previous?: Story): Reply {
  const scene = scenes.find(s => s.id === sceneId) || scenes[0];
  const interested = text.match(/(?:我很喜欢|我最喜欢|我喜欢)([^，。！？\n]{1,18})/);
  const base: Reply = { reply: '', suggestions: [], memoryCandidates: interested ? [{ kind: 'interest', text: `喜欢${interested[1]}`, evidence: interested[0] }] : [], story: null, word: null, observation: null };
  if (mode === 'story') {
    const start = previous?.summary || '小恐龙在森林里找到一扇会发光的门。';
    return { ...base, reply: previous ? `我们上次讲到：${previous.summary.slice(0,90)} 现在，门边传来轻轻的敲门声。你觉得是谁来了？` : '一只小恐龙在森林里发现了一扇小小的门。门把手竟然是一颗星星！它把耳朵贴上去，听见了沙沙的声音。门后面会有什么呢？', suggestions: ['一片星星花园', '一只迷路的小兔', '我来接着讲'], story: { title: previous?.title || '小恐龙和星星门', summary: `${start.slice(0,100)} 讲述者提出：“${text.slice(0,45)}”。门边传来敲门声，等待决定来访者是谁。` } };
  }
  if (mode === 'picture') return { ...base, reply: `你给“${scene.title}”添了一个新想法。我们再看看画面，${scene.id === 'rain' ? '小兔子把伞往小刺猬那边挪了挪。小刺猬发现以后，会说些什么呢？' : scene.prompt}`, suggestions: ['我发现一个小细节', '它们会成为朋友', '我想编一个新结尾'], word: scene.word, observation: '这次讲述参与了图片讨论。可以试着用“先……然后……”把两个画面细节连起来。' };
  if (/英语|英文|hello|cat|dog/i.test(text)) return { ...base, reply: '小猫用英文可以说 cat。小猫轻轻地走过来，喵了一声。你想用什么声音跟它打招呼呢？', suggestions: ['Hello, little cat!', '它想找个朋友', '我们说中文吧'], word: { hanzi: '小猫', pinyin: 'xiǎo māo', english: 'cat' } };
  if (/难过|伤心|生气/.test(text)) return { ...base, reply: '听起来这件事让你不太舒服。你可以慢慢说，也可以和身边信任的大人聊聊。刚刚发生了什么呢？', suggestions: ['我想慢慢说', '先抱抱我的玩偶', '换个轻松的话题'] };
  return { ...base, reply: interested ? `原来你喜欢${interested[1]}呀。要是它今天来到我们的故事屋，你觉得它会先做什么呢？` : '我在听呢。你说的事情让我想到一个可以慢慢展开的小故事。你最想从哪个地方开始讲？', suggestions: ['今天发生的趣事', '我喜欢的小动物', '来一场太空旅行'] };
}
