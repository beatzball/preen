import { css, html } from 'lit';
import { customElement } from 'lit/decorators.js';
import { LitroPage } from '@beatzball/litro/runtime';
import { definePageData } from '@beatzball/litro';
import { getGlobalData } from 'litro:content';
import { siteConfig } from '../server/starlight.config.js';
import { starlightHead } from '../src/route-meta.js';
import { buildSeoHead, buildSeoTitle } from '../src/seo.js';

// Register components used in render()
import '../src/components/starlight-header.js';
import '../src/components/litro-card.js';
import '../src/components/litro-card-grid.js';
import '../src/components/litro-footer.js';

/**
 * Install, then the first thing to run. Kept in step with the Install and
 * First run sections of content/docs/getting-started.md.
 */
const INSTALL_STEPS = [
  {
    note: 'install (clones preen and links it into ~/.local/bin)',
    cmd: 'curl -fsSL https://raw.githubusercontent.com/beatzball/preen/main/install.sh | bash',
  },
  { note: 'diffs in a git repo, markdown anywhere else', cmd: 'preen' },
] as const;

/**
 * What you can point it at. One line each, in the order someone meets them:
 * the two everyday ones, then the two read-only review modes, then pipes.
 * Kept in step with the command list in content/docs/getting-started.md.
 */
const MODES = [
  { cmd: 'preen diff', what: 'Browse what you have not committed. Staged and unstaged together.', href: '/docs/browsing' },
  { cmd: 'preen md', what: 'Browse every markdown file under a directory.', href: '/docs/browsing' },
  { cmd: 'preen pr 42', what: 'Review a GitHub PR. No checkout, one network call.', href: '/docs/pull-requests' },
  { cmd: 'preen wt', what: 'Pick a worktree and see what the agent changed.', href: '/docs/worktrees' },
  { cmd: 'git diff | preen', what: 'Pipe anything in. It works out which renderer to use.', href: '/docs/pipes' },
] as const;

/** The three tools that do the actual rendering. preen is the glue. */
const TOOLS = [
  { name: 'glow', job: 'renders the markdown', href: 'https://github.com/charmbracelet/glow' },
  { name: 'delta', job: 'renders the diffs', href: 'https://github.com/dandavison/delta' },
  { name: 'fzf', job: 'does the file navigation', href: 'https://github.com/junegunn/fzf' },
] as const;

export interface SplashData {
  siteTitle: string;
  description: string;
  nav: Array<{ label: string; href: string }>;
  features: Array<{ title: string; description: string; icon?: string }>;
  /**
   * Raw <head> HTML. Litro injects this and strips it from the JSON payload
   * before serializing — it contains no </script>, but the framework treats
   * the key specially regardless. See src/seo.ts.
   */
  seoHead: string;
  /** Overrides routeMeta.title, which cannot vary per request. */
  seoTitle: string;
}

export const pageData = definePageData(async (_event) => {
  const metadata = await getGlobalData();
  const siteTitle = String(metadata.title ?? siteConfig.title);
  const description = String(metadata.description ?? siteConfig.description);

  return {
    siteTitle,
    description,
    seoTitle: buildSeoTitle(siteTitle),
    seoHead: buildSeoHead({ title: siteTitle, description, path: '/' }),
    nav: siteConfig.nav,
    // Six, not five or seven. The grid is auto-fit at a 16rem minimum inside a
    // 56rem column, which resolves to three across at every width that fits
    // more than one — so only a multiple of three fills its last row.
    features: [
      {
        icon: '🪶',
        title: 'Thin glue',
        description: 'One bash script over three tools that already do the hard part. No daemon, no binary, no plugin manager.',
      },
      {
        icon: '👀',
        title: 'Read-only review',
        description: 'PR and worktree modes never checkout, fetch or stash. Your half-finished work stays exactly where it is.',
      },
      {
        icon: '🎨',
        title: 'One palette',
        description: 'glow and delta ship the same theme, so a markdown preview and a diff preview look like one tool.',
      },
      {
        icon: '🔀',
        title: 'Pipe-friendly',
        description: 'It sniffs what you piped in and picks the renderer. Color survives into a file, not just a terminal.',
      },
      {
        icon: '⌨️',
        title: 'Flip the layout live',
        description: 'ctrl-s swaps side-by-side and inline mid-review, on the file you are already looking at.',
      },
      {
        icon: '🔗',
        title: 'Wired into git',
        description: 'The installer registers git preen and git difftool -t preen, and takes both back out again on uninstall.',
      },
    ],
  } satisfies SplashData;
});

