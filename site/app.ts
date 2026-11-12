/**
 * Client entry: a two-statement bootstrap. Keep it that way.
 *
 * Its only job is to install Lit's hydration support before any Lit code runs.
 * Everything else lives in app-main.ts, behind a DYNAMIC import.
 *
 * The hydrate-support module patches nothing itself. It only sets
 * `globalThis.litElementHydrateSupport`, and `lit-element` reads that hook
 * once, when its own module body runs. If `lit-element` runs first, the hook
 * is missed for good: the browser throws away every server-rendered page and
 * draws it again. litro 0.17.4 and later log a console.error when that
 * happens, and the e2e suite fails on any console.error (checked by putting
 * an import of lit above the hook).
 *
 * Putting the hook import first is not a guarantee. A module's static imports
 * all run before its body, and litro reports that from Vite 8.1.6 the bundler
 * can put `lit-element` in a chunk the entry imports statically. The old
 * single-file entry still hydrated on this site when it was replaced, but a
 * dynamic import cannot be hoisted, so this shape cannot break that way. It is
 * the shape the litro starlight recipe ships (litro BUILD-009), and the one
 * litroEntryPlugin() in vite.config.ts is written for.
 *
 * So a new `import` line belongs in app-main.ts, never here.
 */

// Statement 1: set the hydration hook.
import '@lit-labs/ssr-client/lit-element-hydrate-support.js';

// Statement 2: the real entry, which may now load Lit.
void import('./app-main.js');
