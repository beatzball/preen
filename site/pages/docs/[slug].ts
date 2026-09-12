import { html, css } from 'lit';
import { unsafeHTML } from 'lit/directives/unsafe-html.js';
import { customElement } from 'lit/decorators.js';
import { LitroPage } from '@beatzball/litro/runtime';
import { definePageData } from '@beatzball/litro';
import { createError } from 'h3';
import type { Post } from 'litro:content';
import { getPosts } from 'litro:content';
import { siteConfig } from '../../server/starlight.config.js';
import { extractHeadings, addHeadingIds } from '../../src/extract-headings.js';
import { starlightHead } from '../../src/route-meta.js';
import { buildSeoHead, buildSeoTitle } from '../../src/seo.js';

// Register components used in render()
import '../../src/components/starlight-page.js';

export interface DocPageData {
  /** Only what render() reads. See the note where this is built. */
  doc: { title: string };
  body: string;
  toc: Array<{ depth: number; text: string; slug: string }>;
  sidebar: typeof siteConfig.sidebar;
  siteTitle: string;
  currentSlug: string;
  prevDoc: { label: string; href: string } | null;
  nextDoc: { label: string; href: string } | null;
  nav: typeof siteConfig.nav;
  editUrl: string | null;
  /** Raw <head> HTML for this doc. See src/seo.ts. */
  seoHead: string;
  /**
   * Overrides routeMeta.title. routeMeta is static per FILE, and this file
   * serves every doc, so without this every page would share one title.
   */
  seoTitle: string;
}

function computePrevNext(
  sidebar: typeof siteConfig.sidebar,
  currentSlug: string,
): { prevDoc: DocPageData['prevDoc']; nextDoc: DocPageData['nextDoc'] } {
  const flat = sidebar.flatMap(g => g.items);
  const idx = flat.findIndex(item => item.slug === currentSlug);
  return {
    prevDoc: idx > 0
      ? { label: flat[idx - 1].label, href: `/docs/${flat[idx - 1].slug}` }
      : null,
    nextDoc: idx < flat.length - 1
      ? { label: flat[idx + 1].label, href: `/docs/${flat[idx + 1].slug}` }
      : null,
  };
}

/**
 * Give every image in the rendered Markdown the attributes it cannot carry
 * itself: an intrinsic size, and lazy loading below the first one.
 *
 * **width and height** are what stop the page jumping. Without them a
 * Markdown image reserves no space, so every paragraph below it moves once
 * the bytes arrive — /docs/pipes measured CLS 0.174 against Google's 0.1
 * limit. The pair is only a ratio here, because the stylesheet sets
 * `max-width:100%; height:auto`, so the browser reserves the right box at
 * whatever width the column happens to be.
 *
 * **loading** is deferred on every image except the first. The recordings are
 * the heaviest thing the site serves and a page often has one near the top
 * and others most readers never scroll to. The first stays eager: it is
 * usually above the fold and is the thing the reader is waiting for.
 *
 * **An image that cannot be sized stops the build.** sizeOf reads PNG and
 * WebP headers and returns null for everything else, which is the right
 * fallback — a wrong number is worse than none — but on its own it is silent:
 * add a .jpg and that page quietly reserves nothing again, the build passes,
 * the probe passes, and nothing measures CLS. Nobody noticing is the failure
 * mode, so the omission is raised here instead of shipped. The opt-out is to
 * write the width and height yourself; see the message below.
 *
 * Reported and `process.exitCode`, deliberately NOT `throw`. litro's page
 * handler wraps every pageData fetcher in a try/catch that calls console.warn
 * and renders the page without data — "Data fetch failure is non-fatal" — so a
 * throw here is caught, `pnpm build` still exits 0, AND the page ships with
 * the Loading placeholder instead of its content. Measured both ways on the
 * fixture: throw gave exit 0 and a blank /docs/pipes; this gives exit 1 and a
 * complete page. Turning this back into a throw would silently restore the
 * bug it was written to close.
 *
 * Every image is checked before anything is reported, so one build names every
 * problem rather than one per round trip.
 */
