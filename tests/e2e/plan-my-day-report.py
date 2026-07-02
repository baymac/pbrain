#!/usr/bin/env python3
"""plan-my-day-report.py — render a CLEAN standalone HTML report for the
plan-my-day live e2e (PB-186).

Inputs (argv):
  1 transcript.ndjson  — one JSON object per line:
                         {"leg":"journal|fitness-journal|diet-journal|plan-my-day",
                          "role":"skill|persona","text":...}  (leg optional → plan-my-day)
  2 verdict JSON       — from the assert step (ok, problems, blocks, breaks, rows, ...)
  3 plan file          — the generated daily-planning markdown
  4 scenario JSON      — the morning-replay scenario (display, checkin_answers)
  5 out path           — where to write the HTML
  6 label (optional)   — override the sub-title (chain mode passes the real-facts label,
                         so the report never shows a stale scenario name)

Self-contained: inline CSS, no external assets. Sections:
  - header + PASS/FAIL verdict + policy summary
  - agent↔agent conversation rendered as chat bubbles (skill vs you)
  - the day timeline: work blocks (full vs trimmed) + breaks (vs min/median/max)
  - the rules-check table (every block/break with a per-row verdict)
  - the raw generated "Today at a glance" table
"""
import html, json, sys, datetime

tpath, vjson_path_or_str, plan_path, scen_path, out = sys.argv[1:6]
label_override = sys.argv[6] if len(sys.argv) > 6 else ""

def esc(s): return html.escape(str(s), quote=True)

# verdict can be passed as a path or as a raw json string
try:
    verdict = json.loads(vjson_path_or_str)
except Exception:
    verdict = json.load(open(vjson_path_or_str))

scen = {}
try: scen = json.load(open(scen_path))
except Exception: pass

convo = []
try:
    for line in open(tpath):
        line = line.strip()
        if line:
            convo.append(json.loads(line))
except Exception:
    pass

plan_md = ""
try: plan_md = open(plan_path).read()
except Exception: pass

ok = verdict.get("ok", False)
problems = verdict.get("problems", [])
sess = verdict.get("session", 0)
br = verdict.get("break", {}) or {}
bmin, bmed, bmax = br.get("min","?"), br.get("median","?"), br.get("max","?")
blocks = verdict.get("blocks", [])
breaks = verdict.get("breaks", [])
rows = verdict.get("rows", [])

# ---- conversation bubbles, grouped by leg ----------------------------------
# The chain writes turns for every leg (journal → fitness → diet → plan-my-day)
# into ONE transcript, each tagged with "leg". Group them so the report shows the
# FULL agent-to-agent conversation, leg by leg, in order — not just plan-my-day.
LEG_ORDER = ["journal", "fitness-journal", "diet-journal", "plan-my-day"]
LEG_TITLE = {
    "journal":        "① /journal — morning brain dump (sleep line feeds fitness)",
    "fitness-journal":"② /fitness-journal — today's session + its time (feeds plan-my-day)",
    "diet-journal":   "③ /diet-journal — today's meals (meal slots feed plan-my-day)",
    "plan-my-day":    "④ /plan-my-day — reads the fresh fitness When + meal slots, lays the day",
}
def _leg_of(m): return m.get("leg") or "plan-my-day"

legs_seen = []
for m in convo:
    lg = _leg_of(m)
    if lg not in legs_seen: legs_seen.append(lg)
ordered_legs = [l for l in LEG_ORDER if l in legs_seen] + [l for l in legs_seen if l not in LEG_ORDER]

multi_leg = len(ordered_legs) > 1
sections = []
for lg in ordered_legs:
    bubbles = []
    for m in convo:
        if _leg_of(m) != lg: continue
        role = m.get("role","")
        text = (m.get("text") or "").strip()
        who = "You" if role == "persona" else lg
        side = "right" if role == "persona" else "left"
        bubbles.append(
            f'<div class="msg {side}"><div class="who">{esc(who)}</div>'
            f'<div class="bubble {side}">{esc(text).replace(chr(10),"<br>")}</div></div>'
        )
    body = "\n".join(bubbles) or '<p class="none">(no turns captured for this leg — it may have written its file on the first turn)</p>'
    hdr = f'<div class="leghdr">{esc(LEG_TITLE.get(lg, lg))}</div>' if multi_leg else ""
    sections.append(f'{hdr}<div class="chat">{body}</div>')
convo_html = "\n".join(sections) or '<p class="none">(no conversation captured)</p>'

