#!/usr/bin/env python3
"""Render a "what's new" guide (markdown on stdin) to a self-contained HTML page
(PB-129). The version comes from $PBRAIN_WN_VERSION.

This is a *marketing-style guide*, not a changelog dump: a hero, per-feature
sections that say what you can now do, and "try it" command blocks that show the
feature in action. Two input shapes are accepted, auto-detected:

  AUTHORED HIGHLIGHTS (docs/whats-new/<v>.md) — the rich path:
      # Hero headline
      > One-line tagline under the hero.

      ## Feature name
      Prose describing what you can now do, with **bold**, `code`, [links](url).
      - optional bullets

      ```bash
      # Try it — fenced code becomes a styled command card
      /some-command --flag
      ```

  CHANGELOG SECTION (fallback) — terse `### Added` + `-` bullets. Rendered as a
  simple list so a release always produces a page even without an authored file.

Supported inline markdown (both shapes): **bold**, `code`, [text](url).
The palette mirrors docs/nightly-groom-flow.html so the page looks native.
"""
import sys, os, html, re

version = os.environ.get("PBRAIN_WN_VERSION", "").strip() or "?"
md = sys.stdin.read()


def inline(s):
    s = html.escape(s)
    # Bold first, non-greedy so it spans inline `code` (which may itself contain
    # a literal *, e.g. **the `auto:*` labels**). Then code, then links.
    s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'<a href="\2">\1</a>', s)
    return s


def parse(md):
    """Return (hero, tagline, [sections]). A section is (title, [blocks]) where
    each block is ('p', html) | ('ul', [items]) | ('code', text, lang)."""
    hero, tagline, sections = None, None, []
    cur_title, cur_blocks = None, []
    buf_list, in_code, code_lang, code_lines = [], False, "", []

    def flush_list():
        if buf_list:
            cur_blocks.append(('ul', list(buf_list)))
            buf_list.clear()

    def open_section(title):
        nonlocal cur_title, cur_blocks
        flush_list()
        if cur_title is not None or cur_blocks:
            sections.append((cur_title, cur_blocks))
        cur_title, cur_blocks = title, []

    for raw in md.splitlines():
        line = raw.rstrip("\n")
        fence = line.strip()
        if fence.startswith("```"):
            if not in_code:
                flush_list()
                in_code, code_lang, code_lines = True, fence[3:].strip(), []
            else:
                cur_blocks.append(('code', "\n".join(code_lines), code_lang))
                in_code = False
            continue
        if in_code:
            code_lines.append(line)
            continue

        s = line.strip()
        if not s:
            flush_list()
            continue
        if s.startswith("# ") and hero is None and cur_title is None and not sections:
            hero = s[2:].strip()
        elif s.startswith("> ") and tagline is None and not sections and cur_title is None:
            tagline = s[2:].strip()
        elif s.startswith("## "):
            open_section(s[3:].strip())
        elif s.startswith("### "):
            # changelog-fallback heading → treat as a section
            open_section(s[4:].strip())
        elif s.startswith("- "):
            buf_list.append(s[2:])
        else:
            flush_list()
            cur_blocks.append(('p', s))
    flush_list()
    if cur_title is not None or cur_blocks:
        sections.append((cur_title, cur_blocks))
    return hero, tagline, sections


hero, tagline, sections = parse(md)
hero = hero or "What's new in pbrain"
tagline = tagline or f"Release {version}"


def render_blocks(blocks):
    out = []
    for b in blocks:
        if b[0] == 'p':
            out.append("<p>%s</p>" % inline(b[1]))
        elif b[0] == 'ul':
            items = "".join("<li>%s</li>" % inline(x) for x in b[1])
            out.append("<ul>%s</ul>" % items)
        elif b[0] == 'code':
            label = "Try it" if not b[2] or b[2] in ("bash", "sh", "shell") else html.escape(b[2])
            out.append(
                '<div class="card"><div class="card-h">%s</div><pre>%s</pre></div>'
                % (label, html.escape(b[1])))
    return "\n".join(out)


section_html = []
for title, blocks in sections:
    inner = render_blocks(blocks)
    if title:
        section_html.append('<section><h2>%s</h2>%s</section>' % (inline(title), inner))
    else:
        section_html.append('<section>%s</section>' % inner)
body = "\n".join(section_html) or "<p>See the changelog for details.</p>"

print(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pbrain v{version} — what's new</title>
<style>
  :root{{
    --bg:#0b0e14; --panel:#141a23; --panel2:#1b232f; --line:#2a3340;
    --ink:#e6edf3; --dim:#9aa6b2; --acc:#58a6ff; --good:#3fb950;
    --mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace;
    --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;
  }}
  *{{box-sizing:border-box}}
  body{{margin:0;background:var(--bg);color:var(--ink);
    font-family:var(--sans);line-height:1.65;font-size:15px}}
  .wrap{{max-width:720px;margin:0 auto;padding:56px 24px 100px}}
  .tag{{display:inline-block;font-family:var(--mono);font-size:12px;
    color:var(--good);border:1px solid var(--line);border-radius:999px;
    padding:4px 12px;margin-bottom:18px}}
  h1{{font-size:34px;line-height:1.15;margin:0 0 12px;letter-spacing:-.02em}}
  .lede{{color:var(--dim);font-size:18px;margin:0 0 14px;line-height:1.5}}
  .hr{{height:1px;background:var(--line);border:0;margin:36px 0}}
  section{{margin:0 0 34px}}
  h2{{font-size:20px;margin:0 0 10px;letter-spacing:-.01em}}
  ul{{margin:10px 0 16px;padding-left:20px}}
  li{{margin:0 0 7px}}
  p{{margin:0 0 14px}}
  code{{font-family:var(--mono);font-size:.86em;background:var(--panel2);
    border:1px solid var(--line);border-radius:4px;padding:1px 5px}}
  a{{color:var(--acc);text-decoration:none}}
  a:hover{{text-decoration:underline}}
  strong{{color:#fff}}
  .card{{background:var(--panel);border:1px solid var(--line);
    border-radius:10px;overflow:hidden;margin:14px 0 18px}}
  .card-h{{font-family:var(--mono);font-size:11px;letter-spacing:.08em;
    text-transform:uppercase;color:var(--good);
    background:var(--panel2);border-bottom:1px solid var(--line);
    padding:7px 14px}}
  .card pre{{margin:0;padding:14px;overflow-x:auto;font-family:var(--mono);
    font-size:13px;line-height:1.55;color:var(--ink)}}
  .foot{{margin-top:46px;padding-top:18px;border-top:1px solid var(--line);
    color:var(--dim);font-size:13px}}
</style>
</head>
<body>
  <div class="wrap">
    <span class="tag">v{version}</span>
    <h1>{inline(hero)}</h1>
    <p class="lede">{inline(tagline)}</p>
    <hr class="hr">
    {body}
    <div class="foot">
      Full history in the
      <a href="https://github.com/baymac/pbrain/blob/main/CHANGELOG.md">changelog</a>.
      Update any time with <code>/plugin update pbrain</code>.
    </div>
  </div>
</body>
</html>""")
