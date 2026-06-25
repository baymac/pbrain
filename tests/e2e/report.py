#!/usr/bin/env python3
"""report.py — aggregate every (scenario × persona) run into ONE standalone HTML.

PB-89. Reads all *.result.json files from a results dir and emits a single
self-contained HTML file (inline CSS, no external assets, all run data embedded)
to a gitignored .e2e_report/ dir with a timestamped name:

    .e2e_report/e2e-<YYYYMMDD-HHMMSS>.html

The one file holds the WHOLE run: a pass/fail grid, and per run the full
agent↔agent chat transcript, the Plane write journal, and the SEAM callouts for
the boundaries the harness does not actually cross (gh / CI / merge).

Usage: report.py <results_dir> <report_dir>
Prints the path of the written report on stdout.
"""
import datetime
import glob
import html
import json
import os
import sys


def _esc(s):
    return html.escape(str(s), quote=True)


def _tracking_html(r):
    """The kind-aware Tracking pane: each command shows ITS artifact alongside
    the chat. plane-journal → JSON write-log; vault-file → the real file the
    command wrote; db-rows → JSON rows. Defaults to plane-journal."""
    kind = r.get("tracking_kind", "plane-journal")
    if kind == "vault-file":
        art = r.get("artifact") or "(no artifact)"
        path, _, body = art.partition("\n---\n")
        return ("<h4>Tracking artifact — vault file <code>%s</code></h4>"
                "<pre class='jr'>%s</pre>" % (_esc(path), _esc(body or "(empty)")))
    label = "Plane write journal" if kind == "plane-journal" else "DB rows"
    rows = "\n".join(json.dumps(j, sort_keys=True) for j in r.get("tracking", []))
    return ("<h4>Tracking — %s</h4><pre class='jr'>%s</pre>"
            % (_esc(label), _esc(rows or "(empty)")))


