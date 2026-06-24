#!/usr/bin/env python3
"""Render a "what's new" guide (markdown on stdin) to a self-contained HTML page
(PB-129). The version comes from $PBRAIN_WN_VERSION.

This is a *marketing-style guide*, not a changelog dump: a hero, scannable
feature sections, a pipeline diagram, "try it" command cards, and a coverage
table so every change is visible at a glance. Two input shapes auto-detect:

  AUTHORED HIGHLIGHTS (docs/whats-new/<v>.md) — the rich path. Vocabulary:
      # Hero headline
      > One-line tagline.

      ## Section name
      Prose with **bold**, `code`, [links](url).
      - bullets

      ```flow
      plan -> implement -> test -> ship -> land
      ```                         → a connected-chip pipeline diagram

      ```bash
      /some-command --flag
      ```                         → a "try it" command card

      | Command | What changed | Try |          → a styled table
      |---|---|---|
      | `/x` | does y | `cmd` |

  CHANGELOG SECTION (fallback) — terse `### Added` + `-` bullets, rendered as a
  simple list so a release always produces a page.

Palette mirrors docs/nightly-groom-flow.html so the page looks native.
"""
import sys, os, html, re

version = os.environ.get("PBRAIN_WN_VERSION", "").strip() or "?"
md = sys.stdin.read()


def inline(s):
    s = html.escape(s)
    # Bold first (non-greedy, may span inline `code`), then code, then links.
    s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'<a href="\2">\1</a>', s)
    return s


def is_table_sep(line):
    return bool(re.match(r'^\s*\|?\s*:?-{2,}.*$', line)) and '|' in line and set(line.strip()) <= set('|:- ')


def split_row(line):
    line = line.strip()
    if line.startswith('|'):
        line = line[1:]
    if line.endswith('|'):
        line = line[:-1]
    return [c.strip() for c in line.split('|')]


