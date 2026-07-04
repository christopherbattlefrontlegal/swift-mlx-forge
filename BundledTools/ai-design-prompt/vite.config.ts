import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react-swc'
import path from 'path'

export default defineConfig({
  // Relative asset paths: the app is served from file:// inside Forge.app,
  // where absolute /assets/ URLs resolve to the filesystem root (white screen).
  base: './',
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
})
