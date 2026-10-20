import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';
import { copyFileSync } from 'node:fs';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const renderer = path.join(root, 'renderer');
const output = path.resolve(root, '../Resources/Web');

export default defineConfig({
  root: renderer,
  base: './',
  define: { 'process.env.NODE_ENV': '"production"' },
  build: {
    outDir: output,
    emptyOutDir: true,
    target: 'safari16',
    cssCodeSplit: false,
    lib: {
      entry: path.join(renderer, 'main.tsx'),
      name: 'RcloneBrowserUI',
      formats: ['iife'],
      fileName: () => 'app.js',
      cssFileName: 'style',
    },
  },
  plugins: [{
    name: 'native-app-document',
    writeBundle() {
      copyFileSync(path.join(renderer, 'index.html'), path.join(output, 'index.html'));
      copyFileSync(path.join(renderer, 'favicon.svg'), path.join(output, 'favicon.svg'));
      copyFileSync(path.join(root, 'THIRD_PARTY_NOTICES.txt'), path.join(output, 'THIRD_PARTY_NOTICES.txt'));
    },
  }],
});