def parse(md):
    """Return (hero, tagline, [sections]); each section is (title, [blocks]).
    Blocks: ('p',html) ('ul',[items]) ('code',text,lang) ('flow',[stages])
            ('table',[headers],[[rows]])."""
    hero = tagline = None
    sections = []
    cur_title, cur_blocks = None, []
    buf_list = []
    in_code = False
    code_lang, code_lines = "", []
    lines = md.splitlines()

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

    i = 0
    while i < len(lines):
        raw = lines[i].rstrip("\n")
        fence = raw.strip()

        if fence.startswith("```"):
            if not in_code:
                flush_list()
                in_code, code_lang, code_lines = True, fence[3:].strip().lower(), []
            else:
                if code_lang == "flow":
                    stages = [s.strip() for s in re.split(r'->|→', "\n".join(code_lines)) if s.strip()]
                    cur_blocks.append(('flow', stages))
                else:
                    cur_blocks.append(('code', "\n".join(code_lines), code_lang))
                in_code = False
            i += 1
            continue
        if in_code:
            code_lines.append(raw)
            i += 1
            continue

        s = raw.strip()

        # table: a header row followed by a separator row
        if '|' in s and i + 1 < len(lines) and is_table_sep(lines[i + 1]):
            flush_list()
            headers = split_row(s)
            rows = []
            i += 2
            while i < len(lines) and '|' in lines[i] and lines[i].strip():
                rows.append(split_row(lines[i]))
                i += 1
            cur_blocks.append(('table', headers, rows))
            continue

        if not s:
            flush_list()
        elif s.startswith("# ") and hero is None and cur_title is None and not sections:
            hero = s[2:].strip()
        elif s.startswith("> ") and tagline is None and not sections and cur_title is None:
            tagline = s[2:].strip()
        elif s.startswith("## "):
            open_section(s[3:].strip())
        elif s.startswith("### "):
            open_section(s[4:].strip())
        elif s.startswith("- "):
            buf_list.append(s[2:])
        else:
            flush_list()
            cur_blocks.append(('p', s))
        i += 1

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
        kind = b[0]
        if kind == 'p':
            out.append("<p>%s</p>" % inline(b[1]))
        elif kind == 'ul':
            items = "".join("<li>%s</li>" % inline(x) for x in b[1])
            out.append("<ul>%s</ul>" % items)
        elif kind == 'code':
            label = "Try it" if b[2] in ("", "bash", "sh", "shell") else html.escape(b[2])
            out.append('<div class="card"><div class="card-h">%s</div><pre>%s</pre></div>'
                       % (label, html.escape(b[1])))
        elif kind == 'flow':
            chips = '<span class="arrow">→</span>'.join(
                '<span class="chip">%s</span>' % inline(st) for st in b[1])
            out.append('<div class="flow">%s</div>' % chips)
        elif kind == 'table':
            headers, rows = b[1], b[2]
            thead = "".join("<th>%s</th>" % inline(h) for h in headers)
            body = ""
            for r in rows:
                cells = "".join("<td>%s</td>" % inline(c) for c in r)
                body += "<tr>%s</tr>" % cells
            out.append('<div class="tablewrap"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>'
                       % (thead, body))
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
    --ink:#e6edf3; --dim:#9aa6b2; --mute:#6e7681; --acc:#58a6ff; --good:#3fb950;
    --mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace;
    --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;
  }}
  *{{box-sizing:border-box}}
  body{{margin:0;background:var(--bg);color:var(--ink);
    font-family:var(--sans);line-height:1.6;font-size:15px}}
  .wrap{{max-width:860px;margin:0 auto;padding:56px 24px 100px}}
  .tag{{display:inline-block;font-family:var(--mono);font-size:12px;
    color:var(--good);border:1px solid var(--line);border-radius:999px;
    padding:4px 12px;margin-bottom:18px}}
  h1{{font-size:34px;line-height:1.15;margin:0 0 12px;letter-spacing:-.02em}}
  .lede{{color:var(--dim);font-size:18px;margin:0 0 14px;line-height:1.5}}
  .hr{{height:1px;background:var(--line);border:0;margin:36px 0}}
  section{{margin:0 0 38px}}
  h2{{font-size:21px;margin:0 0 12px;letter-spacing:-.01em}}
  ul{{margin:8px 0 16px;padding-left:20px}}
  li{{margin:0 0 6px}}
  p{{margin:0 0 13px}}
  code{{font-family:var(--mono);font-size:.85em;background:var(--panel2);
    border:1px solid var(--line);border-radius:4px;padding:1px 5px;white-space:nowrap}}
  a{{color:var(--acc);text-decoration:none}}
  a:hover{{text-decoration:underline}}
  strong{{color:#fff}}
  /* try-it command card */
  .card{{background:var(--panel);border:1px solid var(--line);
    border-radius:10px;overflow:hidden;margin:14px 0 18px}}
  .card-h{{font-family:var(--mono);font-size:11px;letter-spacing:.08em;
    text-transform:uppercase;color:var(--good);
    background:var(--panel2);border-bottom:1px solid var(--line);padding:7px 14px}}
  .card pre{{margin:0;padding:14px;overflow-x:auto;font-family:var(--mono);
    font-size:13px;line-height:1.55;color:var(--ink)}}
  /* pipeline flow diagram */
  .flow{{display:flex;flex-wrap:wrap;align-items:center;gap:8px;
    margin:14px 0 20px;padding:16px;background:var(--panel);
    border:1px solid var(--line);border-radius:10px}}
  .flow .chip{{font-family:var(--mono);font-size:13px;color:var(--ink);
    background:var(--panel2);border:1px solid var(--line);
    border-radius:7px;padding:6px 12px}}
  .flow .chip code{{background:none;border:0;padding:0;white-space:normal}}
  .flow .arrow{{color:var(--mute);font-size:14px}}
  /* coverage table */
  .tablewrap{{overflow-x:auto;margin:14px 0 20px}}
  table{{border-collapse:collapse;width:100%;font-size:13.5px}}
  th,td{{text-align:left;vertical-align:top;padding:9px 12px;
    border-bottom:1px solid var(--line)}}
  th{{color:var(--dim);font-weight:600;font-size:11px;letter-spacing:.06em;
    text-transform:uppercase;background:var(--panel2)}}
  tbody tr:hover{{background:var(--panel)}}
  td code{{white-space:nowrap}}
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
