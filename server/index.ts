import { resolve } from 'node:path';
import { chmodSync } from 'node:fs';
import express from 'express';
import { Store } from './store';
import { OpenAIProvider } from './provider';
import { createApp } from './app';

const port = Number(process.env.PORT || 3210);
const store = new Store(resolve(process.env.TINYTALES_DATA_DIR || 'data', 'tinytales.sqlite'));
try { chmodSync(resolve(process.env.TINYTALES_DATA_DIR || 'data', 'tinytales.sqlite'), 0o600); } catch { /* SQLite may be in a test location. */ }
const provider = process.env.OPENAI_API_KEY?.trim() ? new OpenAIProvider(process.env.OPENAI_API_KEY.trim()) : undefined;
const app = createApp(store, provider);
let closeVite: (() => Promise<void>) | undefined;
app.use('/scenes', express.static(resolve('public/scenes')));
if (process.env.NODE_ENV === 'production') {
  app.use(express.static(resolve('dist')));
  app.get('/{*path}', (_req, res) => res.sendFile(resolve('dist/index.html')));
} else {
  const { createServer } = await import('vite');
  const vite = await createServer({ server: { middlewareMode: true }, appType: 'spa' });
  app.use(vite.middlewares); closeVite = () => vite.close();
}
const server = app.listen(port, '127.0.0.1', () => {
  console.log(`TinyTales: http://127.0.0.1:${port}`);
  console.log(`Adult synthetic-data preview · Cloud ${provider ? 'configured' : 'not configured'}`);
});
async function shutdown() { server.close(); await closeVite?.(); store.close(); process.exit(0); }
process.on('SIGINT', shutdown); process.on('SIGTERM', shutdown);
