#!/usr/bin/env python3
"""fable-advisor routing: the deterministic policy, an optional Jev layer, the ledger.

    fable-route.py route   [--task T] [--class C] [--route R] < decision-state.json
    fable-route.py review  [--id ID] [--task T]                < review-state.json
    fable-route.py outcome --id ID --outcome O [--attempts N] [--duration S] [--note N]
    fable-route.py config

Obvious cases are decided by rules in this file and never reach Jev. Only the
ambiguous middle does, and only when FABLE_JEV_MODE is shadow or active. With
FABLE_JEV_MODE=off the Jev adapter (jev_route.py) is never imported, no binary is
looked up and no credential is read — deleting the adapter file leaves off mode
fully working.

Requires only the Python 3.8+ standard library.
"""
from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # importing jev_route must not litter the plugin directory
MODES = ("off", "shadow", "active")

# --- configuration: the `:=` defaults in fable-config.sh are the single source ---

def load_config():
    pattern = re.compile(r'^:\s*"\$\{(\w+):=(.*)\}"')
    with open(os.path.join(HERE, "fable-config.sh")) as handle:
        for line in handle:
            match = pattern.match(line.strip())
            # `:=` also replaces a set-but-empty value; mirror bash exactly.
            if match and not os.environ.get(match.group(1)):
                os.environ[match.group(1)] = os.path.expandvars(match.group(2))


def warn(message):
    print("fable-route: " + message, file=sys.stderr)


def jev_mode():
    mode = os.environ["FABLE_JEV_MODE"].strip().lower()
    if mode in MODES:
        return mode
    # An unrecognised mode must never enable Jev by accident.
    warn("unknown FABLE_JEV_MODE=%r; using off" % mode)
    return "off"


def min_confidence():
    try:
        value = float(os.environ["FABLE_JEV_MIN_CONFIDENCE"])
        if 0.0 <= value <= 1.0:
            return value
    except ValueError:
        pass
    # A broken threshold must reject every Jev answer, never accept every one.
    warn("invalid FABLE_JEV_MIN_CONFIDENCE; every Jev decision will be rejected")
    return math.inf


def jev_timeout():
    try:
        value = float(os.environ["FABLE_JEV_TIMEOUT"])
        if 0 < value <= 60:
            return value
    except ValueError:
        pass
    warn("FABLE_JEV_TIMEOUT must be in (0, 60]; using 8")
    return 8.0


# --- decision state -------------------------------------------------------------

# Everything Jev may ever see is on these lists. Unknown keys are dropped, so
# source code, diffs or conversation pasted into the state cannot leak into a
# routing call. `objective` is truncated for the same reason.
ROUTE_FIELDS = {
    "objective": str, "file_count": int, "mechanical": bool,
    "interface_change": bool, "api_change": bool, "schema_change": bool,
    "data_migration": bool, "security_sensitive": bool, "concurrency_sensitive": bool,
    "irreversible": bool, "multi_component": bool, "prior_failures": int,
    "verification_available": bool,
    # Claude-side reasons. Decided by rule, so they are never sent to Jev.
    "context_bound": bool, "below_spawn_floor": bool, "judgment_dominated": bool,
    "claude_only_tool": bool,
}
REVIEW_FIELDS = {
    "objective": str, "file_count": int, "lines_changed": int, "mechanical": bool,
    "verification_passed": bool, "api_change": bool, "schema_change": bool,
    "data_migration": bool, "security_sensitive": bool, "concurrency_sensitive": bool,
    "irreversible": bool, "wide_blast_radius": bool, "lane_disagreement": bool,
    "silence_gap": int, "attempts": int,
}
CLAUDE_SIDE = ("context_bound", "below_spawn_floor", "judgment_dominated", "claude_only_tool")
HIGH_RISK = ("security_sensitive", "data_migration", "schema_change", "api_change",
             "concurrency_sensitive", "irreversible")
OBJECTIVE_MAX = 280


class StateError(Exception):
    pass


def parse_state(text, fields):
    try:
        raw = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError as exc:
        raise StateError("state is not valid JSON: %s" % exc)
    if not isinstance(raw, dict):
        raise StateError("state must be a JSON object")
    state, ignored = {}, sorted(k for k in raw if k not in fields)
    for key, kind in fields.items():
        if key not in raw or raw[key] is None:
            continue
        value = raw[key]
        ok = isinstance(value, bool) if kind is bool else \
            isinstance(value, int) and not isinstance(value, bool) if kind is int else \
            isinstance(value, str)
        if not ok:
            raise StateError("%s must be %s" % (key, kind.__name__))
        if kind is int and value < 0:
            raise StateError("%s must be >= 0" % key)
        state[key] = value[:OBJECTIVE_MAX] if key == "objective" else value
    return state, ignored


