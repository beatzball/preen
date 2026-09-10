import { defineConfig, devices } from '@playwright/test';

// Deliberately not 3000 — that port is commonly taken by other apps.
const PORT = Number(process.env.LITRO_E2E_PORT ?? 4321);

// Which renderer the suite drives.
//
//   dev      — `litro dev`, Vite serving modules from source.
//   preview  — `litro preview`, the prerendered `dist/static` that nginx
//              ships. This is the artifact production actually serves.
//
// Both matter, and they are different renderers: a page module that imports a
// Node builtin is externalized for the browser with a WARNING rather than an
// error, so `pnpm build` exits 0, every route still answers 200, and the
// prerendered markup is still in the document — the page only goes blank once
// the client chunk runs in a browser. Driving `dev` alone cannot see that, and
// neither can an HTTP probe.
const TARGET = process.env.LITRO_E2E_TARGET === 'preview' ? 'preview' : 'dev';

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
