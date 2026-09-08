import { defineConfig } from 'vite';
import litroContentPlugin from '@beatzball/litro/vite';

/**
 * Keep the server-only modules out of the client build entirely.
 *
 * pages/docs/[slug].ts imports both of these dynamically, from inside its
 * pageData fetcher, so the browser never asks for either chunk. Vite still
 * emits them.
 *
 * For src/highlight.ts that is 921KB written into dist/, shipped in the image
 * and pushed to the CDN, for code that only ever runs at build time -- and a
 * loaded gun, because the emitted chunk keeps a real import.
 *
 * For src/image-size.ts it is worse than waste: it reads node:fs, which Vite
 * externalises for the browser with a warning rather than an error. The build
 * still passes and the doc page renders blank.
 *
 * This config drives ONLY the client bundle (input app.ts, outDir
 * dist/client); the server is built separately by nitro and still gets the
 * real module. `apply: 'build'` keeps dev untouched.
 */
const SERVER_ONLY_STUBS: Record<string, string> = {
  // Same shapes as the real modules, so anything that reaches for one still
  // resolves and degrades to a no-op rather than throwing.
  '/src/highlight.ts': 'export function applyHighlighting(html) { return html; }\n',
  '/src/image-size.ts':
    "export const PUBLIC_DIR = '';\nexport function imageSize() { return null; }\n",
};

function stubServerOnlyModulesInClientBuild() {
  return {
    name: 'preen:stub-server-only-in-client',
    apply: 'build' as const,
    enforce: 'pre' as const,
    load(id: string) {
      const path = id.replace(/\\/g, '/');
      const hit = Object.keys(SERVER_ONLY_STUBS).find((s) => path.endsWith(s));
      return hit ? SERVER_ONLY_STUBS[hit] : null;
    },
  };
}

export default defineConfig({
  plugins: [stubServerOnlyModulesInClientBuild(), litroContentPlugin()],
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
