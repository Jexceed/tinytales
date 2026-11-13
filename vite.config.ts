import { defineConfig } from 'vite';

export default defineConfig({
  server: { host: '127.0.0.1', allowedHosts: ['localhost'], hmr: { port: 24679 } },
  build: { outDir: 'dist' },
});
