import { defineConfig } from 'vite';
import litroContentPlugin from '@beatzball/litro/vite';

/**
 * Keep highlight.js out of the client build entirely.
 *
 * pages/docs/[slug].ts imports src/highlight.ts dynamically, from inside its
 * pageData fetcher, so the browser never asks for the chunk. But Vite still
 * emits it: 921KB written into dist/, shipped in the Docker image and pushed
 * to the CDN, for code that only ever runs at build time. It is also a loaded
 * gun -- the emitted chunk keeps a real import, so if that fetcher were ever
 * to run client-side it would pull all ~190 language grammars down.
 *
 * This config drives ONLY the client bundle (input app.ts, outDir
 * dist/client); the server is built separately by nitro and still gets the
 * real module. `apply: 'build'` keeps dev untouched.
 */
function stubHighlightInClientBuild() {
  return {
    name: 'preen:stub-highlight-in-client',
    apply: 'build' as const,
    enforce: 'pre' as const,
    load(id: string) {
      if (id.replace(/\\/g, '/').endsWith('/src/highlight.ts')) {
        // Same shape, so anything that reaches for it still type-checks and
        // returns the markup untouched rather than throwing.
        return 'export function applyHighlighting(html) { return html; }\n';
      }
      return null;
    },
  };
}

export default defineConfig({
  plugins: [stubHighlightInClientBuild(), litroContentPlugin()],
  base: process.env.LITRO_BASE_PATH ? `${process.env.LITRO_BASE_PATH}/_litro/` : '/_litro/',
  resolve: {
    // NOTE: no 'source' condition. An installed package's TypeScript is
    // never transpiled by Vite (it lives under node_modules), so resolving
    // to source would emit raw decorators and break the client bundle.
    // Always consume the package's compiled output.
    conditions: ['browser', 'module', 'import', 'default'],
  },
  build: {
    outDir: 'dist/client',
    rollupOptions: {
      input: 'app.ts',
      output: {
        entryFileNames: '[name].js',
      },
    },
  },
});
