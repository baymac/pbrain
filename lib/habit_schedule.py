"""Habit schedule engine — the single source of truth for "is this habit due on
this date?" plus the frequency→days spacing helpers.

A habit's SCHEDULE (axis 1) is separate from its SCORING direction (axis 2,
at_least/at_most). The schedule decides which calendar days the habit occurs on,
which in turn gates per-day one-shot reminder creation. Kinds:

  daily     — every day
  weekdays  — specific weekdays, e.g. ["mon","wed","fri"]
  interval  — every `every_days` days from `start_date`
  monthly   — specific calendar days-of-month, e.g. [1, 16]

"N times per week/month" is NOT a stored kind: it's resolved at creation into
spaced concrete days (weekdays / days_of_month) from a start anchor, so is_due
stays a simple membership/modulo test.

This module is imported by both commands/habits.sh (reminder creation) and
lib/habits.sh (schedule-aware scoring) via an explicit sys.path insert of the
lib dir — it has no third-party deps (stdlib only).
"""
import calendar
import datetime
import re

WD = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
_WD_INDEX = {d: i for i, d in enumerate(WD)}

_DAY_ALIAS = {
    "m": "mon", "mo": "mon", "mon": "mon", "monday": "mon",
    "tu": "tue", "tue": "tue", "tues": "tue", "tuesday": "tue",
    "w": "wed", "we": "wed", "wed": "wed", "weds": "wed", "wednesday": "wed",
    "th": "thu", "thu": "thu", "thur": "thu", "thurs": "thu", "thursday": "thu",
    "f": "fri", "fr": "fri", "fri": "fri", "friday": "fri",
    "sa": "sat", "sat": "sat", "saturday": "sat",
    "su": "sun", "sun": "sun", "sunday": "sun",
}


def norm_days(lst):
    """Normalize a list of weekday tokens → canonical lowercase, deduped, in
    week order. Drops anything unrecognizable."""
    out = []
    for x in (lst or []):
        k = str(x).strip().lower()
        if k in _DAY_ALIAS and _DAY_ALIAS[k] not in out:
            out.append(_DAY_ALIAS[k])
    return sorted(out, key=WD.index)