def main(argv):
    results_dir, report_dir = argv[0], argv[1]
    runs = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.result.json"))):
        try:
            runs.append(json.load(open(path)))
        except (ValueError, OSError):
            continue

    os.makedirs(report_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = os.path.join(report_dir, "e2e-%s.html" % stamp)

    total = len(runs)
    skipped = sum(1 for r in runs if r.get("skipped"))
    passed = sum(1 for r in runs if r.get("passed") and not r.get("skipped"))
    failed = total - passed - skipped

    def _state(r):
        if r.get("skipped"):
            return ("skip", "SKIP")
        return ("ok", "PASS") if r.get("passed") else ("bad", "FAIL")

    # Fidelity badge. LIVE = a real two-model conversation drove the real skill and
    # the model wrote the artifact. SCRIPT-ONLY = the command script ran and its
    # emitted instructions were checked, but the driver replayed the agent's write,
    # so the model's BEHAVIOUR was not exercised. Skipped runs get neither.
    def _is_live(r):
        return "skill model ↔ persona model" in r.get("transcript", "")

    def _fidelity_badge(r):
        if r.get("skipped"):
            return ""
        if _is_live(r):
            return " <span class='badge live' title='Real skill driven by a real model; the model wrote the artifact.'>LIVE</span>"
        return " <span class='badge scriptonly' title='The command script ran and its emitted instructions were asserted, but the driver replayed the agent file-write — the model was NOT exercised.'>SCRIPT-ONLY</span>"

    rows = []
    for r in runs:
        cls, mark = _state(r)
        rows.append(
            '<tr class="{cls}"><td>{s}</td><td>{p}</td><td>{e}</td>'
            '<td class="m">{m}</td></tr>'.format(
                cls=cls, s=_esc(r.get("display") or r.get("scenario")),
                p=_esc(r.get("persona")),
                e=_esc(r.get("expect")), m=mark))

    blocks = []
    for r in runs:
        cls, mark = _state(r)
        fails = r.get("failures", [])
        seams = r.get("seams", [])
        fails_html = ("<ul class='fail'>" + "".join("<li>%s</li>" % _esc(f) for f in fails) + "</ul>") if fails else "<p class='none'>none</p>"
        seams_html = ("<ul class='seam'>" + "".join("<li>%s</li>" % _esc(s) for s in seams) + "</ul>") if seams else "<p class='none'>none</p>"
        blocks.append(
            "<details class='{cls}'><summary><b>{s}</b> × <b>{p}</b> — "
            "<span class='badge {cls}'>{m}</span>{live} <span class='exp'>expect: {e}</span></summary>"
            "<h4>Persona ↔ command chat</h4><pre class='tr'>{tr}</pre>"
            "{track}"
            "<h4>Failed assertions</h4>{fh}"
            "<h4>Seams (not verified by harness)</h4>{sh}"
            "</details>".format(
                cls=cls, s=_esc(r.get("display") or r.get("scenario")),
                p=_esc(r.get("persona")), live=_fidelity_badge(r),
                m=mark, e=_esc(r.get("expect")),
                tr=_esc(r.get("transcript", "")),
                track=_tracking_html(r),
                fh=fails_html, sh=seams_html))

    doc = """<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>pbrain pmw e2e — {stamp}</title>
<style>
:root{{--ok:#1a7f37;--bad:#cf222e;--bg:#0d1117;--fg:#e6edf3;--mut:#8b949e;--card:#161b22;--bd:#30363d}}
*{{box-sizing:border-box}}
body{{font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;background:var(--bg);color:var(--fg)}}
header{{padding:24px;border-bottom:1px solid var(--bd)}}
h1{{margin:0 0 4px;font-size:18px}}
.sub{{color:var(--mut)}}
.summary{{display:flex;gap:24px;margin-top:12px;font-size:16px}}
.summary .ok{{color:var(--ok)}} .summary .bad{{color:var(--bad)}}
main{{padding:24px;max-width:1100px}}
table{{border-collapse:collapse;width:100%;margin-bottom:24px}}
th,td{{text-align:left;padding:8px 12px;border-bottom:1px solid var(--bd)}}
th{{color:var(--mut);font-weight:600}}
td.m{{font-weight:700}}
tr.ok td.m{{color:var(--ok)}} tr.bad td.m{{color:var(--bad)}}
details{{background:var(--card);border:1px solid var(--bd);border-radius:6px;margin:10px 0;padding:8px 14px}}
details.bad{{border-color:var(--bad)}}
summary{{cursor:pointer;font-size:14px}}
.badge{{padding:1px 8px;border-radius:10px;font-size:12px;font-weight:700}}
.badge.ok{{background:rgba(26,127,55,.2);color:var(--ok)}}
.badge.bad{{background:rgba(207,34,46,.2);color:var(--bad)}}
.badge.skip{{background:rgba(210,153,34,.2);color:#d29922}}
.badge.live{{background:rgba(56,139,253,.2);color:#58a6ff}}
.badge.scriptonly{{background:rgba(139,148,158,.2);color:#8b949e}}
.summary .skip{{color:#d29922}}
tr.skip td.m{{color:#d29922}}
details.skip{{border-color:#d29922}}
.exp{{color:var(--mut);font-size:12px}}
h4{{margin:14px 0 4px;color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}}
pre{{background:#010409;border:1px solid var(--bd);border-radius:6px;padding:12px;overflow:auto;white-space:pre-wrap;word-break:break-word}}
pre.tr{{color:var(--fg)}} pre.jr{{color:#79c0ff}}
ul.fail li{{color:var(--bad)}} ul.seam li{{color:#d29922}}
.none{{color:var(--mut);margin:4px 0}}
footer{{padding:16px 24px;color:var(--mut);border-top:1px solid var(--bd);font-size:12px}}
</style></head><body>
<header>
<h1>pbrain · e2e report</h1>
<div class=sub>generated {stamp} · standalone (no external assets) · {total} runs (scenario × persona)</div>
<div class=sub style="margin-top:6px"><span class=badge style="background:rgba(56,139,253,.2);color:#58a6ff">LIVE</span> real skill + real model wrote the artifact (end-to-end) &nbsp;·&nbsp; <span class=badge style="background:rgba(139,148,158,.2);color:#8b949e">SCRIPT-ONLY</span> the command script ran and its emitted instructions were asserted, but the driver replayed the file-write — the model was NOT exercised</div>
<div class=summary><span class=ok>● {passed} passed</span><span class=bad>● {failed} failed</span><span class=skip>● {skipped} skipped</span></div>
</header>
<main>
<table><thead><tr><th>scenario</th><th>persona</th><th>expect</th><th>result</th></tr></thead>
<tbody>{rows}</tbody></table>
{blocks}
</main>
<footer>Real: the command script under test, PBRAIN_VAULT, persona prefs + per-persona fixtures, and (LIVE runs) two real claude model calls + the file the skill actually wrote.
Faked/scripted (non-LIVE): pmw's Plane I/O (fake_plane.py) and gh/CI/merge (SEAM lines); the agent's file write is replayed.
SKIP = a live run the claude CLI could not perform (never a synthetic pass).</footer>
</body></html>""".format(
        stamp=_esc(stamp), total=total, passed=passed, failed=failed, skipped=skipped,
        rows="".join(rows), blocks="".join(blocks))

    with open(out, "w") as fh:
        fh.write(doc)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
