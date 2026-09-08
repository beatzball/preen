/**
 * Intrinsic pixel size of a WebP or PNG, read straight out of its header.
 *
 * **Server only.** It reaches for node:fs and node:path, so importing it from
 * the top of a page module puts those in the client bundle too — Vite then
 * externalises them with a warning rather than an error, the build still
 * passes, and the doc page renders blank in the browser. Reach it with an
 * `await import()` from inside a pageData fetcher, the same way
 * src/highlight.ts is reached, and let the stub in vite.config.ts keep it out
 * of the client build entirely.
 */
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

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
 * Returns null for anything unrecognised or unreadable; the caller then omits
 * the attributes rather than guessing at them.
 */
export function imageSize(src: string): ImageSize | null {
  let buf: Buffer;
  try {
    buf = readFileSync(resolve(PUBLIC_DIR, src.replace(/^\//, '')));
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