# ---- timeline --------------------------------------------------------------
# Build a simple proportional timeline from the parsed rows.
def mins(t):
    h,m=t.split(":"); return int(h)*60+int(m)
tl_rows = []
day_start = None; day_end = None
for s,e,act in rows:
    try:
        ms, me = mins(s), mins(e)
        if me < ms: me += 24*60
    except Exception:
        continue
    day_start = ms if day_start is None else min(day_start, ms)
    day_end = me if day_end is None else max(day_end, me)
span = (day_end - day_start) if (day_start is not None and day_end and day_end>day_start) else 1

def classify(action):
    a=action.lower()
    if "block" in a or "focus work" in a: return "work"
    if "break" in a: return "break"
    if "wind" in a or "bed" in a: return "winddown"
    return "anchor"

work_idxs = [i for i,(s,e,a) in enumerate(rows) if classify(a)=="work"]
last_work = max(work_idxs) if work_idxs else -1

tl_html = []
for i,(s,e,act) in enumerate(rows):
    try:
        ms,me=mins(s),mins(e)
        if me<ms: me+=24*60
    except Exception:
        continue
    left = (ms-day_start)/span*100
    width = max((me-ms)/span*100, 0.8)
    k = classify(act); d = me-ms
    cls = k
    note = ""
    if k=="work":
        if d==sess: cls="work full"; note=f"{d}m ✓"
        elif d>sess: cls="work over"; note=f"{d}m ⚠"
        else:
            nxt = rows[i+1] if i+1<len(rows) else None
            ok_short = (i==last_work) or (nxt and classify(nxt[2]) in ("anchor","winddown"))
            cls = "work trim" if ok_short else "work bad"
            note=f"{d}m"+(" (trim)" if ok_short else " ✗")
    elif k=="break":
        try:
            if d>int(bmax): cls="break bad"; note=f"{d}m ✗>max"
            elif d<int(bmin): cls="break bad"; note=f"{d}m ✗<min"
            else: cls="break ok"; note=f"{d}m"
        except Exception:
            note=f"{d}m"
    label = esc(act[:28])
    tl_html.append(
        f'<div class="seg {cls}" style="left:{left:.1f}%;width:{width:.1f}%" '
        f'title="{esc(s)}–{esc(e)} · {esc(act)}"><span>{label}<br><b>{note}</b></span></div>'
    )
timeline = "".join(tl_html) or '<p class="none">(no rows parsed)</p>'

# axis ticks every ~2h
ticks=[]
if day_start is not None and span>1:
    t=day_start - (day_start % 60)
    while t<=day_end:
        left=(t-day_start)/span*100
        if 0<=left<=100:
            ticks.append(f'<span style="left:{left:.1f}%">{t//60%24:02d}:{t%60:02d}</span>')
        t+=120
axis="".join(ticks)

# ---- rules-check table -----------------------------------------------------
check_rows=[]
for b in blocks:
    d=b["dur"]; full = d==sess
    verdict_cell = '<span class="ok">full</span>' if full else (
        '<span class="warn">trimmed</span>')
    check_rows.append(f'<tr><td>{esc(b["start"])}–{esc(b["end"])}</td><td>work</td>'
                      f'<td>{d} min</td><td>target {sess}</td><td>{verdict_cell}</td></tr>')
for bk in breaks:
    d=bk["dur"]
    try:
        good = int(bmin)<=d<=int(bmax)
    except Exception: good=True
    vc = '<span class="ok">within min–max</span>' if good else '<span class="bad">out of range</span>'
    check_rows.append(f'<tr><td>{esc(bk["start"])}–{esc(bk["end"])}</td><td>break</td>'
                      f'<td>{d} min</td><td>{bmin}/{bmed}/{bmax}</td><td>{vc}</td></tr>')
check_table="".join(check_rows) or '<tr><td colspan="5" class="none">no blocks/breaks parsed</td></tr>'

problems_html = ("<ul class='probs'>"+"".join(f"<li>{esc(p)}</li>" for p in problems)+"</ul>") if problems else "<p class='none'>none</p>"

display = label_override or scen.get("display","plan-my-day — today replay")
answers = scen.get("checkin_answers",[])
answers_html = "".join(f"<li>{esc(a)}</li>" for a in answers) or "<li class='none'>(none)</li>"

verdict_badge = ('<span class="badge pass">PASS</span>' if ok
                 else '<span class="badge fail">FAIL</span>')

