#!/usr/bin/env python3
# plan-my-day-facts.py — extract "facts only" from the user's REAL today files in
# the e2e snapshot, for the live CHAIN mode (PB-165). Read-only. Prints a compact,
# human-readable facts block; the persona model rephrases these naturally.
#
#   usage: plan-my-day-facts.py <vault_dir> <YYYY-MM-DD>
import os
import re
import sys

vault, today = sys.argv[1], sys.argv[2]


def read(*parts):
    try:
        return open(os.path.join(vault, *parts)).read()
    except OSError:
        return ""


facts = []

# --- journal: brain-dump gist + the sleep line (PB-165's one linkage input) ---
jrnl = read("life", "daily-tracking", "%s.md" % today)
if jrnl:
    body = re.sub(r"^---\n.*?\n---\n", "", jrnl, count=1, flags=re.DOTALL)
    sleep_hits = [l.strip(" -*#\t") for l in body.splitlines()
                  if re.search(r"sleep|slept|woke|awake|\bbed\b|wake", l, re.I)
                  and re.search(r"\d", l)]
    gist = [l.strip(" -*#\t") for l in body.splitlines() if l.strip(" -*#\t")][:5]
    if sleep_hits:
        facts.append("SLEEP (from today's journal): " + " / ".join(sleep_hits[:2]))
    if gist:
        facts.append("MORNING BRAIN-DUMP gist: " + " | ".join(gist))
else:
    facts.append("JOURNAL: (none for today - invent a brief, realistic slow-morning brain dump)")

# --- fitness: activity/focus, the session time, sleep_* frontmatter ---
fit = read("fitness", "daily-tracking", "%s.md" % today)
if fit:
    def fm(key):
        m = re.search(r"^%s:\s*(.+)$" % key, fit, re.M)
        return m.group(1).strip().strip('"') if m else ""
    act = fm("activity") or fm("focus") or "gym"
    when = ""
    mw = (re.search(r"\*\*When\*\*\s*(\d{1,2}:\d{2})", fit)
          or re.search(r"^when:\s*(\d{1,2}:\d{2})", fit, re.M))
    if mw:
        when = mw.group(1)
    if not when:
        mh = re.search(r"·\s*(\d{1,2}:\d{2})", fit)  # heading "· HH:MM"
        if mh:
            when = mh.group(1)
    day = ""
    md = re.search(r"Day\s+([A-D])\b", fit)
    if md:
        day = "Day %s" % md.group(1)
    sb, sw = fm("sleep_bed"), fm("sleep_wake")
    line = "FITNESS today: %s" % act
    if day:
        line += " (%s)" % day
    if when:
        line += ", at %s" % when
    facts.append(line)
    if sb or sw:
        facts.append("SLEEP frontmatter: bed %s / wake %s" % (sb or "?", sw or "?"))
else:
    facts.append("FITNESS: (none for today - invent a realistic session, e.g. a gym day with a stated time)")

# --- diet: profile meal slots + any logged meals today ---
prof = ""
pdir = os.path.join(vault, "fitness", "diet-tracking", ".profile")
if os.path.isdir(pdir):
    cands = sorted(f for f in os.listdir(pdir)
                   if f.startswith("diet-profile") and f.endswith(".md"))
    if cands:
        prof = open(os.path.join(pdir, cands[-1])).read()
slots = re.findall(r'"?([A-Za-z ]+)"?\s*:\s*"(\d{1,2}:\d{2})"', prof)
if slots:
    facts.append("DIET meal slots: " + ", ".join("%s %s" % (n.strip(), t) for n, t in slots[:6]))
diet = read("fitness", "diet-tracking", "%s.md" % today)
if diet:
    meals = re.findall(r"^\|\s*([A-Za-z][A-Za-z ]+?)\s*\|", diet, re.M)
    meals = [m for m in meals if m.lower() not in ("meal", "total", "target", "remaining")]
    if meals:
        facts.append("MEALS logged today: " + ", ".join(dict.fromkeys(meals))[:200])

# --- plan (if present): the intended day-shape, as ASSERTION inspiration ---
plan = read("life", "daily-planning", "%s.md" % today)
if plan:
    anchors = re.findall(r"\|\s*(\d{1,2}:\d{2})[^|]*\|\s*([^|]+?)\s*\|", plan)
    if anchors:
        facts.append("PRIOR PLAN anchors (inspiration only): "
                     + "; ".join("%s %s" % (t, a.strip()) for t, a in anchors[:8]))

print("\n".join(facts))
