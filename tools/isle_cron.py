#!/usr/bin/env python3
"""
isle_cron.py - cron expressions for scheduled jobs (backups), standard library only.

    isle_cron.py check "<expr>"                     exit 0 if valid (prints the reason if not)
    isle_cron.py match "<expr>" [--at ISO]          exit 0 if the expression fires in that minute
    isle_cron.py next  "<expr>" [-n 5] [--json]     the next run times
    isle_cron.py describe "<expr>"                  a short English description
    isle_cron.py due "<expr>" [--since ISO]         exit 0 and print the minute if a run fell after --since
                                                    (at most 10 minutes back) up to now - for a per-minute timer
    common: [--conf FILE] (TIMEZONE=local|utc)

Syntax: "minute hour day-of-month month day-of-week", each field "*", "*/n", "a", "a-b", "a-b/n" or a
comma list; months JAN-DEC and days SUN-SAT (0 or 7 = Sunday) by name; shortcuts @hourly @daily
@midnight @weekly @monthly @yearly @annually. As in cron, when both day-of-month and day-of-week are
restricted, a day matches if EITHER matches. An empty expression (or "off") means "never".
"""
import argparse
import datetime
import json
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import isle_logs  # noqa: E402

MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
DAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
SHORTCUTS = {"@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
             "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"}
FIELDS = (("minute", 0, 59, None), ("hour", 0, 23, None), ("day of month", 1, 31, None),
          ("month", 1, 12, MONTHS), ("day of week", 0, 7, DAYS))


class CronError(ValueError):
    pass


def _value(text, low, high, names, label):
    t = text.upper()
    if names and t in names:
        return names.index(t) + (1 if names is MONTHS else 0)
    if not re.match(r"^\d+$", text):
        raise CronError("%s: '%s' is not a number%s" % (label, text, " or name" if names else ""))
    v = int(text)
    if not low <= v <= high:
        raise CronError("%s: %d is outside %d-%d" % (label, v, low, high))
    return v


def _field(text, low, high, names, label):
    values = set()
    for part in text.split(","):
        if not part:
            raise CronError("%s: empty list item" % label)
        step = 1
        if "/" in part:
            part, step_text = part.split("/", 1)
            if not re.match(r"^\d+$", step_text) or int(step_text) < 1:
                raise CronError("%s: step '/%s' must be a positive number" % (label, step_text))
            step = int(step_text)
        if part == "*":
            start, end = low, high
        elif "-" in part:
            a, b = part.split("-", 1)
            start, end = _value(a, low, high, names, label), _value(b, low, high, names, label)
            if start > end:
                raise CronError("%s: range %s is backwards" % (label, part))
        else:
            start = _value(part, low, high, names, label)
            end = high if step > 1 else start
        values.update(range(start, end + 1, step))
    return values


class Cron(object):
    def __init__(self, expr):
        self.expr = (expr or "").strip()
        text = SHORTCUTS.get(self.expr.lower(), self.expr)
        self.never = text.lower() in ("", "off", "never", "none")
        if self.never:
            return
        parts = text.split()
        if len(parts) != 5:
            raise CronError("expected 5 fields (minute hour day-of-month month day-of-week), got %d" % len(parts))
        sets = [_field(p, lo, hi, names, label) for p, (label, lo, hi, names) in zip(parts, FIELDS)]
        self.minutes, self.hours, self.mdays, self.months, wdays = sets
        self.wdays = {d % 7 for d in wdays}          # 7 = Sunday
        self.mday_any, self.wday_any = parts[2] == "*", parts[4] == "*"

    def day_matches(self, dt):
        wday = (dt.weekday() + 1) % 7                # Python: Monday = 0; cron: Sunday = 0
        md, wd = dt.day in self.mdays, wday in self.wdays
        if self.mday_any or self.wday_any:
            return md and wd
        return md or wd                              # cron: either restricted day field

    def matches(self, dt):
        if self.never:
            return False
        if dt.minute not in self.minutes or dt.hour not in self.hours or dt.month not in self.months:
            return False
        return self.day_matches(dt)

    def next_runs(self, start, count=5):
        out = []
        if self.never:
            return out
        t = start.replace(second=0, microsecond=0) + datetime.timedelta(minutes=1)
        limit = t + datetime.timedelta(days=366 * 9)   # Feb 29 schedules: up to 8 years apart
        while len(out) < count and t < limit:
            if t.month not in self.months:            # skip whole months / days / hours quickly
                t = (t.replace(day=1, hour=0, minute=0) + datetime.timedelta(days=32)).replace(day=1)
                continue
            if not self.day_matches(t):
                t = t.replace(hour=0, minute=0) + datetime.timedelta(days=1)
                continue
            if t.hour not in self.hours:
                t = t.replace(minute=0) + datetime.timedelta(hours=1)
                continue
            if self.matches(t):
                out.append(t)
            t += datetime.timedelta(minutes=1)
        return out

    def describe(self):
        if self.never:
            return "never (no schedule)"
        names = {"@hourly": "every hour, on the hour", "@daily": "every day at 00:00", "@midnight": "every day at 00:00",
                 "@weekly": "every Sunday at 00:00", "@monthly": "on day 1 of every month at 00:00",
                 "@yearly": "every 1 January at 00:00", "@annually": "every 1 January at 00:00"}
        if self.expr.lower() in names:
            return names[self.expr.lower()]
        m, h, dom, mon, dow = self.expr.split()
        if re.match(r"^\d+$", m) and re.match(r"^[\d,]+$", h) and dom == "*" and mon == "*":
            times = ", ".join("%02d:%02d" % (int(x), int(m)) for x in h.split(","))
            if dow == "*":
                return "every day at " + times
            days = sorted(self.wdays)
            return "every %s at %s" % (", ".join(DAYS[d].title() for d in days), times)
        if re.match(r"^\d+$", m) and h.startswith("*/") and dom == "*" and mon == "*" and dow == "*":
            return "every %s hours at minute %s" % (h[2:], m)
        if m.startswith("*/") and h == "*" and dom == "*" and mon == "*" and dow == "*":
            return "every minute" if m[2:] == "1" else "every %s minutes" % m[2:]
        if m == "*" and h == "*" and dom == "*" and mon == "*" and dow == "*":
            return "every minute"
        return "cron: " + self.expr


