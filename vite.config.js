import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'

// Em "mock" o app roda com dados de demonstração na memória (para testes),
// sem tocar no Supabase. Em produção usa sempre o Supabase.
export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [react()],
  resolve: {
    alias: {
      '#backend': fileURLToPath(new URL(
        mode === 'mock' ? './src/lib/backend.mock.js' : './src/lib/backend.supabase.js',
        import.meta.url)),
    },
  },
}))
