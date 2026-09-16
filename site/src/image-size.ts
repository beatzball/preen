/**
 * Intrinsic pixel size of a WebP or PNG, read straight out of its header.
 *
 * **Server only.** It reaches for node:fs and node:path, so importing it from
 * the top of a page module puts those in the client bundle too — Vite then
 * externalizes them with a warning rather than an error, the build still
 * passes, and the doc page renders blank in the browser. Reach it with an
 * `await import()` from inside a pageData fetcher, the same way
 * src/highlight.ts is reached, and let the stub in vite.config.ts keep it out
 * of the client build entirely.
 */
import { readFileSync, existsSync } from 'node:fs';
import { resolve, sep } from 'node:path';

/**
 * Where public/ is, from whichever directory the build happens to run in.
 *
 * dev runs from site/, the prerender pass can run from the repo root, and the
 * server bundle sees a copy under dist/. Each candidate is tried rather than
 * assumed.
 */
export const PUBLIC_DIR =
  ['public', 'site/public', 'dist/server/public'].map((d) => resolve(d)).find((d) => existsSync(d)) ??
  resolve('public');

export interface ImageSize {
  w: number;
  h: number;
}

/**
 * The file under public/ that a Markdown `src` names, or null if it names
 * none.
 *
 * A src is a URL, not a path, so three things have to come off it first, and
 * every one of them is the difference between "this image is fine" and "this
 * build stops" now that the caller treats null as a failure.
 *
 * - **`?v=2` and `#frag`.** A cache buster and a fragment name the same bytes;
 *   readFileSync misses with either still attached.
 * - **Percent-encoding.** A space is `%20` and an accent is `%C3%A9`, which is
 *   what Markdown emits for BOTH `![x](/my%20shot.webp)` and the angle-bracket
 *   form `![x](</my shot.webp>)`. Undecoded, a file that exists on disk and
 *   serves fine over HTTP reads as unmeasurable.
 * - **A `..` segment.** resolve() would read it happily from outside public/,
 *   and a size taken from a file nginx is going to 404 is worse than no size:
 *   the build passes on a page that is already broken.
 *
 * decodeURIComponent throws URIError on a `%` that is not an escape, and a
 * file may legitimately be called `50%.webp`, so the decode is attempted and
 * the raw spelling is kept as a fallback rather than replaced. Both are tried,
 * decoded first: an author whose filename really does contain `%20` still gets
 * a hit, and nothing here can throw.
 */
function fileFor(src: string): string | null {
  const bare = src.replace(/[?#].*$/, '').replace(/^\//, '');

  const spellings = [bare];
  try {
    const decoded = decodeURIComponent(bare);
    if (decoded !== bare) spellings.unshift(decoded);
  } catch {
    // A lone `%`. The raw spelling is the only candidate, which is correct —
    // a name with a bare percent in it cannot have been encoded.
  }

  const root = resolve(PUBLIC_DIR);
  for (const spelling of spellings) {
    const full = resolve(root, spelling);
    if (full !== root && !full.startsWith(root + sep)) continue;
    if (existsSync(full)) return full;
  }
  return null;
}

/**
 * Returns null for anything unrecognized or unreadable. A wrong number is
 * worse than none, so there is no guessing here — but null is now a build
 * failure at the call site rather than a silently unsized image. See
 * annotateImages in pages/docs/[slug].ts.
 */
export function imageSize(src: string): ImageSize | null {
  const size = readHeader(src);
  // Zero is a wrong number, and a wrong number is the one thing this module
  // promises not to return. A corrupt PNG IHDR or VP8 header reads as 0×0 —
  // those two store the dimensions as they are, while VP8X and VP8L store
  // them minus one and so cannot express zero at all — and `{w:0,h:0}` is
  // truthy, so without this the caller emits width="0" height="0": a box the
  // browser reserves at nothing and never corrects. Measured on a PNG whose
  // IHDR was zeroed; see the pull request.
  return size && size.w > 0 && size.h > 0 ? size : null;
}

function readHeader(src: string): ImageSize | null {
  const file = fileFor(src);
  if (!file) return null;

  let buf: Buffer;
  try {
    buf = readFileSync(file);
  } catch {
    return null;
  }

  // PNG: IHDR is always the first chunk, width and height big-endian at 16.
  if (buf.length > 24 && buf.toString('ascii', 1, 4) === 'PNG') {
    return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
  }

  if (
    buf.length > 30 &&
    buf.toString('ascii', 0, 4) === 'RIFF' &&
    buf.toString('ascii', 8, 12) === 'WEBP'
  ) {
    const kind = buf.toString('ascii', 12, 16);
    // VP8X is the extended header an animated file carries; canvas size is
    // stored minus one, in three little-endian bytes each.
    if (kind === 'VP8X') {
      return {
        w: (buf[24] | (buf[25] << 8) | (buf[26] << 16)) + 1,
        h: (buf[27] | (buf[28] << 8) | (buf[29] << 16)) + 1,
      };
    }
    if (kind === 'VP8 ') {
      return { w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff };
    }
    // VP8L packs 14-bit width and height, each minus one, into four bytes.
    if (kind === 'VP8L') {
      const bits = buf.readUInt32LE(21);
      return { w: (bits & 0x3fff) + 1, h: ((bits >> 14) & 0x3fff) + 1 };
    }
  }
  return null;
}