def spaced_weekdays(start_wd, n):
    """N occurrences spaced across a week from start weekday index (mon=0).
    2 from Mon → [mon, thu]; 3 from Mon → [mon, wed, fri]. n>=7 → all days."""
    try:
        n = int(n)
    except (TypeError, ValueError):
        return []
    if n <= 0:
        return []
    if n >= 7:
        return list(WD)
    out = []
    for i in range(n):
        out.append(WD[(int(start_wd) + (i * 7) // n) % 7])
    seen = []
    for d in out:
        if d not in seen:
            seen.append(d)
    return sorted(seen, key=WD.index)


def spaced_dom(start_dom, n):
    """N occurrences spaced across a month from a start day-of-month. Clamped to
    1..28 so every month actually contains each day. 2 from the 1st → [1, 16]."""
    try:
        n = int(n)
        start = max(1, min(28, int(start_dom)))
    except (TypeError, ValueError):
        return []
    if n <= 0:
        return []
    out = set()
    for i in range(n):
        out.add(((start - 1 + (i * 30) // n) % 30) + 1)
    return sorted(min(d, 28) for d in out)


def derive_schedule(habit):
    """Return a normalized schedule dict for a habit. Uses the explicit
    `schedule` field when present; otherwise synthesizes one (non-destructively)
    from legacy fields (schedule_type / target_count) and any reminder.days left
    over from the fixed-weekday work. Default start anchor for a synthesized
    weekly/monthly habit is Monday / the 1st (the user can refine it)."""
    s = habit.get("schedule")
    if isinstance(s, dict) and s.get("type"):
        t = str(s.get("type")).strip().lower()
        if t == "weekdays":
            return {"type": "weekdays", "days": norm_days(s.get("days"))}
        if t == "interval":
            try:
                n = int(s.get("every_days") or 0)
            except (TypeError, ValueError):
                n = 0
            return {"type": "interval", "start_date": s.get("start_date"), "every_days": n}
        if t == "monthly":
            doms = sorted({int(d) for d in (s.get("days_of_month") or [])
                           if str(d).strip().lstrip("-").isdigit() and int(d) > 0})
            return {"type": "monthly", "days_of_month": doms}
        return {"type": "daily"}

    # ---- synthesize from legacy shape ----
    rem = habit.get("reminder") if isinstance(habit.get("reminder"), dict) else {}
    rdays = norm_days(rem.get("days"))
    if rdays:
        return {"type": "weekdays", "days": rdays}

    st = str(habit.get("schedule_type", "") or "daily").strip().lower()
    if st == "daily":
        return {"type": "daily"}
    try:
        n = max(1, int(habit.get("target_count")))
    except (TypeError, ValueError):
        n = 1
    if st == "weekly":
        return {"type": "weekdays", "days": spaced_weekdays(0, n)}
    if st == "monthly":
        return {"type": "monthly", "days_of_month": spaced_dom(1, n)}
    return {"type": "daily"}


def is_due(sched, date_iso):
    """True if a habit with this (normalized) schedule occurs on date_iso."""
    try:
        d = datetime.date.fromisoformat(str(date_iso))
    except (TypeError, ValueError):
        return False
    t = (sched or {}).get("type", "daily")
    if t == "daily":
        return True
    if t == "weekdays":
        return WD[d.weekday()] in (sched.get("days") or [])
    if t == "interval":
        sd = sched.get("start_date")
        try:
            n = int(sched.get("every_days") or 0)
        except (TypeError, ValueError):
            n = 0
        if not sd or n <= 0:
            return False
        try:
            start = datetime.date.fromisoformat(str(sd))
        except (TypeError, ValueError):
            return False
        delta = (d - start).days
        return delta >= 0 and delta % n == 0
    if t == "monthly":
        last = calendar.monthrange(d.year, d.month)[1]
        eff = set()
        for x in (sched.get("days_of_month") or []):
            if str(x).strip().lstrip("-").isdigit() and int(x) > 0:
                eff.add(min(int(x), last))
        return d.day in eff
    return False


def build_schedule(p):
    """Build a normalized schedule dict from a params dict (values may be
    strings or None). Recognized keys: kind, days, times_per_week, start_day,
    every_days, start_date, days_of_month, times_per_month, start_dom, today.
    The frequency forms (times_per_week / times_per_month) are resolved into
    concrete spaced days here, so the stored schedule is always is_due-ready.
    The kind is inferred from which fields are present when not given."""
    def g(k):
        v = p.get(k)
        return "" if v is None else str(v).strip()

    kind = g("kind").lower()
    days, tpw, start_day = g("days"), g("times_per_week"), g("start_day").lower()
    every, start_date = g("every_days"), g("start_date")
    dom, tpm, start_dom = g("days_of_month"), g("times_per_month"), g("start_dom")
    today = g("today")

    if kind in ("", "weekly"):
        if kind == "weekly":
            kind = "weekdays"
        elif every:
            kind = "interval"
        elif dom or tpm:
            kind = "monthly"
        elif days or tpw:
            kind = "weekdays"
        else:
            kind = "daily"

    if kind == "weekdays":
        if days:
            dl = norm_days(re.split(r"[,\s]+", days))
        elif tpw:
            try:
                n = int(tpw)
            except ValueError:
                n = 1
            dl = spaced_weekdays(_WD_INDEX.get(start_day, 0), n)
        else:
            dl = []
        sched = {"type": "weekdays", "days": dl}
        if tpw:
            try:
                sched["times_per_week"] = int(tpw)
            except ValueError:
                pass
        if start_day in _WD_INDEX:
            sched["start_day"] = start_day
        return sched

    if kind == "interval":
        try:
            n = int(every) if every else 0
        except ValueError:
            n = 0
        return {"type": "interval", "start_date": (start_date or today or None), "every_days": n}

    if kind == "monthly":
        if dom:
            dl = sorted({int(x) for x in re.split(r"[,\s]+", dom)
                         if x.strip().isdigit() and 1 <= int(x) <= 31})
        elif tpm:
            try:
                n = int(tpm)
            except ValueError:
                n = 1
            try:
                sdom = int(start_dom) if start_dom else 1
            except ValueError:
                sdom = 1
            dl = spaced_dom(sdom, n)
        else:
            dl = []
        sched = {"type": "monthly", "days_of_month": dl}
        if tpm:
            try:
                sched["times_per_month"] = int(tpm)
            except ValueError:
                pass
        return sched

    return {"type": "daily"}


def legacy_fields(sched):
    """Best-effort (schedule_type, target_count) for the transitional evaluator
    that still reads the old fields. Replaced by schedule-aware scoring later."""
    t = (sched or {}).get("type", "daily")
    if t == "daily":
        return "daily", 1
    if t == "weekdays":
        return "weekly", max(1, len(sched.get("days") or []))
    if t == "monthly":
        return "monthly", max(1, len(sched.get("days_of_month") or []))
    if t == "interval":
        n = sched.get("every_days") or 1
        return ("daily" if n <= 1 else "weekly" if n < 28 else "monthly"), 1
    return "daily", 1


def schedule_label(sched):
    """Short human label for a normalized schedule (for rollups/messages)."""
    t = (sched or {}).get("type", "daily")
    if t == "daily":
        return "daily"
    if t == "weekdays":
        return "/".join(x.capitalize() for x in (sched.get("days") or [])) or "weekdays"
    if t == "interval":
        return "every %s days" % sched.get("every_days")
    if t == "monthly":
        return "monthly " + ",".join(str(x) for x in (sched.get("days_of_month") or []))
    return t
