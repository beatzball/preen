# Kitchen Sink

A test file for terminal markdown renderers.

## Text styles

Normal, **bold**, *italic*, ***both***, ~~strikethrough~~, and `inline code`.

### Links

- Inline: [Charm](https://charm.sh)
- Reference: [mdcat][md]
- Autolink: <https://github.com/swsnr/mdcat>

[md]: https://github.com/swsnr/mdcat

## Lists

1. First item
2. Second item
   - Nested bullet
   - Another nested
     - Deeper still
3. Third item

- [x] Done task
- [ ] Open task

## Blockquote

> Terminals are just very slow web browsers.
>
> — nobody, probably

## Table

| Tool   | Language | TUI | Images | Themes |
|--------|----------|:---:|:------:|-------:|
| glow   | Go       | yes | no     |   JSON |
| mdcat  | Rust     | no  | yes    |      9 |
| bat    | Rust     | no  | no     |     24 |

## Code highlighting

```bash
#!/usr/bin/env bash
set -euo pipefail
for f in *.md; do
  glow -w 80 "$f" | less -R
done
```

```python
def fib(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```

```javascript
const render = async (path) => {
  const md = await Bun.file(path).text();
  return md.split("\n").filter(Boolean).length;
};
```

```json
{ "delta": { "side-by-side": true, "navigate": true } }
```

## Inline image

![preen rendering markdown](preen-md.png)

---

## Footnote

Terminals vary a lot.[^1]

[^1]: Image support needs kitty, iTerm2, or WezTerm.