# Chain mode (>1 leg) vs the single plan-my-day replay: adapt the conversation
# section so it never shows stale scripted-scenario framing.
if multi_leg:
    convo_heading = "Full agent ↔ agent conversation (every leg, in order)"
    left_card = ('<div class="card"><h3>How the persona was driven</h3>'
                 '<p style="font-size:13px;color:var(--mut);margin:0">No scripted scenario. '
                 'Each leg\'s persona spoke the <b>real facts</b> extracted from that day\'s own '
                 'vault files (rephrased naturally), then the file was reset and regenerated live.</p></div>')
    proves_text = ("The chain is connected end to end: /journal recorded the night's sleep, "
                   "/fitness-journal wrote today's real session <b>with its time</b>, and "
                   "/plan-my-day then read that fresh <code>When</code> line + the diet meal slots "
                   "to anchor the day — nothing about the schedule was supplied by hand.")
else:
    convo_heading = "Morning conversation (agent ↔ agent)"
    left_card = (f'<div class="card"><h3>Your replayed check-in answers (scenario)</h3>'
                 f'<ul>{answers_html}</ul></div>')
    proves_text = ("The fitness time and meal slots were NOT supplied here — the skill pulled them "
                   "from the copied fitness journal &amp; diet profile, exactly as a real morning "
                   "run does. You only answered the check-in.")

HTML = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>plan-my-day live e2e — PB-186</title>
<style>
:root{{--bg:#0d1117;--panel:#161b22;--panel2:#1c2230;--bd:#30363d;--tx:#e6edf3;
--mut:#8b949e;--grn:#3fb950;--red:#f85149;--amb:#d29922;--blu:#58a6ff;--trk:#21262d;}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--tx);padding:32px 20px 80px;
font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}}
.wrap{{max-width:1040px;margin:0 auto}}
h1{{font-size:23px;margin:0 0 2px}} h2{{font-size:16px;margin:34px 0 12px;
border-bottom:1px solid var(--bd);padding-bottom:6px}}
.sub{{color:var(--mut);margin:0 0 14px}}
.badge{{display:inline-block;padding:2px 12px;border-radius:999px;font-size:13px;font-weight:700;vertical-align:middle}}
.badge.pass{{background:rgba(63,185,80,.15);color:var(--grn);border:1px solid rgba(63,185,80,.45)}}
.badge.fail{{background:rgba(248,81,73,.15);color:var(--red);border:1px solid rgba(248,81,73,.45)}}
.meta{{display:flex;flex-wrap:wrap;gap:6px 22px;color:var(--mut);font-size:13px;margin:8px 0}}
.meta b{{color:var(--tx)}}
code{{background:var(--trk);padding:1px 6px;border-radius:5px;font:13px ui-monospace,Menlo,monospace}}
.cols{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}
@media(max-width:760px){{.cols{{grid-template-columns:1fr}}}}
.card{{background:var(--panel);border:1px solid var(--bd);border-radius:10px;padding:14px 16px}}
.card h3{{margin:0 0 8px;font-size:14px;color:var(--mut);font-weight:600}}

/* conversation */
.leghdr{{margin:20px 0 8px;font-size:13px;font-weight:700;color:var(--blu);
letter-spacing:.2px}}
.leghdr:first-child{{margin-top:0}}
.chat{{background:var(--panel);border:1px solid var(--bd);border-radius:12px;padding:16px;margin-bottom:6px}}
.msg{{display:flex;flex-direction:column;margin:10px 0;max-width:80%}}
.msg.left{{align-items:flex-start}} .msg.right{{align-items:flex-end;margin-left:auto}}
.who{{font-size:11px;color:var(--mut);margin:0 6px 3px}}
.bubble{{padding:10px 13px;border-radius:14px;font-size:14px;white-space:normal}}
.bubble.left{{background:var(--panel2);border:1px solid var(--bd);border-bottom-left-radius:4px}}
.bubble.right{{background:rgba(88,166,255,.14);border:1px solid rgba(88,166,255,.35);border-bottom-right-radius:4px}}

