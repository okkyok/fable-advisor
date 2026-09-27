#!/usr/bin/env python3
"""Summarise the routing ledger: is the policy working, and is Jev worth trusting?

    routing-report.py [--ledger PATH] [--json]

Reads the ledger fable-route.py writes (FABLE_LEDGER, default
~/.claude/fable-advisor/routing.jsonl). Decisions, reviews and outcomes are
joined by id; lines written before 5.1 (no "event" field) are counted
separately so old data stays readable. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict

sys.dont_write_bytecode = True  # loading fable-route.py for its config must not litter the plugin
BUCKETS = ((0.0, 0.5), (0.5, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.01))


def load(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    rows.append(row)
    except OSError:
        pass
    return rows


def num(value):
    """A ledger number, or None: hand-edited rows may hold strings, bools or null."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def text(value):
    return value if isinstance(value, str) else None


def tally(values):
    return dict(Counter(v if isinstance(v, (str, int, float, bool, type(None))) else json.dumps(v)
                        for v in values))


def rate(part, whole):
    return None if not whole else round(part / whole, 3)


def mean(values):
    values = [v for v in (num(x) for x in values) if v is not None]
    return None if not values else round(sum(values) / len(values), 2)


def outcome_stats(rows):
    ok = sum(1 for r in rows if r.get("outcome") == "success")
    retried = sum(1 for r in rows if r.get("outcome") == "retry" or (num(r.get("attempts")) or 1) > 1)
    return {"n": len(rows), "success_rate": rate(ok, len(rows)), "retry_rate": rate(retried, len(rows)),
            "avg_attempts": mean([r.get("attempts") for r in rows]),
            "avg_duration_s": mean([r.get("duration_s") for r in rows])}


def report(rows):
    legacy_rows = [r for r in rows if "event" not in r]
    decisions = [r for r in rows if r.get("event") == "decision"]
    reviews = [r for r in rows if r.get("event") == "review"]
    outcomes = {r["id"]: r for r in rows if r.get("event") == "outcome" and text(r.get("id"))}

    out = {"total_decisions": len(decisions),
           "jev_mode": tally((r.get("jev_mode") for r in decisions)),
           "decided_by": tally((r.get("decided_by") for r in decisions)),
           "route_distribution": tally((r.get("actual_route") for r in decisions)),
           "outcomes_recorded": len(outcomes)}

    by_route = defaultdict(list)
    for o in outcomes.values():
        by_route[o.get("actual_route")].append(o)
    out["by_route"] = {k: outcome_stats(v) for k, v in sorted(by_route.items(), key=lambda i: str(i[0]))}
    out["overall"] = outcome_stats(list(outcomes.values()))

    asked = [r for r in decisions if text(r.get("jev_route"))]
    agree = sum(1 for r in asked if r["jev_route"] == r.get("legacy_route"))
    out["jev"] = {
        "consulted": sum(1 for r in decisions if r.get("jev_status") not in (None, "skipped")),
        "skipped_obvious": sum(1 for r in decisions if r.get("jev_status") == "skipped"),
        "status": tally((r.get("jev_status") for r in decisions if r.get("jev_status"))),
        "fallback_reasons": tally((r.get("jev_reason") for r in decisions if r.get("jev_reason"))),
        "agreement_with_legacy": rate(agree, len(asked)),
        "disagreements": tally(("%s->%s" % (r.get("legacy_route"), r["jev_route"])
                                      for r in asked if r["jev_route"] != r.get("legacy_route"))),
        "avg_latency_ms": mean([r.get("jev_latency_ms") for r in decisions]),
    }

    buckets = []
    for low, high in BUCKETS:
        inside = [r for r in asked if num(r.get("jev_confidence")) is not None
                  and low <= r["jev_confidence"] < high]
        done = [outcomes[r["id"]] for r in inside if text(r.get("id")) in outcomes]
        followed = [o for o in done if o.get("actual_route") == o.get("jev_route")]
        buckets.append({"confidence": "%.1f-%.1f" % (low, min(high, 1.0)), "n": len(inside),
                        "agree_legacy": rate(sum(1 for r in inside if r["jev_route"] == r.get("legacy_route")), len(inside)),
                        "success_rate": rate(sum(1 for o in done if o.get("outcome") == "success"), len(done)),
                        "success_when_jev_followed": rate(sum(1 for o in followed if o.get("outcome") == "success"), len(followed))})
    out["confidence_buckets"] = buckets

    # Counterfactual evidence from shadow mode: when Jev wanted something else,
    # how did the route that actually ran do?
    shadow = defaultdict(list)
    for o in outcomes.values():
        if o.get("jev_status") == "shadow" and o.get("jev_route") != o.get("actual_route"):
            shadow["jev=%s ran=%s" % (o.get("jev_route"), o.get("actual_route"))].append(o)
    out["shadow_disagreement_outcomes"] = {k: outcome_stats(v) for k, v in sorted(shadow.items())}

    review_dist = Counter(text(r.get("review")) for r in reviews)
    out["review"] = {"total": len(reviews), "distribution": dict(review_dist),
                     "fable_review_rate": rate(review_dist.get("fable_review", 0), len(reviews)),
                     "decided_by": tally((r.get("review_decided_by") for r in reviews)),
                     "jev_fallback_reasons": tally((r.get("jev_reason") for r in reviews if r.get("jev_reason")))}
    if legacy_rows:
        out["pre_5_1_records"] = {"n": len(legacy_rows),
                                  "by_lane": tally((r.get("lane") for r in legacy_rows)),
                                  "outcome": tally((r.get("outcome") for r in legacy_rows))}
    return out


def render(data):
    lines = []
    for key, value in data.items():
        if isinstance(value, list):
            lines.append("%s:" % key)
            lines += ["  " + json.dumps(item, separators=(", ", ": ")) for item in value]
        elif isinstance(value, dict):
            lines.append("%s:" % key)
            for sub, item in value.items():
                lines.append("  %s: %s" % (sub, json.dumps(item) if isinstance(item, (dict, list)) else item))
        else:
            lines.append("%s: %s" % (key, value))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="routing-report")
    parser.add_argument("--ledger")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    path = args.ledger
    if not path:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "fable_route", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fable-route.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.load_config()
        path = module.ledger_path()
    if not path or not os.path.exists(path):
        print("no ledger at %s" % path, file=sys.stderr)
        return 1
    data = report(load(path))
    print(json.dumps(data, indent=2) if args.json else render(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
