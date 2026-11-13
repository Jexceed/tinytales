import { z } from 'zod';

export const ModeSchema = z.enum(['chat', 'story', 'picture']);
export type Mode = z.infer<typeof ModeSchema>;
export const MemoryKindSchema = z.enum(['interest', 'english', 'word']);
export const ReplySchema = z.object({
  reply: z.string(),
  suggestions: z.array(z.string()).max(3),
  memoryCandidates: z.array(z.object({ kind: MemoryKindSchema, text: z.string(), evidence: z.string() })).max(2),
  story: z.object({ title: z.string(), summary: z.string() }).nullable(),
  word: z.object({ hanzi: z.string(), pinyin: z.string(), english: z.string() }).nullable(),
  observation: z.string().nullable(),
});
export type Reply = z.infer<typeof ReplySchema>;
export interface Memory { id: string; kind: z.infer<typeof MemoryKindSchema>; text: string; evidence: string; status: 'pending' | 'approved'; createdAt: string }
export interface Story { id: string; title: string; summary: string; updatedAt: string; source: 'demo' | 'cloud' }
export interface Settings { sessionMinutes: number; english: boolean; voice: 'device' | 'cloud' | 'off'; memoryEnabled: boolean }
export interface Usage { turns: number; inputTokens: number; outputTokens: number; transcriptionSeconds: number; speechSeconds: number; cloudOperations: number }
export interface Bootstrap { memories: Memory[]; stories: Story[]; settings: Settings; usage: Usage; cloudAvailable: boolean; model: string; dailyLimit: number; scenes: Scene[]; observations: { text: string; createdAt: string }[] }
export interface Scene { id: string; title: string; subtitle: string; prompt: string; image: string; color: string; word: { hanzi: string; pinyin: string; english: string } }
export interface TurnResponse extends Reply { storyId: string | null; turnId: string; source: 'demo' | 'cloud' | 'safety'; latencyMs: number }
export interface Message { id: string; role: 'assistant' | 'user'; text: string; turnId?: string; source?: TurnResponse['source']; word?: Reply['word']; suggestions?: string[] }
