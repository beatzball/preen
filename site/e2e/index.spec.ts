import { test, expect, type Page } from '@playwright/test';

const DOC_ROUTES = [
  '/docs/getting-started',
  '/docs/browsing',
  '/docs/pipes',
  '/docs/pull-requests',
  '/docs/worktrees',
  '/docs/git-integration',
  '/docs/theming',
];

const PRERENDERED_ROUTES = ['/', ...DOC_ROUTES];

/**
 * Everything the browser itself reports: an uncaught exception, a
 * `console.error`, or a subresource that never arrived.
 *
 * This is the only place a broken client bundle shows up. A page module that
 * imports a Node builtin is externalized for the browser with a warning, so
 * `pnpm build` exits 0; the route still answers 200 and the document still
 * carries the prerendered markup, so neither the HTTP probe in
 * `scripts/verify-site.sh` nor a markup grep notices. The chunk then throws in
 * the browser, the custom element never upgrades, and the page paints nothing.
 *
 * Verified against a clean build: all eight routes report zero of these, so an
 * empty list is the real baseline and not an accident of what we listen for.
 */
function collectBrowserErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(`uncaught: ${e.message}`));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(`console.error: ${m.text()}`);
  });
  page.on('requestfailed', (r) => errors.push(`request failed: ${r.url()}`));
  return errors;
}

// `.first()`, not a bare locator, and only the built output needs it: while
// `litro-outlet` hydrates it briefly holds a second, hidden copy of the page
// element alongside the prerendered one, so a bare locator trips Playwright's
// strict mode with "resolved to 2 elements". The prerendered one is first and
// is the one on screen. `litro dev` never shows this, which is the whole
// reason the preview target exists.
test('home renders page-home component', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('page-home');
  await expect(page.locator('page-home').first()).toBeVisible();
});

test('/docs/getting-started renders', async ({ page }) => {
  await page.goto('/docs/getting-started');
  await page.waitForSelector('page-docs-slug');
  await expect(page.locator('page-docs-slug').first()).toBeVisible();
});

test('all prerendered routes return 200', async ({ request }) => {
  for (const route of PRERENDERED_ROUTES) {
    const response = await request.get(route);
    expect(response.status(), `Expected 200 for ${route}`).toBe(200);
  }
});

test('every prerendered route paints its content', async ({ page }) => {
  for (const route of PRERENDERED_ROUTES) {
    await page.goto(route);
    // Not the custom element and not the markup: an element that never
    // upgraded is still in the document, and so is every <h2> the prerender
    // wrote. Only `:visible` separates a page that rendered from one that
    // shipped its markup and then painted nothing -- which is exactly the
    // shape the node:fs break takes.
    const heading = page.locator('h2').first();
    await expect(heading, `${route} painted no visible <h2>`).toBeVisible();
    await expect(heading, `${route} painted an empty <h2>`).not.toHaveText('');
  }
});

test('every prerendered route hydrates without a browser error', async ({ page }) => {
  const errors = collectBrowserErrors(page);
  for (const route of PRERENDERED_ROUTES) {
    await page.goto(route, { waitUntil: 'networkidle' });
    // Hydration proper: the page component has to be defined. When the client
    // chunk throws on the way in, the registration never runs.
    const tag = route === '/' ? 'page-home' : 'page-docs-slug';
    await expect
      .poll(
        () => page.evaluate((t) => !!customElements.get(t), tag),
        { message: `${route} never defined <${tag}>, so it did not hydrate` },
      )
      .toBe(true);
  }
  expect(errors, 'the browser reported errors').toEqual([]);
});
