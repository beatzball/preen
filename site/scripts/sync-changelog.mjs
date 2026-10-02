#!/usr/bin/env node
// Copy the repository CHANGELOG.md into content/docs/changelog.md, so
// preening.dev has a "what changed" page without a second copy to maintain.
//
// The generated file is COMMITTED, not built. Coolify builds the image with
// site/ as the Docker context (see the header of site/Dockerfile), so
// ../CHANGELOG.md does not exist at build time -- generating it there would
// work locally and produce an empty page in production.
//
// Run `node scripts/sync-changelog.mjs` after editing CHANGELOG.md; CI runs
// `--check`, which fails if the two have drifted.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const SOURCE = join(here, '..', '..', 'CHANGELOG.md');
const TARGET = join(here, '..', 'content', 'docs', 'changelog.md');

const FRONTMATTER = `---
title: Changelog
description: Every released version of preen, what it added, and what it fixed.
sidebar:
  order: 8
---

<!-- GENERATED FILE — do not edit.
     Source: CHANGELOG.md at the repository root.
     Regenerate: cd site && node scripts/sync-changelog.mjs -->
`;

function render() {
  const raw = readFileSync(SOURCE, 'utf8');

  // Drop the source file's own "# Changelog" H1. The frontmatter title is
  // already rendered as the page's <h1>, and site/AGENTS.md forbids a second
  // one. Everything below it is already at ## or deeper, so nothing is
  // demoted -- the heading levels come out right by deletion alone.
  const body = raw.replace(/^#[^\n#][^\n]*\n/, '').replace(/^\n+/, '');

  return `${FRONTMATTER}\n${body.trimEnd()}\n`;
}

// The first line where the two differ, so a failure says what drifted rather
// than only that something did.
function firstDifference(found, wanted) {
  const a = found.split('\n');
  const b = wanted.split('\n');
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      const show = (s) => (s === undefined ? '(end of file)' : JSON.stringify(s));
      return `  first difference at line ${i + 1}:\n` +
        `    page has:      ${show(a[i])}\n` +
        `    CHANGELOG.md:  ${show(b[i])}`;
    }
  }
  return '';
}

const wanted = render();
const check = process.argv.includes('--check');

if (check) {
  if (!existsSync(TARGET)) {
    console.error(
      'site/content/docs/changelog.md does not exist.\n' +
        'Fix it with:  cd site && node scripts/sync-changelog.mjs',
    );
    process.exit(1);
  }
  const found = readFileSync(TARGET, 'utf8');
  if (found !== wanted) {
    console.error(
      'site/content/docs/changelog.md is out of step with CHANGELOG.md.\n' +
        firstDifference(found, wanted) + '\n' +
        'Fix it with:  cd site && node scripts/sync-changelog.mjs',
    );
    process.exit(1);
  }
  console.log('changelog.md is in step with CHANGELOG.md.');
} else {
  writeFileSync(TARGET, wanted);
  console.log(`Wrote ${TARGET}`);
}
