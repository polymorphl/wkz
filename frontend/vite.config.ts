import { defineConfig } from 'vite'

export default defineConfig({
  resolve: {
    alias: {
      '@wkz/bridge': new URL('../bridge-js/src/index.ts', import.meta.url).pathname,
    },
  },
})