def now_for(values):
    if isle_logs.is_utc(values):
        return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    return datetime.datetime.now()


def parse_at(text):
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.datetime.strptime(text, fmt)
        except ValueError:
            pass
    raise CronError("--at: use YYYY-MM-DDTHH:MM")


def main(argv=None):
    ap = argparse.ArgumentParser(description="cron expressions for The Isle server jobs")
    ap.add_argument("--conf", default=os.environ.get("ISLE_CONF"))
    sub = ap.add_subparsers(dest="action")
    for name in ("check", "match", "next", "describe", "due"):
        p = sub.add_parser(name)
        p.add_argument("expr")
        if name == "match":
            p.add_argument("--at", help="ISO time (default: now, in TIMEZONE)")
        if name == "due":
            p.add_argument("--since", help="last run (YYYY-MM-DDTHH:MM); default: 2 minutes ago")
            p.add_argument("--now", help=argparse.SUPPRESS)
        if name == "next":
            p.add_argument("-n", type=int, default=5)
            p.add_argument("--json", action="store_true")
    o = ap.parse_args(argv)
    if not o.action:
        ap.print_help()
        return 2
    values = isle_logs.read_conf(o.conf) if o.conf else {}
    try:
        cron = Cron(o.expr)
    except CronError as exc:
        print("invalid schedule '%s': %s" % (o.expr, exc), file=sys.stderr)
        return 2
    if o.action == "check":
        print(cron.describe())
        return 0
    if o.action == "describe":
        print(cron.describe())
        return 0
    if o.action == "match":
        try:
            at = parse_at(o.at) if o.at else now_for(values)
        except CronError as exc:
            print(exc, file=sys.stderr)
            return 2
        return 0 if cron.matches(at) else 1
    if o.action == "due":
        try:
            now = parse_at(o.now) if o.now else now_for(values)
            now = now.replace(second=0, microsecond=0)
            since = parse_at(o.since) if o.since else now - datetime.timedelta(minutes=2)
        except CronError as exc:
            print(exc, file=sys.stderr)
            return 2
        since = max(since, now - datetime.timedelta(minutes=10))   # never catch up a long outage
        t = now
        while t > since:
            if cron.matches(t):
                print(t.strftime("%Y-%m-%dT%H:%M"))
                return 0
            t -= datetime.timedelta(minutes=1)
        return 1
    runs = cron.next_runs(now_for(values), max(1, min(o.n, 50)))
    if o.json:
        print(json.dumps({"describe": cron.describe(), "zone": isle_logs.zone_label(values),
                          "next": [r.strftime("%Y-%m-%dT%H:%M:00") for r in runs]}))
    else:
        for r in runs:
            print(r.strftime("%Y-%m-%d %H:%M ") + isle_logs.zone_label(values))
    return 0


if __name__ == "__main__":
    sys.exit(main())
