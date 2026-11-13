import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import type { Memory, Story, Settings, Usage, Reply } from '../shared/types';
import { acceptableMemory } from './safety';

export const defaultSettings: Settings = { sessionMinutes: 10, english: false, voice: 'device', memoryEnabled: true };
const emptyUsage = (): Usage => ({ turns: 0, inputTokens: 0, outputTokens: 0, transcriptionSeconds: 0, speechSeconds: 0, cloudOperations: 0 });
// Billing day is defined in the user's timezone, not the host's.
export const usageDay = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export class Store {
  db: DatabaseSync;
  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;
      CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL UNIQUE, evidence TEXT NOT NULL, status TEXT NOT NULL, createdAt TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS stories (id TEXT PRIMARY KEY, title TEXT NOT NULL, summary TEXT NOT NULL, updatedAt TEXT NOT NULL, source TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS observations (id TEXT PRIMARY KEY, text TEXT NOT NULL, createdAt TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS usage (day TEXT PRIMARY KEY, json TEXT NOT NULL);`);
    this.db.prepare('INSERT OR IGNORE INTO settings VALUES (1, ?)').run(JSON.stringify(defaultSettings));
  }
  settings(): Settings { return JSON.parse((this.db.prepare('SELECT json FROM settings WHERE id=1').get() as { json: string }).json); }
  setSettings(value: Settings) { this.db.prepare('UPDATE settings SET json=? WHERE id=1').run(JSON.stringify(value)); }
  memories(): Memory[] { return this.db.prepare('SELECT * FROM memories ORDER BY createdAt DESC LIMIT 60').all() as unknown as Memory[]; }
  addCandidate(c: Reply['memoryCandidates'][number]) {
    if (!acceptableMemory(c.text) || !acceptableMemory(c.evidence)) return;
    if (this.memories().length >= 60) return;
    this.db.prepare('INSERT OR IGNORE INTO memories VALUES (?,?,?,?,?,?)').run(randomUUID(), c.kind, c.text, c.evidence, 'pending', new Date().toISOString());
  }
  updateMemory(id: string, text: string, status: 'pending' | 'approved') {
    this.db.prepare('UPDATE memories SET text=?, status=? WHERE id=?').run(text, status, id);
  }
  deleteMemory(id: string) { this.db.prepare('DELETE FROM memories WHERE id=?').run(id); }
  stories(): Story[] { return this.db.prepare('SELECT * FROM stories ORDER BY updatedAt DESC LIMIT 20').all() as unknown as Story[]; }
  story(id: string): Story | undefined { return this.db.prepare('SELECT * FROM stories WHERE id=?').get(id) as unknown as Story | undefined; }
  saveStory(story: Story) {
    if (!acceptableMemory(story.title) || containsBadSummary(story.summary)) return;
    this.db.prepare('INSERT INTO stories VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, summary=excluded.summary, updatedAt=excluded.updatedAt').run(story.id, story.title, story.summary, story.updatedAt, story.source);
    this.db.exec('DELETE FROM stories WHERE id NOT IN (SELECT id FROM stories ORDER BY updatedAt DESC LIMIT 20)');
  }
  deleteStory(id: string) { this.db.prepare('DELETE FROM stories WHERE id=?').run(id); }
  observe(text: string) {
    if (containsBadSummary(text) || /(?:诊断|发育|智商|落后|障碍|能力差|得分|评分)/.test(text)) return;
    this.db.prepare('INSERT INTO observations VALUES (?,?,?)').run(randomUUID(), text.slice(0, 160), new Date().toISOString());
    this.db.exec('DELETE FROM observations WHERE id NOT IN (SELECT id FROM observations ORDER BY createdAt DESC LIMIT 10)');
  }
  observations() { return this.db.prepare('SELECT text, createdAt FROM observations ORDER BY createdAt DESC').all() as { text: string; createdAt: string }[]; }
  usage(): Usage { const row = this.db.prepare('SELECT json FROM usage WHERE day=?').get(usageDay()) as { json: string } | undefined; return row ? { ...emptyUsage(), ...JSON.parse(row.json) } : emptyUsage(); }
  addUsage(delta: Partial<Usage>) {
    const value = this.usage();
    for (const k of Object.keys(delta) as (keyof Usage)[]) value[k] += delta[k] || 0;
    this.db.prepare('INSERT INTO usage VALUES (?,?) ON CONFLICT(day) DO UPDATE SET json=excluded.json').run(usageDay(), JSON.stringify(value));
  }
  clear() {
    this.db.exec('DELETE FROM memories; DELETE FROM stories; DELETE FROM observations; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;');
    // Daily usage is deliberately preserved so deleting memories cannot bypass the request cap.
  }
  close() { this.db.close(); }
}

import { containsPrivateData, localRisk } from './safety';
function containsBadSummary(text: string) { return text.length > 800 || containsPrivateData(text) || localRisk(text) || /(?:忽略.*指令|system prompt|ignore.*instruction)/i.test(text); }