function annotateImages(
  html: string,
  where: string,
  sizeOf: (src: string) => { w: number; h: number } | null,
): string {
  let seen = 0;
  const unsized: string[] = [];

  const out = html.replace(/<img\b([^>]*)>/g, (tag, attrs: string) => {
    // Count every image, including ones skipped below. Counting only the ones
    // that get rewritten would make a hand-written eager <img> promote the
    // NEXT image to "first" as well, and neither would be deferred.
    const isFirst = ++seen === 1;
    const add: string[] = [];

    // Anchored to a quote or whitespace so `data-loading=` cannot match.
    if (!isFirst && !/[\s"']loading\s*=/.test(' ' + attrs)) {
      add.push('loading="lazy"', 'decoding="async"');
    }

    // Either attribute written by hand means the author has taken the size on
    // themselves. That is the opt-out, and it is also why this tests for
    // EITHER rather than both: with one already present, adding the measured
    // pair emitted the same attribute twice.
    const authored = /[\s"']width\s*=/.test(' ' + attrs) || /[\s"']height\s*=/.test(' ' + attrs);
    if (!authored) {
      const src = /\ssrc\s*=\s*["']([^"']+)["']/.exec(attrs)?.[1];
      // Site-root paths only: anything remote has no file to read at build
      // time. It is collected rather than skipped, because an unsized remote
      // image shifts the layout exactly as much as an unsized local one.
      const local = src?.startsWith('/') && !src.startsWith('//');
      const size = local ? sizeOf(src!) : null;
      if (size) add.push(`width="${size.w}"`, `height="${size.h}"`);
      else unsized.push(src ?? '(no src)');
    }

    return add.length ? `<img${attrs} ${add.join(' ')}>` : tag;
  });

  if (unsized.length) {
    console.error(
      `${where}: ${unsized.length} image(s) have no intrinsic size, so the page would ` +
        `reserve no space for them and the layout would shift as they load:\n` +
        unsized.map((s) => `  ${s}`).join('\n') +
        `\nsrc/image-size.ts reads PNG and WebP headers only, and nothing remote can be ` +
        `measured at build time. Either convert the image to WebP, or write the tag in ` +
        `the Markdown with the size you want reserved, e.g.\n` +
        `  <img src="..." alt="..." width="1400" height="620">`,
    );
    process.exitCode = 1;
  }

  return out;
}

export const pageData = definePageData(async (event) => {
  const slug = event.context.params?.slug ?? '';

  // Content URLs are /content/docs/<slug> (contentDir = 'content', so
  // dirname is project root, and paths include the 'content/' prefix in the URL).
  const posts = await getPosts();
  const doc = posts.find(p => p.url === `/content/docs/${slug}`);

  if (!doc) {
    throw createError({ statusCode: 404, message: `Doc not found: ${slug}` });
  }

  const toc = extractHeadings(doc.rawBody);

  // Imported here rather than at the top of the file, and this is load-bearing.
  //
  // `highlight.js` pulls in every one of its ~190 language grammars. A static
  // top-level import put all of it in the CLIENT bundle — this file is the
  // page component as well as its data fetcher — making the chunk for every
  // doc route 940KB, of which 920KB was grammars the browser never runs.
  //
  // It is only needed while this fetcher runs, which under SSG is at build
  // time: the highlighted markup is baked into the static HTML. As a dynamic
  // import it becomes its own chunk that the client build emits but never
  // requests, and the route chunk drops to ~19KB.
  //
  // Deliberately not guarded with `import.meta.env.SSR` — Nitro does not
  // define it, so the guard reads as undefined on the server and silently
  // skips highlighting altogether. Every code block renders unstyled and
  // nothing errors.
  const { applyHighlighting } = await import('../../src/highlight.js');
  // src/image-size.ts reads node:fs. Imported at the top of this file those
  // builtins land in the CLIENT bundle, where Vite externalises them with a
  // warning rather than an error — the build passes and the doc page renders
  // blank in the browser. Same dynamic-import treatment as highlighting.
  const { imageSize } = await import('../../src/image-size.js');
  const body = annotateImages(
    applyHighlighting(addHeadingIds(doc.body)),
    `content/docs/${slug}.md`,
    imageSize,
  );
  const { prevDoc, nextDoc } = computePrevNext(siteConfig.sidebar, slug);
  const title = doc.title || slug;
  const description = doc.description || siteConfig.description;
  const editUrl = siteConfig.editUrlBase
    ? `${siteConfig.editUrlBase}/${slug}.md`
    : null;

  return {
    // Only the title, not the whole doc. Returning `doc` sent doc.body (the
    // un-highlighted HTML) and doc.rawBody (the Markdown source) into the
    // page's JSON payload as well, so every doc page shipped its own content
    // three times over — 11.5KB of a 20.4KB payload on getting-started.
    doc: { title: doc.title || slug },
    body,
    toc,
    sidebar: siteConfig.sidebar,
    siteTitle: siteConfig.title,
    currentSlug: slug,
    prevDoc,
    nextDoc,
    nav: siteConfig.nav,
    editUrl,
    seoTitle: buildSeoTitle(title),
    seoHead: buildSeoHead({
      title,
      description,
      path: `/docs/${slug}`,
      // A doc page is a document, not a landing page; og:type drives how
      // some readers (and Google) treat it.
      type: 'article',
    }),
  } satisfies DocPageData;
});

export async function generateRoutes(): Promise<string[]> {
  const posts = await getPosts();
  return posts
    .filter(p => p.url.startsWith('/content/docs/'))
    .map(p => '/docs' + p.url.slice('/content/docs'.length));
}

export const routeMeta = {
  head: starlightHead,
  title: 'Docs — preen',
};

@customElement('page-docs-slug')
export class DocPage extends LitroPage {
  /**
   * Styles injected into page-docs-slug's shadow root so they reach the
   * <div slot="content"> subtree. Global stylesheets (starlight.css,
   * highlight.css) cannot pierce shadow DOM boundaries.
   */
  static override styles = css`
    /* ── Typography for slotted doc content ─────────────────────────── */
    h1, h2, h3, h4, h5, h6 {
      margin-top: 1.5em; margin-bottom: 0.5em;
      font-weight: 600; line-height: 1.25;
      color: var(--sl-color-text);
    }
    h1 { font-size: var(--sl-text-4xl, 2.25rem); }
    h2 { font-size: var(--sl-text-2xl, 1.5rem); border-bottom: 1px solid var(--sl-color-border, #e8e8e8); padding-bottom: 0.25em; }
    h3 { font-size: var(--sl-text-xl, 1.25rem); }
    h4 { font-size: var(--sl-text-lg, 1.125rem); }
    p  { margin-top: 0; margin-bottom: 1rem; line-height: 1.7; }
    a  { color: var(--sl-color-text-accent, var(--sl-color-accent)); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
      font-family: var(--sl-font-mono, ui-monospace, monospace);
      font-size: 0.875em;
      background-color: var(--sl-color-bg-inline-code, #e8e8e8);
      border: 1px solid var(--sl-color-border, #e8e8e8);
      border-radius: 0.25rem;
      padding: 0.15em 0.4em;
    }
    pre {
      background-color: #0d0e11;
      color: #e2e4e9;
      border-radius: 0.375rem;
      padding: 1rem 1.25rem;
      overflow-x: auto;
      margin: 1.5rem 0;
      font-size: var(--sl-text-sm, 0.875rem);
      line-height: 1.6;
    }
    pre code { background: none; border: none; padding: 0; font-size: inherit; }
    ul, ol { padding-left: 1.5rem; margin: 0 0 1rem; }
    li { margin-bottom: 0.25rem; line-height: 1.7; }
    blockquote {
      margin: 1.5rem 0; padding: 0.75rem 1rem;
      border-left: 4px solid var(--sl-color-accent, #ea580c);
      background-color: var(--sl-color-accent-low, #fff7ed);
      border-radius: 0 0.375rem 0.375rem 0;
    }
    hr { border: none; border-top: 1px solid var(--sl-color-border, #e8e8e8); margin: 2rem 0; }
    img { max-width: 100%; height: auto; }
    table { width: 100%; border-collapse: collapse; margin: 1.5rem 0; font-size: var(--sl-text-sm, 0.875rem); }
    th, td { border: 1px solid var(--sl-color-border, #e8e8e8); padding: 0.5rem 0.75rem; text-align: left; }
    /* A long unbreakable token in a cell — an env var name, a flag, a path —
       sets the table's min-content width, and a table will not shrink below
       that. On a phone it takes the whole page sideways with it. Breaking
       mid-token is the lesser evil; without this /docs/theming pushed the
       viewport 15px wide on a 390px screen. Same family as
       beatzball/litro#137. */
    th, td { overflow-wrap: anywhere; }
    th { background-color: var(--sl-color-gray-1, #f6f6f6); font-weight: 600; }

    /* ── highlight.js fire theme ─────────────────────────────────────── */
    pre:has(.hljs) { background-color: #0d0d10; color: #cbd5e1; }
    .hljs { color: #cbd5e1; background: transparent; }
    .hljs-keyword, .hljs-selector-tag, .hljs-tag { color: #f97316; }
    .hljs-string, .hljs-attr, .hljs-attribute { color: #38bdf8; }
    .hljs-number, .hljs-literal { color: #fbbf24; }
    .hljs-title, .hljs-title.class_, .hljs-title.function_, .hljs-built_in { color: #fb923c; }
    .hljs-comment { color: #6b7280; font-style: italic; }
    .hljs-variable, .hljs-params { color: #cbd5e1; }
    .hljs-operator, .hljs-punctuation { color: #94a3b8; }
    .hljs-meta, .hljs-meta .hljs-keyword { color: #38bdf8; }
    .hljs-type { color: #fb923c; }
    .hljs-deletion { color: #f87171; background: rgba(248,113,113,.1); }
    .hljs-addition { color: #4ade80; background: rgba(74,222,128,.1); }
    .hljs-section, .hljs-selector-class, .hljs-selector-id { color: #fb923c; }
    .hljs-symbol, .hljs-bullet, .hljs-link { color: #38bdf8; }
    .hljs-emphasis { font-style: italic; }
    .hljs-strong { font-weight: bold; }
  `;

  override render() {
    const data = this.serverData as DocPageData | null;
    if (!data?.doc) return html`<p>Loading&hellip;</p>`;

    return html`
      <starlight-page
        siteTitle="${data.siteTitle}"
        pageTitle="${data.doc.title}"
        .nav="${data.nav}"
        .sidebar="${data.sidebar}"
        .toc="${data.toc}"
        currentSlug="${data.currentSlug}"
        currentPath="/docs/${data.currentSlug}"
      >
        <div slot="content">
          <!-- unsafeHTML renders the Markdown-generated HTML directly.
               The content/docs directory is trusted-author-only; do not place
               user-submitted or untrusted content here without sanitizing. -->
          ${unsafeHTML(data.body)}

          ${data.prevDoc || data.nextDoc ? html`
            <nav style="
              display:flex;
              justify-content:space-between;
              padding-top:2rem;
              margin-top:2rem;
              border-top:1px solid var(--sl-color-border);
              font-size:var(--sl-text-sm);
            " aria-label="Previous and next pages">
              ${data.prevDoc ? html`
                <a href="${data.prevDoc.href}" style="color:var(--sl-color-accent);text-decoration:none;">
                  ← ${data.prevDoc.label}
                </a>
              ` : html`<span></span>`}
              ${data.nextDoc ? html`
                <a href="${data.nextDoc.href}" style="color:var(--sl-color-accent);text-decoration:none;">
                  ${data.nextDoc.label} →
                </a>
              ` : ''}
            </nav>
          ` : ''}

          ${data.editUrl ? html`
            <p style="margin-top:1.5rem;font-size:var(--sl-text-xs);color:var(--sl-color-gray-4);">
              <a href="${data.editUrl}" style="color:var(--sl-color-accent);" target="_blank" rel="noopener">
                Edit this page
              </a>
            </p>
          ` : ''}
        </div>
      </starlight-page>
    `;
  }
}

export default DocPage;
