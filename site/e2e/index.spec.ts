import { test, expect, type Page } from '@playwright/test';

const DOC_ROUTES = [
  '/docs/getting-started',
  '/docs/browsing',
  '/docs/pipes',
  '/docs/pull-requests',
  '/docs/worktrees',
  '/docs/git-integration',
  '/docs/theming',
  '/docs/changelog',
];

const PRERENDERED_ROUTES = ['/', ...DOC_ROUTES];

/**
 * Everything the browser itself reports: an uncaught exception, a
 * `console.error`, or a subresource that never arrived.
 *
 * This is the only place a broken client bundle shows up. The route still
 * answers 200 and the document still carries the prerendered markup, so
 * neither the HTTP probe in `scripts/verify-site.sh` nor a markup grep
 * notices; the chunk throws in the browser, the custom element never upgrades,
 * and the page paints nothing.
 *
 * Verified against a clean build: all eight routes report zero of these across
 * 50 runs (`--repeat-each=5`, both targets), so an empty list is the real
 * baseline and not an accident of what we listen for.
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

test('home renders page-home component', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('page-home');
  await expect(page.locator('page-home')).toBeVisible();
});

// `.first()` here and not on `page-home`: against the BUILT output
// `litro-outlet` briefly holds a second, hidden `page-docs-slug` alongside the
// prerendered one while it hydrates, so a bare locator trips Playwright's
// strict mode with "resolved to 2 elements". Checked with `--repeat-each=5`:
// only the docs route shows the duplicate, home never does. `litro dev` never
// shows it either, which is one more thing the preview target sees first.
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

/**
 * Where a route's OWN content lives, so an assertion cannot be satisfied by
 * page furniture.
 *
 * A bare `h2` is not good enough. Playwright's CSS engine pierces open shadow
 * roots, and `starlight-toc` renders a fixed `<h2>On this page</h2>`
 * (src/components/starlight-toc.ts:116) on every doc page. That heading is
 * there whether or not the page has any content, so a bare `h2` check passes a
 * completely empty doc page -- verified by setting `body` to `''` in
 * `pages/docs/[slug].ts`, which renders seven blank pages and still gives
 * `5 passed`. Doc content is slotted into a `<div slot="content">`
 * (pages/docs/[slug].ts:275); the home page has no such slot and no TOC, so its
 * own headings are the only ones inside `page-home`.
 *
 * Every doc page is required to start its body at `##` (see site/AGENTS.md), so
 * "the content slot contains a visible, non-empty <h2>" holds for all of them.
 */
function contentHeadingSelector(route: string): string {
  return route === '/' ? 'page-home h2' : '[slot="content"] h2';
}

test('every prerendered route paints its content', async ({ page }) => {
  for (const route of PRERENDERED_ROUTES) {
    await page.goto(route);
    // `:visible`, not merely present: an element that never upgraded is still
    // in the document, and so is every <h2> the prerender wrote. Visibility is
    // what separates a page that rendered from one that shipped its markup and
    // then painted nothing.
    const heading = page.locator(contentHeadingSelector(route)).first();
    await expect(heading, `${route} painted no visible content <h2>`).toBeVisible();
    await expect(heading, `${route} painted an empty content <h2>`).not.toHaveText('');
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

/**
 * The header row cannot wrap, so one link too many in `nav` makes every page
 * scroll sideways on a phone -- and nothing else fails. A second top-nav link
 * (Changelog) did exactly that: 433px of document in a 390px viewport, with
 * the theme toggle off screen, while every other test here stayed green.
 * 320px is the narrowest width the header budget in
 * src/components/starlight-header.ts is written for.
 */
test('no prerendered route scrolls sideways on a phone', async ({ page }) => {
  for (const width of [320, 375]) {
    await page.setViewportSize({ width, height: 800 });
    for (const route of PRERENDERED_ROUTES) {
      // Wait for the client to draw the header. In dev the first measure can
      // land before it has, and passes a page that is 397px wide once it does.
      await page.goto(route, { waitUntil: 'networkidle' });
      const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
      expect(scrollWidth, `${route} is ${scrollWidth}px wide at ${width}px`).toBeLessThanOrEqual(width);
    }
  }
});

/**
 * content/docs/changelog.md is generated, and an edit to it fails
 * `pnpm sync:check`. Its "Edit this page" link has to send a visitor to the
 * source instead.
 */
test('the changelog edits CHANGELOG.md, not its generated page', async ({ page }) => {
  await page.goto('/docs/changelog');
  const edit = page.locator('a[href*="/edit/main/"]').first();
  await expect(edit).toHaveAttribute('href', 'https://github.com/beatzball/preen/edit/main/CHANGELOG.md');
  await page.goto('/docs/pipes');
  await expect(page.locator('a[href*="/edit/main/"]').first())
    .toHaveAttribute('href', 'https://github.com/beatzball/preen/edit/main/site/content/docs/pipes.md');
});