def flag(state, key):
    return state.get(key, False) is True


def high_risk(state):
    return [k for k in HIGH_RISK if flag(state, k)]


# --- routes -----------------------------------------------------------------------

# Implementation routes in cost/capability order. `self` (the orchestrator does
# it) is outside the order: it is chosen only by a Claude-side rule.
RANKED = ("luna_low", "luna_high", "sol_high", "claude_fable")
ROUTE_OPTIONS = {
    "luna_low": "Mechanical, localized, fully specified change with clear verification; little reasoning needed.",
    "luna_high": "Ordinary well-specified implementation; the default route.",
    "sol_high": "Well-specified but reasoning-heavy: several components, complex integration, or hard debugging.",
    "claude_fable": "The outcome turns on judgment a written spec cannot capture, not on how hard the code is.",
}
ROUTE_QUESTION = ("Which implementation route does this coding task need? "
                  "Judge only from the task characteristics given.")
REVIEWS = ("none", "self_review", "fable_review")
REVIEW_OPTIONS = {
    "none": "Trivial change fully proven by its passing verification command.",  # rule-only
    "self_review": "Ordinary change; the verification plus a re-read of the diff is enough.",
    "fable_review": "Wide blast radius or hidden risk that warrants an independent senior review.",
}
REVIEW_QUESTION = "What review does this finished, verified change need before it is reported done?"


def lane_for(route):
    model = os.environ["FABLE_CODEX_DEFAULT_MODEL"]
    return {
        "self": {"lane": "self"},
        "luna_low": {"lane": "codex-implementer", "model": model, "effort": "low"},
        "luna_high": {"lane": "codex-implementer", "model": model,
                      "effort": os.environ["FABLE_CODEX_DEFAULT_EFFORT"]},
        "sol_high": {"lane": "codex-implementer", "model": os.environ["FABLE_CODEX_STRONG_MODEL"],
                     "effort": "high"},
        "claude_fable": {"lane": "implementer", "model": "fable"},
    }[route]


def deterministic_route(s):
    """(route, rule, obvious). obvious=True means Jev is never consulted."""
    if flag(s, "context_bound"):
        return "self", "context_bound", True
    if flag(s, "below_spawn_floor"):
        return "self", "below_spawn_floor", True
    if s.get("prior_failures", 0) >= 2:
        return "claude_fable", "failed_twice", True
    if flag(s, "judgment_dominated"):
        return "claude_fable", "judgment_dominated", True
    if (flag(s, "mechanical") and s.get("file_count") is not None and s["file_count"] <= 1
            and flag(s, "verification_available") and s.get("prior_failures", 0) == 0
            and not high_risk(s) and not flag(s, "interface_change")
            and not flag(s, "multi_component")):
        return "luna_low", "mechanical_one_file", True
    return "luna_high", "default", False


def route_floor(s):
    """The cheapest route nothing — Jev or caller — may go below.

    Two failures pin claude_fable. Anything that keeps a task off the
    mechanical_one_file rule (a risk flag, a failure, no verification, an
    interface change, several components, an unknown size) also keeps Jev and
    the caller off luna_low.
    """
    if s.get("prior_failures", 0) >= 2:
        return "claude_fable"
    if (high_risk(s) or s.get("prior_failures", 0) >= 1 or not flag(s, "verification_available")
            or flag(s, "interface_change") or flag(s, "multi_component") or s.get("file_count") is None):
        return "luna_high"
    return "luna_low"


def below(route, floor):
    # `self` is outside the ranking: the orchestrator may take any task itself,
    # except one that has already failed twice (that belongs to claude_fable).
    if route == "self":
        return floor == "claude_fable"
    return route in RANKED and RANKED.index(route) < RANKED.index(floor)


def deterministic_review(s):
    risks = high_risk(s) + [k for k in ("wide_blast_radius", "lane_disagreement") if flag(s, k)]
    if risks:
        return "fable_review", "high_risk:" + ",".join(risks), True
    if s.get("attempts", 1) >= 2:
        return "fable_review", "resisted_two_attempts", True
    if not flag(s, "verification_passed"):
        return "self_review", "verification_not_passed", True
    if (flag(s, "mechanical") and s.get("file_count") is not None and s["file_count"] <= 1
            and not s.get("silence_gap")):
        return "none", "one_file_mechanical_verified", True
    return "self_review", "ordinary", False


