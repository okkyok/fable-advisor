#!/usr/bin/env python3
"""Summarise the routing ledger: is the policy working, and is Jev worth trusting?

    routing-report.py [--ledger PATH] [--json]

Reads the ledger fable-route.py writes (FABLE_LEDGER, default
~/.claude/fable-advisor/routing.jsonl). Decisions, reviews, lane attempts
(written automatically by codex-lane.sh --route-id) and outcomes are joined by
id; lines written before 5.1 (no "event" field) are counted
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
    attempts = defaultdict(list)
    for r in rows:
        if r.get("event") == "attempt" and text(r.get("id")):
            attempts[r["id"]].append(r)

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

    # Lane-level evidence, recorded mechanically: available even when nobody
    # ran `outcome`. "first_try_ok" is the lane's own success, not acceptance.
    lanes = defaultdict(list)
    for d in decisions:
        runs = attempts.get(text(d.get("id")) or "")
        if runs:
            lanes[d.get("actual_route")].append(runs)
    out["lane_attempts"] = {
        "tasks_with_attempts": sum(len(v) for v in lanes.values()),
        "tasks_with_outcome": sum(1 for d in decisions if text(d.get("id")) in outcomes),
        "by_route": {str(route): {
            "n": len(runs),
            "first_try_ok": rate(sum(1 for r in runs if r[0].get("lane_status") == "ok"), len(runs)),
            "eventually_ok": rate(sum(1 for r in runs if any(a.get("lane_status") == "ok" for a in r)), len(runs)),
            "avg_attempts": mean([len(r) for r in runs]),
            "avg_lane_s": mean([sum(num(a.get("duration_s")) or 0 for a in r) for r in runs]),
            "scope_violation_rate": rate(sum(1 for r in runs if any((num(a.get("scope_violations")) or 0) > 0 for a in r)), len(runs)),
            "status": tally(a.get("lane_status") for r in runs for a in r)}
            for route, runs in sorted(lanes.items(), key=lambda i: str(i[0]))},
    }

    # Off-list answers are counted under fallback_reasons, not as disagreements.
    asked = [r for r in decisions if text(r.get("jev_route")) and r.get("jev_reason") != "unknown_choice"]
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
    # The same question from lane attempts alone, so shadow data is usable
    # even where outcomes were never recorded.
    shadow_lane = defaultdict(list)
    for d in decisions:
        runs = attempts.get(text(d.get("id")) or "")
        if runs and d.get("jev_status") == "shadow" and text(d.get("jev_route")) \
                and d["jev_route"] != d.get("actual_route"):
            shadow_lane["jev=%s ran=%s" % (d["jev_route"], d.get("actual_route"))].append(runs)
    out["shadow_disagreement_lanes"] = {k: {
        "n": len(v), "first_try_ok": rate(sum(1 for r in v if r[0].get("lane_status") == "ok"), len(v)),
        "avg_attempts": mean([len(r) for r in v])} for k, v in sorted(shadow_lane.items())}

    # Compliance: is the measurement itself trustworthy? Every lane run is logged
    # mechanically; these rates show how often the manual steps were skipped.
    decision_ids = {d["id"] for d in decisions if text(d.get("id"))}
    runs = [r for r in rows if r.get("event") == "attempt" and text(r.get("id"))]
    routed_runs = [r for r in runs if r["id"] in decision_ids]
    codex = [d for d in decisions if d.get("lane") == "codex-implementer" and text(d.get("id"))]
    claude = [d for d in decisions if d.get("lane") in ("implementer", "self") and text(d.get("id"))]
    open_decisions = [d for d in decisions if text(d.get("id")) and d["id"] not in outcomes]
    out["compliance"] = {
        "lane_runs": len(runs),
        "routed_lane_run_rate": rate(len(routed_runs), len(runs)),
        "unrouted_lane_runs": sum(1 for r in runs if r.get("unrouted") is True),
        "codex_decisions_without_lane_run": sum(1 for d in codex if d["id"] not in attempts),
        "outcome_rate": rate(len(decisions) - len(open_decisions), len(decisions)),
        "outcome_rate_codex_routes": rate(sum(1 for d in codex if d["id"] in outcomes), len(codex)),
        "outcome_rate_claude_routes": rate(sum(1 for d in claude if d["id"] in outcomes), len(claude)),
        "reviews_linked_to_a_decision": rate(sum(1 for r in reviews if text(r.get("id")) in decision_ids), len(reviews)),
        "open_decisions_recent": ["%s %s %s" % (d["id"], d.get("ts", ""), str(d.get("task") or "")[:40])
                                  for d in open_decisions[-5:]],
    }

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
