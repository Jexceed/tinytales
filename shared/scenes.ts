import type { Scene } from './types';

export const scenes: Scene[] = [
  { id: 'rain', title: '一把伞的旅行', subtitle: '下雨了，谁需要一把伞？', prompt: '画里的小兔子和小刺猬在做什么呢？', image: '/scenes/rain.png', color: '#edf1e8', word: { hanzi: '雨伞', pinyin: 'yǔ sǎn', english: 'umbrella' } },
  { id: 'moon', title: '月亮来做客', subtitle: '今晚，森林里亮起了一盏灯。', prompt: '你觉得小狐狸为什么要把梯子靠在月亮旁边？', image: '/scenes/moon.png', color: '#eeedf5', word: { hanzi: '月亮', pinyin: 'yuè liang', english: 'moon' } },
  { id: 'seed', title: '一颗种子的愿望', subtitle: '小小的种子，会长成什么呢？', prompt: '小熊在花园里发现了什么？接下来会发生什么呢？', image: '/scenes/seed.png', color: '#f5eddc', word: { hanzi: '种子', pinyin: 'zhǒng zi', english: 'seed' } },
];
