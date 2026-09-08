/**
 * /__og/**.png — the share card behind every og:image on this site.
 *
 * Litro renders these with Satori (HTML/CSS -> SVG) and resvg (SVG -> PNG).
 * In SSG the whole set is prerendered: ogPrerenderHook() in nitro.config.ts
 * adds one /__og/<route>.png entry per page, so the built site ships static
 * PNGs and nothing is generated at request time.
 */
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { createOgHandler } from '@beatzball/litro/runtime/og-handler.js';
import { defaultOgTemplate, type OgTemplate } from '@beatzball/litro/runtime/og-template.js';
import { routes, pageModules } from '#litro/page-manifest';

/**
 * The default template draws the logo in a 36px box, which suits a mark that
 * fills its square — roost's owl does. preen's feather is tall and narrow, so
 * at 36px its actual ink is only about a third of the width and it reads as a
 * smudge next to the 24px site name.
 *
 * The template is not parameterised for this, so rather than fork the whole
 * card, take what the default builds and enlarge the one <img> in it. The top
 * row is `alignItems: center`, so a taller box stays centred on the name.
 */
const LOGO_SIZE = 64;

/** Depth-first: the card is a small tree of `{ type, props: { children } }`. */
function enlargeLogo(node: unknown, size: number): void {
  if (!node || typeof node !== 'object') return;
  const n = node as { type?: string; props?: Record<string, unknown> };
  if (n.type === 'img' && n.props) {
    n.props.width = size;
    n.props.height = size;
  }
  const children = n.props?.children;
  if (Array.isArray(children)) children.forEach((c) => enlargeLogo(c, size));
  else if (children) enlargeLogo(children, size);
}

const template: OgTemplate = (input) => {
  const card = defaultOgTemplate(input);
  enlargeLogo(card, LOGO_SIZE);
  return card;
};

/**
 * The logo has to be inlined as a data URI — Satori cannot fetch a URL.
 *
 * The working directory is not the same in every mode (dev runs from site/,
 * the prerender pass can run from the repo root), so each candidate is tried
 * rather than assumed. A missing logo is not fatal: the card just loses its
 * mark.
 */
function loadLogoDataUri(): string | undefined {
  const candidates = [
    resolve('public/logo.png'),
    resolve('site/public/logo.png'),
    resolve('dist/server/public/logo.png'),
  ];
  for (const p of candidates) {
    if (existsSync(p)) {
      return `data:image/png;base64,${readFileSync(p).toString('base64')}`;
    }
  }
  return undefined;
}

export default createOgHandler({
  siteName: 'preen',
  // Matches --sl-color-accent in the site's dark theme.
  accentColor: '#a78bfa',
  logoDataUri: loadLogoDataUri(),
  template,
  routes,
  pageModules,
});
