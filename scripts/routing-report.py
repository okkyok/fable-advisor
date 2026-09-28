#!/usr/bin/env python3
"""Summarise the routing ledger: is the policy working, and is Jev worth trusting?

    routing-report.py [--ledger PATH] [--json]

Reads the ledger fable-route.py writes (FABLE_LEDGER, default
~/.claude/fable-advisor/routing.jsonl). Decisions, reviews, lane attempts
(written automatically by codex-lane.sh) and outcomes are joined by id; lines
written before 5.1 (no "event" field) are counted separately so old data stays
readable. Standard library only.

Every number is segmented by routing policy. Rows carry "policy_version" from
5.4.0 on; older rows have none and form the "pre-5.4" segment. A row belongs to
the policy of the decision it joins (a 5.3 decision's lane run is 5.3 evidence
even if it ran after the upgrade), else to its own field. The headline is
`current_policy`; `by_policy_version` holds one full section per policy; and
`historical_all` mixes them and must not be used to judge Jev or a route,
because route names, the deterministic baseline and Jev's options all changed
between policies. Nothing in the ledger is rewritten.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

sys.dont_write_bytecode = True  # loading fable-route.py for its config must not litter the plugin
BUCKETS = ((0.0, 0.5), (0.5, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.01))
HISTORICAL = "pre-5.4"    # rows written before policy_version existed


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


def pct(values, p):
    """Nearest-rank percentile; tail latency, not the mean, decides whether a
    max-effort route fits under the lane's wall clock."""
    values = sorted(v for v in (num(x) for x in values) if v is not None)
    if not values:
        return None
    return round(values[max(0, math.ceil(p / 100.0 * len(values)) - 1)], 2)


def outcome_stats(rows):
    ok = sum(1 for r in rows if r.get("outcome") == "success")
    retried = sum(1 for r in rows if r.get("outcome") == "retry" or (num(r.get("attempts")) or 1) > 1)
    durations = [r.get("duration_s") for r in rows]
    return {"n": len(rows), "success_rate": rate(ok, len(rows)), "retry_rate": rate(retried, len(rows)),
            "avg_attempts": mean([r.get("attempts") for r in rows]),
            "avg_duration_s": mean(durations), "p50_duration_s": pct(durations, 50),
            "p90_duration_s": pct(durations, 90)}


def lane_stats(tasks):
    """Per task: `tasks` is a list of attempt lists, one list per decision."""
    seconds = [sum(num(a.get("duration_s")) or 0 for a in r) for r in tasks]
    return {
        "n": len(tasks),
        "first_try_ok": rate(sum(1 for r in tasks if r[0].get("lane_status") == "ok"), len(tasks)),
        "eventually_ok": rate(sum(1 for r in tasks if any(a.get("lane_status") == "ok" for a in r)), len(tasks)),
        "retry_rate": rate(sum(1 for r in tasks if len(r) > 1), len(tasks)),
        "avg_attempts": mean([len(r) for r in tasks]),
        "avg_lane_s": mean(seconds),
        "p50_lane_s": pct(seconds, 50),
        "p90_lane_s": pct(seconds, 90),
        "timeout_rate": rate(sum(1 for r in tasks if any(a.get("lane_status") == "timeout" for a in r)), len(tasks)),
        "scope_violation_rate": rate(sum(1 for r in tasks if any((num(a.get("scope_violations")) or 0) > 0 for a in r)), len(tasks)),
        "status": tally(a.get("lane_status") for r in tasks for a in r)}


def model_effort(row):
    return "%s/%s" % (text(row.get("model")) or "?", text(row.get("effort")) or "?")


