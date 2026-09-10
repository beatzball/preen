# preen docs site — agent instructions

This directory is the source for **https://preening.dev**. It is a Litro
`starlight` site in SSG mode: Markdown in, static HTML out.

Read this before changing anything in `site/`.

## Where things live

| Path | What it is |
|------|-----------|
| `content/docs/*.md` | Every documentation page. One file = one page. |
| `server/starlight.config.js` | Site title, top nav, and the sidebar tree. |
| `_data/metadata.js` | Site title, canonical URL, description (used for SEO and OG images). |
| `pages/index.ts` | The landing page (a Lit component, not Markdown). |
| `pages/docs/[slug].ts` | The doc page template. Do not edit to add a page. |
| `src/seo.ts` | Per-page description, canonical, Open Graph and Twitter tags. |
| `src/components/` | Shared UI. Rarely needs touching. |
| `public/` | Icons, and the demo recordings as WebP. See below. |
| `sync-assets.sh` | Rebuilds those from the GIFs in `demo/`. |
| `Dockerfile`, `nginx.conf` | Deploy. Coolify builds these on push to `main`. |

## Add a documentation page

1. Create `content/docs/<slug>.md`. The filename becomes the URL:
   `content/docs/foo.md` → `/docs/foo`.

2. Give it frontmatter. `title` and `description` are required:

   ```markdown
   ---
   title: Your Page Title
   description: One sentence. It is used for SEO and the OG image.
   sidebar:
     order: 8
   ---

   ## First heading

   Body starts here.
   ```

3. Add it to the sidebar in `server/starlight.config.js`. A page not listed
   there is still reachable by URL but invisible in the nav:

   ```js
   { label: 'Your Page Title', slug: 'your-page-slug' },
   ```

4. Add the route to `PRERENDERED_ROUTES` in `e2e/index.spec.ts`.

5. Build to verify (see below).

## Rules

- **Start the body at `##`, not `#`.** The `title` from frontmatter is already
  rendered as the page's `<h1>`. A `#` in the body makes a second one.
- **Slugs must be unique across the whole `content/` directory.** The build
  throws on a collision rather than silently dropping a page.
- **Internal links are absolute paths**: `/docs/pipes`, not `pipes.md`.
- **Do not edit `routes.generated.ts` or `server/stubs/page-manifest.ts`.**
  Both are regenerated on every build and are gitignored.
- **This site is for users. The repo `README.md` is for contributors.**
  Install and usage instructions belong here; recording the demo, the notes on
  why glow 3 is required, and anything else aimed at people hacking on preen
  belong in the README. Do not duplicate one into the other — link instead.

## The demo recordings

`public/*.webp` are built from the GIFs in `demo/`. Run this after `vhs`
regenerates any tape:

```sh
./sync-assets.sh     # needs `brew install webp`
```

Nothing fails if you forget. The site just keeps serving the old recording.

Two things that script is doing, both of which matter:

- **It copies.** Coolify builds with its Base Directory set to `/site`, so
  `../demo` does not exist inside the Docker build context. Anything a page
  loads has to be committed under `site/public/`.
- **It converts to WebP.** The recordings are the heaviest thing the site
  serves — `preen.gif` alone was 531KB against 65KB for all the HTML, CSS and
  JavaScript on a doc page put together. As animated WebP the same recording
  is 192KB, and the terminal text stays sharp because `-mixed` lets the
  encoder choose lossless per frame.

`demo/` keeps the GIFs: the README renders on GitHub, which wants a GIF, and
that is what `vhs` emits anyway. Only the site takes the WebP. **Pages must
reference the `.webp` names**, not the `.gif` ones.

The same script also derives `public/logo.webp` from `public/logo.png`, which
is why it is the one asset here that does not come from `demo/`. Both files
stay: the pages load the WebP, while the PNG is what the favicon set is cut
from and what the OG handler inlines as a data URI at build time. The PNG is
therefore never served to a browser. **Regenerate the WebP whenever the logo
changes**, or the site keeps showing the old mark.

### Images are lazy below the first one

`pages/docs/[slug].ts` rewrites the rendered Markdown so every image except
the first carries `loading="lazy" decoding="async"`. Markdown image syntax
cannot carry an attribute, and the first image is usually above the fold, so
deferring it would delay the one thing the reader is waiting for.

Nothing to do when adding a page. A hand-written `<img>` that sets its own
`loading` is left alone.

## Verify your change

```sh
cd site
pnpm install        # first time only
pnpm build          # must exit 0; prints every prerendered route
```

`pnpm build` is the real check. It fails on a duplicate slug, a missing
`title`, or a broken component, and it prints the full route list so you can
confirm your page is there.

For a live-reload loop while writing:

```sh
pnpm dev            # http://localhost:3000
```

End-to-end checks:

```sh
pnpm test:e2e            # both targets, in order
pnpm test:e2e:dev        # just `litro dev`
pnpm test:e2e:preview    # just the built output (rebuilds dist/ first)
```

The same specs run twice, against two different renderers. `dev` is Vite
serving modules from source; `preview` is the prerendered `dist/static` that
nginx ships in production. `preview` is the only check that opens what actually
ships, and what it catches on its own is client code that behaves differently
in the two builds — anything behind `import.meta.env.PROD`, anything the
minifier or tree-shaker rewrites. A build exits 0 and the route answers 200
either way, so nothing else in CI notices.

They run one after the other, never together, because `litro dev` deletes
`dist/` on startup and that is the directory `litro preview` serves.

**`dist/` is current only after the `preview` half has run**, because building
it is the first half of that target's server command. If you ran
`pnpm test:e2e:dev` on its own, or the `pnpm test:e2e` chain stopped when the
dev half failed, then `dist/static` is **empty** — and `litro preview` prints
its usual `Previewing static build at …` banner over it and serves 404 for
every route. Run `pnpm build` before you trust a preview.

**Do not check the built output with `python3 -m http.server`.** It serves
`/_litro/app.js` with a MIME type Chrome rejects for a module script, so every
page comes up blank with nothing in the console. That is the server, not the
site. Use `pnpm preview`, or the Docker image below.

## Deploy

Push to `main`. Coolify rebuilds from `site/Dockerfile` and serves
`dist/static` behind nginx. There is nothing to run by hand.

To check the deploy locally exactly as production runs it:

```sh
cd site
docker build -t preen-docs .
docker run --rm -p 8099:80 preen-docs
# then open http://localhost:8099
```
