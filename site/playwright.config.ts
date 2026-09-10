import { defineConfig, devices } from '@playwright/test';

// Deliberately not 3000 — that port is commonly taken by other apps.
const PORT = Number(process.env.LITRO_E2E_PORT ?? 4321);

// Which renderer the suite drives.
//
//   dev      — `litro dev`, Vite serving modules from source.
//   preview  — `litro preview`, the prerendered `dist/static` that nginx
//              ships. This is the artifact production actually serves.
//
// Both matter, because the two builds are not the same program. What only
// `preview` can catch is client code whose behaviour differs between them —
// anything behind `import.meta.env.PROD`, anything the minifier or the
// tree-shaker rewrites, anything that depends on being a bundled chunk rather
// than a module served from source. A `throw` inside `if (import.meta.env.PROD)`
// passes `dev` 5/5 and fails `preview` 3/5; that is the gap, and it is why this
// file has two targets.
//
// Worth being precise about the break that motivated this, because it is NOT
// an example of the above: a page module that *calls* a Node builtin at module
// scope fails BOTH targets on the current toolchain. And a builtin that is
// merely imported and never called fails neither — rolldown stubs it to an
// empty object and tree-shakes the import away, so nothing ships and there is
// nothing to catch. The `has been externalized for browser compatibility`
// warning is therefore not a reliable signal on its own; gating on it would
// have to be a build-log check, not an assertion here.
const RAW_TARGET = process.env.LITRO_E2E_TARGET ?? 'dev';
if (RAW_TARGET !== 'dev' && RAW_TARGET !== 'preview') {
  // Fail loudly rather than falling back. A silent fallback meant that
  // `LITRO_E2E_TARGET=Preview` ran the dev target, passed, and exited 0 —
  // a CI step that believed it had opened the built output never built it.
  throw new Error(
    `LITRO_E2E_TARGET must be "dev" or "preview", got ${JSON.stringify(RAW_TARGET)}.`,
  );
}
const TARGET = RAW_TARGET;

// One target per invocation, never both in one run. `litro dev` deletes
// `dist/` on startup, which is exactly the directory `litro preview` serves,
// and Playwright starts the entries of a `webServer` array CONCURRENTLY — so a
// two-server config races the dev server against the preview server's own
// build and blanks it. `pnpm test:e2e` runs the two targets in sequence
// instead; see package.json.
const command =
  TARGET === 'preview'
    ? `pnpm build && pnpm preview --port ${PORT}`
    : `pnpm dev --port ${PORT}`;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  // Per target, so the second run does not overwrite the first run's report
  // and CI can upload the evidence for whichever one failed.
  reporter: [['html', { outputFolder: `playwright-report/${TARGET}`, open: 'never' }]],
  outputDir: `test-results/${TARGET}`,
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: 'on-first-retry',
  },
  projects: [{ name: TARGET, use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command,
    url: `http://localhost:${PORT}`,
    // Never reuse: on the default port a completely unrelated app (Docker,
    // Obsidian, another dev server) can be listening, and Playwright would
    // happily run the whole suite against it and report 404s.
    reuseExistingServer: false,
    // The preview target builds first, and a cold build with no cache is the
    // slow case here — 60s is not enough for it.
    timeout: TARGET === 'preview' ? 300000 : 60000,
  },
});