/* timeline */
.tlwrap{{background:var(--panel);border:1px solid var(--bd);border-radius:10px;padding:18px 16px 30px}}
.tl{{position:relative;height:62px;background:var(--trk);border-radius:8px;margin-top:6px}}
.seg{{position:absolute;top:0;bottom:0;border-radius:6px;overflow:hidden;
display:flex;align-items:center;justify-content:center;text-align:center;
font-size:10px;line-height:1.15;padding:2px;border:1px solid rgba(0,0,0,.25)}}
.seg span{{color:#0d1117;font-weight:600}}
.seg.work.full{{background:var(--grn)}}
.seg.work.trim{{background:#8dd39b}}
.seg.work.bad{{background:var(--red)}} .seg.work.bad span{{color:#fff}}
.seg.work.over{{background:var(--amb)}}
.seg.break.ok{{background:var(--blu)}}
.seg.break.bad{{background:var(--red)}} .seg.break.bad span{{color:#fff}}
.seg.anchor{{background:#6e7681}} .seg.anchor span{{color:#fff;font-weight:500}}
.seg.winddown{{background:#39414e}} .seg.winddown span{{color:#cfd6e0;font-weight:500}}
.axis{{position:relative;height:16px;margin-top:4px;font-size:10px;color:var(--mut)}}
.axis span{{position:absolute;transform:translateX(-50%)}}
.legend{{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;color:var(--mut);margin-top:14px}}
.legend i{{display:inline-block;width:13px;height:13px;border-radius:3px;vertical-align:-2px;margin-right:5px}}

table{{border-collapse:collapse;width:100%;font-size:13.5px}}
th,td{{border:1px solid var(--bd);padding:7px 10px;text-align:left}}
th{{background:var(--trk)}}
.ok{{color:var(--grn);font-weight:600}} .warn{{color:var(--amb);font-weight:600}}
.bad{{color:var(--red);font-weight:600}} .none{{color:var(--mut)}}
.probs{{margin:4px 0;padding-left:20px}} .probs li{{color:var(--red)}}
ul{{margin:4px 0;padding-left:20px}}
pre{{background:var(--trk);border:1px solid var(--bd);border-radius:8px;padding:12px;
overflow:auto;font:12.5px ui-monospace,Menlo,monospace;white-space:pre-wrap}}
.verdict{{border-radius:10px;padding:14px 18px;margin:14px 0;border:1px solid}}
.verdict.pass{{background:rgba(63,185,80,.08);border-color:rgba(63,185,80,.35)}}
.verdict.fail{{background:rgba(248,81,73,.08);border-color:rgba(248,81,73,.35)}}
footer{{color:var(--mut);font-size:12px;margin-top:40px;border-top:1px solid var(--bd);padding-top:14px}}
</style></head><body><div class="wrap">

<h1>plan-my-day — live e2e {verdict_badge}</h1>
<p class="sub">{esc(display)}</p>
<div class="meta">
  <span><b>Method:</b> real-vault snapshot · two real models (you ↔ plan-my-day) · auto-planned from your fitness journal &amp; meal times</span>
</div>
<div class="meta">
  <span><b>session_length:</b> {sess} min</span>
  <span><b>break (min/median/max):</b> {bmin} / {bmed} / {bmax} min</span>
  <span><b>work blocks:</b> {verdict.get("n_work",0)}</span>
  <span><b>breaks:</b> {verdict.get("n_break",0)}</span>
</div>

<div class="verdict {'pass' if ok else 'fail'}">
  <b>{'PASS' if ok else 'FAIL'}.</b>
  {'Every work block is a full session (or trimmed only at end-of-day / a hard anchor), and every break sits within min–max — no padded breaks, no arbitrary mid-day shrink.' if ok else 'Rule violations found:'}
  {'' if ok else problems_html}
</div>

<h2>Day timeline</h2>
<div class="tlwrap">
  <div class="tl">{timeline}</div>
  <div class="axis">{axis}</div>
  <div class="legend">
    <span><i style="background:var(--grn)"></i>full work block</span>
    <span><i style="background:#8dd39b"></i>trimmed (end/anchor — ok)</span>
    <span><i style="background:var(--red)"></i>violation</span>
    <span><i style="background:var(--blu)"></i>break (within min–max)</span>
    <span><i style="background:#6e7681"></i>anchor (meal/fitness/event)</span>
    <span><i style="background:#39414e"></i>wind-down</span>
  </div>
</div>

<h2>Rules check</h2>
<table>
  <tr><th>Time</th><th>Kind</th><th>Duration</th><th>Target</th><th>Verdict</th></tr>
  {check_table}
</table>

<h2>{convo_heading}</h2>
<div class="cols">
  {left_card}
  <div class="card"><h3>What this proves</h3>
    <p style="font-size:13px;color:var(--mut);margin:0">{proves_text}</p>
  </div>
</div>
{convo_html}

<h2>Generated plan — “Today at a glance”</h2>
<pre>{esc(plan_md[:6000])}{'…(truncated)' if len(plan_md)>6000 else ''}</pre>

<footer>pbrain · plan-my-day live e2e · PB-186 · real vault copied to a throwaway and discarded after the run; real vault untouched.</footer>
</div></body></html>"""

open(out, "w", encoding="utf-8").write(HTML)
print(out)