def section(rows):
    """Every measurement over one set of rows. Called once per policy version."""
    decisions = [r for r in rows if r.get("event") == "decision"]
    reviews = [r for r in rows if r.get("event") == "review"]
    outcomes = {r["id"]: r for r in rows if r.get("event") == "outcome" and text(r.get("id"))}
    attempt_rows = [r for r in rows if r.get("event") == "attempt" and text(r.get("id"))]
    attempts = defaultdict(list)
    for r in attempt_rows:
        attempts[r["id"]].append(r)

    out = {"total_decisions": len(decisions),
           "jev_mode": tally((r.get("jev_mode") for r in decisions)),
           "decided_by": tally((r.get("decided_by") for r in decisions)),
           "route_distribution": tally((r.get("actual_route") for r in decisions)),
           "deterministic_route_distribution": tally((r.get("legacy_route") for r in decisions)),
           "consult_first": tally((r.get("consult_reason") or "yes" for r in decisions if r.get("consult_first"))),
           "outcomes_recorded": len(outcomes)}

    by_route = defaultdict(list)
    for o in outcomes.values():
        by_route[o.get("actual_route")].append(o)
    out["by_route"] = {str(k): outcome_stats(v) for k, v in sorted(by_route.items(), key=lambda i: str(i[0]))}
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
        "by_route": {str(route): lane_stats(runs) for route, runs in sorted(lanes.items(), key=lambda i: str(i[0]))},
    }
    # What actually ran, per attempt, from the lane's own model/effort — the
    # truth source when a route name and the run disagree (unmapped, overrides,
    # config changes). One row per attempt, so a retry counts twice here.
    per_pair = defaultdict(list)
    for a in attempt_rows:
        per_pair[model_effort(a)].append(a)
    out["by_model_effort"] = {k: {
        "attempts": len(v),
        "ok_rate": rate(sum(1 for a in v if a.get("lane_status") == "ok"), len(v)),
        "timeout_rate": rate(sum(1 for a in v if a.get("lane_status") == "timeout"), len(v)),
        "avg_s": mean([a.get("duration_s") for a in v]),
        "p50_s": pct([a.get("duration_s") for a in v], 50),
        "p90_s": pct([a.get("duration_s") for a in v], 90),
        "scope_violation_rate": rate(sum(1 for a in v if (num(a.get("scope_violations")) or 0) > 0), len(v)),
        "status": tally(a.get("lane_status") for a in v)} for k, v in sorted(per_pair.items())}

    # Off-list answers are counted under fallback_reasons, not as disagreements.
    asked = [r for r in decisions if text(r.get("jev_route")) and r.get("jev_reason") != "unknown_choice"]
    agree = sum(1 for r in asked if r["jev_route"] == r.get("legacy_route"))
    out["jev"] = {
        "consulted": sum(1 for r in decisions if r.get("jev_status") not in (None, "skipped")),
        "consulted_on_backfill": sum(1 for r in decisions if r.get("backfilled") is True
                                     and r.get("jev_status") not in (None, "skipped")),
        "skipped_obvious": sum(1 for r in decisions if r.get("jev_status") == "skipped"),
        "status": tally((r.get("jev_status") for r in decisions if r.get("jev_status"))),
        "fallback_reasons": tally((r.get("jev_reason") for r in decisions if r.get("jev_reason"))),
        # Where Jev wants to send work, whatever ran: the escalation pressure.
        "jev_recommendation_distribution": tally((r["jev_route"] for r in asked)),
        "agreement_with_legacy": rate(agree, len(asked)),
        "disagreements": tally(("%s->%s" % (r.get("legacy_route"), r["jev_route"])
                                for r in asked if r["jev_route"] != r.get("legacy_route"))),
        "would_accept_in_active": rate(sum(1 for r in asked if r.get("jev_would_accept") is True),
                                       sum(1 for r in asked if r.get("jev_status") == "shadow")),
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
    # how did the route that actually ran do? Compare each row with the same
    # `ran=` route in lane_attempts.by_route: a disagreement bucket that does
    # worse than its route's baseline is where following Jev might have helped.
    shadow = defaultdict(list)
    for o in outcomes.values():
        if o.get("jev_status") == "shadow" and text(o.get("jev_route")) \
                and o.get("jev_reason") != "unknown_choice" and o.get("jev_route") != o.get("actual_route"):
            shadow["jev=%s ran=%s" % (o.get("jev_route"), o.get("actual_route"))].append(o)
    out["shadow_disagreement_outcomes"] = {k: outcome_stats(v) for k, v in sorted(shadow.items())}
    # The same question from lane attempts alone, so shadow data is usable
    # even where outcomes were never recorded.
    shadow_lane, would_accept = defaultdict(list), Counter()
    for d in decisions:
        runs = attempts.get(text(d.get("id")) or "")
        if runs and d.get("jev_status") == "shadow" and text(d.get("jev_route")) \
                and d.get("jev_reason") != "unknown_choice" and d["jev_route"] != d.get("actual_route"):
            key = "jev=%s ran=%s" % (d["jev_route"], d.get("actual_route"))
            shadow_lane[key].append(runs)
            would_accept[key] += d.get("jev_would_accept") is True
    out["shadow_disagreement_lanes"] = {k: dict(lane_stats(v), would_accept_in_active=would_accept[k])
                                        for k, v in sorted(shadow_lane.items())}

    # Compliance: is the measurement itself trustworthy? Every lane run is logged
    # mechanically; these rates show how often the manual steps were skipped.
    decision_ids = {d["id"] for d in decisions if text(d.get("id"))}
    # A backfilled decision joins its run for the report, but the router was
    # still skipped: the attempt keeps `unrouted`, so it does not count as routed.
    routed_runs = [r for r in attempt_rows if r["id"] in decision_ids and r.get("unrouted") is not True]
    codex = [d for d in decisions if d.get("lane") == "codex-implementer" and text(d.get("id"))]
    claude = [d for d in decisions if d.get("lane") in ("implementer", "self") and text(d.get("id"))]
    open_decisions = [d for d in decisions if text(d.get("id")) and d["id"] not in outcomes]
    out["compliance"] = {
        "lane_runs": len(attempt_rows),
        "routed_lane_run_rate": rate(len(routed_runs), len(attempt_rows)),
        "unrouted_lane_runs": sum(1 for r in attempt_rows if r.get("unrouted") is True),
        "backfilled_decisions": sum(1 for d in decisions if d.get("backfilled") is True),
        "unmapped_backfills": sum(1 for d in decisions if d.get("backfilled") is True
                                  and d.get("actual_route") == "unmapped"),
        "codex_decisions_without_lane_run": sum(1 for d in codex if d["id"] not in attempts),
        "outcome_rate": rate(len(decisions) - len(open_decisions), len(decisions)),
        "outcome_rate_codex_routes": rate(sum(1 for d in codex if d["id"] in outcomes), len(codex)),
        "outcome_rate_claude_routes": rate(sum(1 for d in claude if d["id"] in outcomes), len(claude)),
        "reviews_linked_to_a_decision": rate(sum(1 for r in reviews if text(r.get("id")) in decision_ids), len(reviews)),
        "open_decisions_recent": ["%s %s %s" % (d["id"], d.get("ts", ""), str(d.get("task") or "")[:40])
                                  for d in open_decisions[-5:]],
    }

    review_dist = Counter(text(r.get("review")) for r in reviews)
    review_asked = [r for r in reviews if text(r.get("jev_route")) and r.get("jev_reason") != "unknown_choice"]
    out["review"] = {"total": len(reviews), "distribution": dict(review_dist),
                     "opus_review_rate": rate(review_dist.get("opus_review", 0), len(reviews)),
                     "fable_review_rate": rate(review_dist.get("fable_review", 0), len(reviews)),
                     "decided_by": tally((r.get("review_decided_by") for r in reviews)),
                     "jev_recommendation_distribution": tally((r["jev_route"] for r in review_asked)),
                     "jev_disagreements": tally(("%s->%s" % (r.get("legacy_review"), r["jev_route"])
                                                 for r in review_asked if r["jev_route"] != r.get("legacy_review"))),
                     "jev_fallback_reasons": tally((r.get("jev_reason") for r in reviews if r.get("jev_reason")))}
    return out


def policy_of(row, decision_policy):
    """The routing policy a row is evidence for (see the module docstring)."""
    joined = decision_policy.get(text(row.get("id")) or "")
    if joined:
        return joined
    return text(row.get("policy_version")) or HISTORICAL


def report(rows, current):
    legacy_rows = [r for r in rows if "event" not in r]
    evented = [r for r in rows if "event" in r]
    decision_policy = {}
    for r in evented:
        if r.get("event") == "decision" and text(r.get("id")):
            decision_policy[r["id"]] = text(r.get("policy_version")) or HISTORICAL
    segments = defaultdict(list)
    for r in evented:
        segments[policy_of(r, decision_policy)].append(r)

    def order(version):  # pre-5.4 first, then versions ascending
        if version == HISTORICAL:
            return (0,)
        return (1,) + tuple(int(p) if p.isdigit() else 0 for p in version.split("."))

    out = {"current_policy_version": current,
           "policy_version_distribution": {
               kind: tally(policy_of(r, decision_policy) for r in evented if r.get("event") == kind)
               for kind in ("decision", "review", "attempt", "outcome")},
           "current_policy": section(segments.get(current, [])),
           "by_policy_version": {v: section(segments[v]) for v in sorted(segments, key=order)},
           "historical_all": dict(
               note="mixes routing policies (route names, baseline and Jev options differ); "
                    "not for judging Jev or a route",
               **section(evented))}
    if legacy_rows:
        out["pre_5_1_records"] = {"n": len(legacy_rows),
                                  "by_lane": tally((r.get("lane") for r in legacy_rows)),
                                  "outcome": tally((r.get("outcome") for r in legacy_rows))}
    return out


def render(data, indent=0):
    pad, lines = "  " * indent, []
    for key, value in data.items():
        if isinstance(value, list):
            lines.append("%s%s:" % (pad, key))
            lines += [pad + "  " + json.dumps(item, separators=(", ", ": ")) for item in value]
        elif isinstance(value, dict) and value and any(isinstance(v, (dict, list)) for v in value.values()):
            lines.append("%s%s:" % (pad, key))
            lines.append(render(value, indent + 1))
        elif isinstance(value, dict):
            lines.append("%s%s: %s" % (pad, key, json.dumps(value)))
        else:
            lines.append("%s%s: %s" % (pad, key, value))
    return "\n".join(line for line in lines if line)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="routing-report")
    parser.add_argument("--ledger")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    # The router owns both the ledger location and the current policy version.
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "fable_route", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fable-route.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    path = args.ledger
    if not path:
        module.load_config()
        path = module.ledger_path()
    if not path or not os.path.exists(path):
        print("no ledger at %s" % path, file=sys.stderr)
        return 1
    data = report(load(path), module.POLICY_VERSION)
    print(json.dumps(data, indent=2) if args.json else render(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