export const routeMeta = {
  head: starlightHead,
  title: 'preen',
};

@customElement('page-home')
export class SplashPage extends LitroPage {
  /**
   * Local workaround for beatzball/litro#137 — remove once the recipe ships
   * its own reset.
   *
   * The `box-sizing: border-box` reset lives in public/styles/starlight.css,
   * which is a document stylesheet and so does not cross into this
   * component's shadow root. Without it the <main> below computes as
   * content-box: `width:100%` resolves to the full viewport and the 1.5rem
   * side padding is added on top, putting the page 48px wider than the screen
   * on every phone. Invisible above ~900px, where `max-width:56rem` caps
   * <main> before the padding can matter.
   *
   * litro.dev works around the same bug by dropping the horizontal padding
   * from <main> entirely. That trades the overflow for content sitting flush
   * against the screen edge; resetting box-sizing keeps the gutters.
   */
  static override styles = css`
    :host {
      display: block;
    }

    *,
    *::before,
    *::after {
      box-sizing: border-box;
    }
  `;

  override render() {
    const data = this.serverData as SplashData | null;
    const { siteTitle = 'preen', description = '', nav = [], features = [] } = data ?? {};

    return html`
      <div style="min-height:100vh;display:flex;flex-direction:column;">
        <starlight-header
          siteTitle="${siteTitle}"
          .nav="${nav}"
          currentPath="/"
        ></starlight-header>
        <main style="
          flex:1;
          max-width:56rem;
          margin:0 auto;
          padding:4rem 1.5rem 3rem;
          width:100%;
        ">
          <section style="text-align:center;margin-bottom:3.5rem;">
            <img
              src="/logo.webp"
              alt=""
              width="160"
              height="160"
              style="
                display:block;
                margin:0 auto 1.5rem;
                width:clamp(96px,18vw,160px);
                height:auto;
              "
            />
            <h1 style="
              font-size:clamp(2rem,5vw,3.5rem);
              font-weight:800;
              color:var(--sl-color-text);
              margin:0 0 1rem;
              line-height:1.1;
            ">${siteTitle}</h1>
            ${description ? html`
              <p style="
                font-size:var(--sl-text-xl);
                color:var(--sl-color-gray-4);
                max-width:36rem;
                margin:0 auto 2.5rem;
                line-height:1.6;
              ">${description}</p>
            ` : ''}
            <div style="display:flex;gap:1rem;justify-content:center;flex-wrap:wrap;">
              <a href="/docs/getting-started" style="
                display:inline-block;
                padding:0.6rem 1.5rem;
                background:var(--sl-color-accent);
                color:var(--sl-color-text-invert,#fff);
                border-radius:var(--sl-border-radius);
                font-weight:600;
                text-decoration:none;
                font-size:var(--sl-text-base);
              ">Get Started</a>
              <a href="https://github.com/beatzball/preen" style="
                display:inline-block;
                padding:0.6rem 1.5rem;
                border:1px solid var(--sl-color-border);
                color:var(--sl-color-text);
                border-radius:var(--sl-border-radius);
                font-weight:600;
                text-decoration:none;
                font-size:var(--sl-text-base);
              ">GitHub</a>
            </div>
            <!-- The name is the joke, so it lands after the reader has already
                 decided whether to click. -->
            <p style="
              font-size:var(--sl-text-base);
              color:var(--sl-color-gray-4);
              max-width:36rem;
              margin:1.75rem auto 0;
              line-height:1.6;
              font-style:italic;
            ">Birds preen to tidy their feathers. You preen your diff before you commit.</p>
          </section>

          <!-- The recording carries the whole pitch faster than any paragraph.
               Kept in step with demo/preen.tape — re-check the alt text when
               that tape changes what it records. -->
          <section style="margin-bottom:3.5rem;">
            <img
              src="/preen.webp"
              alt="preen picking a git worktree, then browsing what it changed"
              width="1400"
              height="620"
              loading="lazy"
              decoding="async"
              style="
                display:block;
                width:100%;
                /* Required, because of the width/height attributes above.
                   Those reserve the right box before the image loads, but the
                   width:100% here overrides only the width half of the pair.
                   Without this line the height attribute stands and the
                   recording is squashed to 620px tall at every viewport. */
                height:auto;
                max-width:48rem;
                margin:0 auto;
                border:1px solid var(--sl-color-border);
                border-radius:var(--sl-border-radius);
              "
            />
          </section>

          <!-- preen renders nothing itself. Saying so up front is the honest
               pitch, and it tells a reader what they are actually installing. -->
          <section style="margin-bottom:3.5rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 0.5rem;
              text-align:center;
            ">Built on three great tools</h2>
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              margin:0 0 1.5rem;
            ">preen renders nothing itself. It is the glue, and the shared theme.</p>
            <div style="
              display:grid;
              grid-template-columns:repeat(auto-fit,minmax(13rem,1fr));
              gap:0.75rem;
              max-width:44rem;
              margin:0 auto;
            ">
              ${TOOLS.map(
                (t) => html`
                  <a href="${t.href}" style="
                    padding:1rem;
                    border:1px solid var(--sl-color-border);
                    border-radius:var(--sl-border-radius);
                    display:flex;
                    flex-direction:column;
                    gap:0.35rem;
                    text-decoration:none;
                  ">
                    <span style="
                      font-family:var(--sl-font-mono,ui-monospace,monospace);
                      font-weight:700;
                      color:var(--sl-color-text-accent,var(--sl-color-accent));
                      font-size:var(--sl-text-base);
                    ">${t.name}</span>
                    <span style="
                      color:var(--sl-color-gray-4);
                      font-size:var(--sl-text-sm);
                      line-height:1.5;
                    ">${t.job}</span>
                  </a>
                `,
              )}
            </div>
          </section>

          <!-- Install and first run: two lines, so the landing page answers
               "how do I start" without a click. -->
          <section style="margin-bottom:3.5rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 1rem;
              text-align:center;
            ">Get running</h2>
            <div style="
              background:var(--sl-color-bg-inline-code,#f6f6f6);
              border:1px solid var(--sl-color-border);
              border-radius:var(--sl-border-radius);
              padding:1.25rem 1.5rem;
              overflow-x:auto;
              max-width:44rem;
              margin:0 auto;
            ">
              <pre style="margin:0;font-size:var(--sl-text-sm);line-height:1.9;"><code>${INSTALL_STEPS.map(
                (step) => html`<span style="color:var(--sl-color-gray-4);"># ${step.note}</span>
<span style="color:var(--sl-color-text);">${step.cmd}</span>
`,
              )}</code></pre>
            </div>
          </section>

          <!-- What you can point it at. Every row links to the page that
               covers it, so this doubles as the table of contents. -->
          <section style="margin-bottom:3.5rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 1.5rem;
              text-align:center;
            ">Five things to point it at</h2>
            <div style="display:grid;gap:0.75rem;max-width:44rem;margin:0 auto;">
              ${MODES.map(
                (m) => html`
                  <a href="${m.href}" style="
                    display:flex;
                    align-items:baseline;
                    gap:1rem;
                    flex-wrap:wrap;
                    padding:0.75rem 1rem;
                    border:1px solid var(--sl-color-border);
                    border-radius:var(--sl-border-radius);
                    text-decoration:none;
                  ">
                    <code style="
                      flex-shrink:0;
                      font-family:var(--sl-font-mono,ui-monospace,monospace);
                      font-size:var(--sl-text-sm);
                      background:var(--sl-color-bg-inline-code,#f6f6f6);
                      border:1px solid var(--sl-color-border);
                      border-radius:0.25rem;
                      padding:0.15rem 0.5rem;
                      white-space:nowrap;
                      color:var(--sl-color-text-accent,var(--sl-color-accent));
                    ">${m.cmd}</code>
                    <span style="color:var(--sl-color-text);font-size:var(--sl-text-base);">
                      ${m.what}
                    </span>
                  </a>
                `,
              )}
            </div>
          </section>

          <section>
            <litro-card-grid>
              ${features.map(f => html`
                <litro-card
                  icon="${f.icon ?? ''}"
                  title="${f.title}"
                  description="${f.description}"
                ></litro-card>
              `)}
            </litro-card-grid>
          </section>
        </main>
        <litro-footer recipe="starlight"></litro-footer>
      </div>
    `;
  }
}

export default SplashPage;