# `none` is only ever a rule outcome. In the middle Jev may keep self_review or
# escalate to fable_review — never skip review; that would be the fail-open.
REVIEW_JEV_OPTIONS = {k: v for k, v in REVIEW_OPTIONS.items() if k != "none"}


# --- the Jev layer: reached only in shadow/active, only for the ambiguous middle ---

def consult_jev(mode, question, state, options):
    """Ask Jev; return ledger fields plus the accepted choice (or None).

    Every failure is explicit: jev_status=fallback with a jev_reason, and the
    caller keeps the deterministic route. Nothing here can raise.
    """
    sys.path.insert(0, HERE)
    try:
        import jev_route  # noqa: E402 — lazy by design: off mode never imports it
    except Exception:
        return {"jev_status": "fallback", "jev_reason": "adapter_missing"}, None
    try:
        result = jev_route.classify(question, state, options, jev_timeout())
    except Exception:
        result = {"ok": False, "reason": "adapter_error"}
    fields = {"jev_backend": result.get("backend")}
    if not result.get("ok"):
        # Keep whatever Jev did answer (e.g. an off-list choice) so the
        # disagreement stays visible in the report.
        fields.update(jev_status="fallback", jev_reason=result.get("reason") or "error",
                      jev_route=result.get("choice"), jev_confidence=result.get("confidence"))
        return fields, None
    choice, confidence = result["choice"], result["confidence"]
    fields.update(jev_route=choice, jev_confidence=round(confidence, 4),
                  jev_latency_ms=result.get("latency_ms"))
    reason = None
    if choice not in options:
        reason = "unknown_choice"
    elif confidence < min_confidence():
        reason = "low_confidence"
    if mode == "shadow":
        fields.update(jev_status="shadow", jev_would_accept=reason is None)
        if reason:
            fields["jev_reason"] = reason
        return fields, None
    if reason:
        fields.update(jev_status="fallback", jev_reason=reason)
        return fields, None
    fields["jev_status"] = "accepted"
    return fields, choice


# --- ledger -------------------------------------------------------------------------

def ledger_path():
    path = os.environ["FABLE_LEDGER"]
    return None if path.strip().lower() == "off" else os.path.expanduser(path)


def append(record):
    path = ledger_path()
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        line = json.dumps({k: v for k, v in record.items() if v is not None},
                          ensure_ascii=False, separators=(",", ":")) + "\n"
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
    except OSError as exc:  # a ledger problem never blocks routing
        warn("ledger not written: %s" % exc)


def read_ledger():
    path = ledger_path()
    if not path or not os.path.exists(path):
        return []
    records = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict):  # a hand-edited or foreign line is skipped, not fatal
                records.append(record)
    return records


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def emit(record):
    print(json.dumps({k: v for k, v in record.items() if v is not None},
                     ensure_ascii=False, separators=(",", ":")))


# --- commands -------------------------------------------------------------------------

def cmd_route(args, text):
    state, ignored = parse_state(text, ROUTE_FIELDS)
    mode = jev_mode()
    legacy, rule, obvious = deterministic_route(state)
    floor = route_floor(state)
    record = {"event": "decision", "id": uuid.uuid4().hex[:12], "ts": now(),
              "task": args.task or state.get("objective", "")[:80], "class": args.cls,
              "jev_mode": mode, "legacy_route": legacy, "rule": rule, "floor": floor}
    actual, decided_by = legacy, "rule" if obvious else "legacy"

    if args.route:
        if below(args.route, floor):
            record["override_rejected"] = "below_risk_floor"
        else:
            actual, decided_by = args.route, "caller"
    elif mode != "off":
        if obvious:
            record["jev_status"] = "skipped"
        else:
            options = {k: v for k, v in ROUTE_OPTIONS.items() if not below(k, floor)}
            jev_state = {k: v for k, v in state.items() if k not in CLAUDE_SIDE}
            fields, choice = consult_jev(mode, ROUTE_QUESTION, jev_state, options)
            record.update(fields)
            if choice is not None and not below(choice, floor):
                actual, decided_by = choice, "jev"

    lane = lane_for(actual)
    risks = high_risk(state)
    record.update(actual_route=actual, decided_by=decided_by, **lane)
    if risks:
        record["risk"] = risks
    if any(flag(state, k) for k in ("api_change", "schema_change", "data_migration", "irreversible")):
        record["consult_first"] = "fable-advisor"  # an expensive-to-reverse decision
    if flag(state, "claude_only_tool"):
        record["tool_bridge"] = True  # run the tool op Claude-side; the lane keeps the code
    append(record)
    lane_text = " ".join(str(lane[k]) for k in ("lane", "model", "effort") if k in lane)
    record["declare"] = "route: %s (%s) -> %s" % (actual, decided_by if decided_by != "rule" else rule, lane_text)
    if ignored:
        record["ignored_keys"] = ignored
    emit(record)


def cmd_review(args, text):
    state, ignored = parse_state(text, REVIEW_FIELDS)
    mode = jev_mode()
    legacy, rule, obvious = deterministic_review(state)
    record = {"event": "review", "id": args.id or uuid.uuid4().hex[:12], "ts": now(),
              "task": args.task, "jev_mode": mode, "legacy_review": legacy, "rule": rule}
    actual, decided_by = legacy, "rule" if obvious else "legacy"
    if mode != "off":
        if obvious:
            record["jev_status"] = "skipped"
        else:
            fields, choice = consult_jev(mode, REVIEW_QUESTION, state, REVIEW_JEV_OPTIONS)
            record.update(fields)
            if choice is not None:
                actual, decided_by = choice, "jev"
    record.update(review=actual, review_decided_by=decided_by)
    append(record)
    if ignored:
        record["ignored_keys"] = ignored
    emit(record)


OUTCOMES = ("success", "retry", "failover", "blocked", "unavailable", "timeout")


def cmd_outcome(args):
    decision, review = {}, {}
    for rec in read_ledger():
        if rec.get("id") == args.id and rec.get("event") == "decision":
            decision = rec
        elif rec.get("id") == args.id and rec.get("event") == "review":
            review = rec
    if not decision:
        warn("no decision with id %s in the ledger; writing the outcome alone" % args.id)
    record = {k: v for k, v in decision.items() if k not in ("event", "ts", "declare")}
    for key, value in review.items():
        if key in ("legacy_review", "review", "review_decided_by"):
            record[key] = value
        elif key.startswith("jev_"):
            record["review_" + key] = value
    record.update(event="outcome", id=args.id, ts=now(), outcome=args.outcome,
                  attempts=args.attempts, duration_s=args.duration, note=args.note)
    append(record)
    emit(record)


def cmd_config(_args):
    info = {k: os.environ[k] for k in sorted(os.environ) if k.startswith("FABLE_")}
    info["jev_mode_effective"] = jev_mode()
    info["ledger_effective"] = ledger_path()
    if info["jev_mode_effective"] != "off":  # never probe when off
        sys.path.insert(0, HERE)
        try:
            import jev_route
            info["jev_backend"] = jev_route.describe_backend()
        except Exception:
            info["jev_backend"] = "adapter_missing"
    emit(info)


def main(argv=None):
    load_config()
    parser = argparse.ArgumentParser(prog="fable-route")
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("route", help="decide an implementation route from a decision state on stdin")
    r.add_argument("--task", default="")
    r.add_argument("--class", dest="cls", default="implement")
    r.add_argument("--route", choices=("self",) + RANKED, help="the architect's explicit choice")
    r.add_argument("--state", default="-", help="state file, or - for stdin")
    v = sub.add_parser("review", help="decide a review from a review state on stdin")
    v.add_argument("--id", help="the route decision's id, to join them in the ledger")
    v.add_argument("--task", default=None)
    v.add_argument("--state", default="-")
    o = sub.add_parser("outcome", help="record how a routed task ended")
    o.add_argument("--id", required=True)
    o.add_argument("--outcome", required=True, choices=OUTCOMES)
    o.add_argument("--attempts", type=int, default=1)
    o.add_argument("--duration", type=float, default=None)
    o.add_argument("--note", default=None)
    sub.add_parser("config", help="print the effective configuration")
    args = parser.parse_args(argv)
    try:
        if args.command in ("route", "review"):
            text = sys.stdin.read() if args.state == "-" else open(args.state).read()
            (cmd_route if args.command == "route" else cmd_review)(args, text)
        elif args.command == "outcome":
            cmd_outcome(args)
        else:
            cmd_config(args)
    except (StateError, OSError) as exc:
        warn(str(exc))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
