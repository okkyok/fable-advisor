#!/usr/bin/env python3
"""fable-advisor routing: the deterministic policy, an optional Jev layer, the ledger.

    fable-route.py route   [--task T] [--class C] [--route R] < decision-state.json
    fable-route.py review  [--id ID] [--task T]                < review-state.json
    fable-route.py outcome --id ID --outcome O [--attempts N] [--duration S] [--note N]
    fable-route.py attempt --id ID --lane-status S ...   (written by codex-lane.sh --route-id)
    fable-route.py backfill --model M --effort E --file-count N ...   (codex-lane.sh, no --route-id)
    fable-route.py config

This file is the routing policy. The orchestration skill describes roles and
judgment; every rule, floor, eligibility check and Jev gate lives here only.
Route ids are stable names; the models behind them are configuration
(fable-config.sh, and the agents' own `effort:` pins for Claude-side roles):

    luna_low          default worker, low effort    mechanical, one file, verified, no risk
    luna_high         default worker                ordinary implementation (the default)
    luna_max          default worker, max effort    narrow retry after one failure (gated)
    sol_high          broad worker                  several interacting components
    claude_opus_high  senior worker (implementer)   two failures, or judgment a spec cannot carry
    Fable             frontier advisor: consult_first / fable_review, never implements

Obvious cases are decided by rules in this file and never reach Jev. Only the
ambiguous middle does, and only when FABLE_JEV_MODE is shadow or active. With
FABLE_JEV_MODE=off the Jev adapter (jev_route.py) is never imported, no binary is
looked up and no credential is read — deleting the adapter file leaves off mode
fully working.

FABLE_IMAJEV_MODE=shadow adds a measurement beside Jev, nothing more: at the
same decisions Jev is asked about (never the obvious ones), Imajev is sent the
same question, the same state object and the same options, and its answer is
logged as imajev_*. It runs concurrently with Jev and can never change a route
or a review. Off (the default) never imports imajev_route.py or opens a socket.

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
import threading
import time
import uuid

POLICY_VERSION = "5.5.0"  # bump whenever routes, rules, floors, Jev options or lane semantics change
HERE = os.path.dirname(os.path.abspath(__file__))
AGENTS_DIR = os.path.join(os.path.dirname(HERE), "agents")
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


def min_confidence(var="FABLE_JEV_MIN_CONFIDENCE", who="Jev"):
    try:
        value = float(os.environ[var])
        if 0.0 <= value <= 1.0:
            return value
    except ValueError:
        pass
    # A broken threshold must reject every Jev answer, never accept every one.
    warn("invalid %s; every %s decision will be rejected" % (var, who))
    return math.inf


def jev_timeout(var="FABLE_JEV_TIMEOUT"):
    try:
        value = float(os.environ[var])
        if 0 < value <= 60:
            return value
    except ValueError:
        pass
    warn("%s must be in (0, 60]; using 8" % var)
    return 8.0


def imajev_mode():
    mode = os.environ.get("FABLE_IMAJEV_MODE", "off").strip().lower()
    if mode in ("off", "shadow"):
        return mode
    # Imajev is measurement only: there is no active mode, and nothing unknown
    # may start network calls.
    warn("unknown FABLE_IMAJEV_MODE=%r (off | shadow); using off" % mode)
    return "off"


def experiment_tag():
    """FABLE_IMAJEV_EXPERIMENT_TAG as logged, or None when unset."""
    return os.environ.get("FABLE_IMAJEV_EXPERIMENT_TAG", "").strip()[:64] or None


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
    # Fable-consult signals. Also rule-only: they send the task to fable-advisor
    # before any implementation, never to Jev.
    "architectural_deadlock": bool, "opus_failed": bool,
    # Scope mode for the worker. Rule-only: it changes how a lane is run, not
    # which route, so it is never sent to Jev.
    "strict_scope": bool,
}
REVIEW_FIELDS = {
    "objective": str, "file_count": int, "lines_changed": int, "mechanical": bool,
    "verification_passed": bool, "api_change": bool, "schema_change": bool,
    "data_migration": bool, "security_sensitive": bool, "concurrency_sensitive": bool,
    "irreversible": bool, "wide_blast_radius": bool, "lane_disagreement": bool,
    "silence_gap": int, "attempts": int,
    # Exceptional-review signals (fable_review). Rule-only, never sent to Jev.
    "architectural_deadlock": bool, "opus_review_inconclusive": bool,
}
CLAUDE_SIDE = ("context_bound", "below_spawn_floor", "judgment_dominated", "claude_only_tool")
# Keys decided by rule alone and never part of what Jev sees.
ROUTE_RULE_ONLY = CLAUDE_SIDE + ("architectural_deadlock", "opus_failed", "strict_scope")
REVIEW_RULE_ONLY = ("architectural_deadlock", "opus_review_inconclusive")
HIGH_RISK = ("security_sensitive", "data_migration", "schema_change", "api_change",
             "concurrency_sensitive", "irreversible")
# Where an exhaustive file allowlist is worth the lost autonomy. Everything else
# runs with Files as the expected scope (see codex-lane.sh).
STRICT_SCOPE_RISKS = ("security_sensitive", "data_migration", "irreversible")
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

# Implementation routes. TIER orders them by cost for the risk floor only:
# luna_max and sol_high share a tier because they are not a ladder — luna_max is
# depth on a narrow retry, sol_high is breadth on integration-heavy work.
# `self` (the orchestrator does it) is outside the order: only a Claude-side
# rule chooses it. Fable is not here at all: it is consulted (consult_first) or
# reviews (fable_review), and never implements, so neither Jev nor a caller can
# route to it.
ROUTES = ("luna_low", "luna_high", "luna_max", "sol_high", "claude_opus_high")
TIER = {"luna_low": 0, "luna_high": 1, "luna_max": 2, "sol_high": 2, "claude_opus_high": 3}
ROUTE_OPTIONS = {
    "luna_low": "Mechanical, localized, fully specified change with clear verification; little reasoning needed.",
    "luna_high": "Ordinary well-specified implementation; the default route.",
    "luna_max": "Narrow, clearly specified task with runnable verification that already failed once; "
                "needs deeper reasoning on the same small scope, not more breadth.",
    "sol_high": "Broad or integration-heavy work: several interacting files or components, interface-heavy "
                "implementation, or debugging with a wide search space.",
    "claude_opus_high": "Already failed, and what remains is a local judgment or trade-off a written spec "
                        "cannot pin down; the problem itself is understood.",
}
ROUTE_QUESTION = ("Which implementation route does this coding task need? "
                  "Judge only from the task characteristics given.")
REVIEWS = ("none", "self_review", "opus_review", "fable_review")
REVIEW_OPTIONS = {
    "none": "Trivial change fully proven by its passing verification command.",  # rule-only
    "self_review": "Ordinary change; the verification plus a re-read of the diff is enough.",
    "opus_review": "Wide blast radius or hidden risk that warrants an independent senior review.",
    "fable_review": "The approach or framing itself is in doubt and a senior review did not settle it.",  # rule-only
}
REVIEW_QUESTION = "What review does this finished, verified change need before it is reported done?"

# luna_max is a retry at the same small scope, so it stays inside a budget that a
# max-effort run can finish under the lane's ~570 s wall clock: three files is
# the largest "narrow" we are willing to assume before there is timeout data.
LUNA_MAX_MAX_FILES = 3


def agent_effort(agent):
    """The effort a Claude-side agent actually runs at: its frontmatter pin.

    The Agent tool takes a model per spawn but no effort, and no environment
    variable sets a subagent's effort, so the `effort:` line in agents/<agent>.md
    is the only switch that takes effect. Reading it here makes the ledger
    record what ran — change the pin (e.g. high -> medium) and the next rows say
    so. No pin means the subagent inherits the session's effort: "inherit".
    """
    try:
        with open(os.path.join(AGENTS_DIR, agent + ".md"), encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return None
    front = text.split("\n---", 1)[0] if text.startswith("---") else ""
    match = re.search(r"^effort:\s*([A-Za-z]+)\s*$", front, re.M)
    return match.group(1) if match else "inherit"


def lane_for(route):
    model = os.environ["FABLE_CODEX_DEFAULT_MODEL"]
    return {
        "self": {"lane": "self"},
        "luna_low": {"lane": "codex-implementer", "role": "default_worker", "model": model, "effort": "low"},
        "luna_high": {"lane": "codex-implementer", "role": "default_worker", "model": model,
                      "effort": os.environ["FABLE_CODEX_DEFAULT_EFFORT"]},
        "luna_max": {"lane": "codex-implementer", "role": "deep_worker", "model": model, "effort": "max"},
        "sol_high": {"lane": "codex-implementer", "role": "broad_worker",
                     "model": os.environ["FABLE_CODEX_STRONG_MODEL"], "effort": "high"},
        # The model is passed on the spawn (it outranks frontmatter); the effort
        # can only come from the agent file's pin, so it is read from there.
        "claude_opus_high": {"lane": "implementer", "role": "senior_worker",
                             "model": os.environ["FABLE_SENIOR_MODEL"], "effort": agent_effort("implementer")},
    }[route]


def review_lane_for(review):
    return {
        "none": {},
        "self_review": {"reviewer": "self"},
        "opus_review": {"reviewer": "opus-reviewer", "reviewer_role": "senior_reviewer",
                        "reviewer_model": os.environ["FABLE_SENIOR_MODEL"],
                        "reviewer_effort": agent_effort("opus-reviewer")},
        "fable_review": {"reviewer": "fable-advisor", "reviewer_role": "frontier_advisor",
                         "reviewer_model": os.environ["FABLE_FRONTIER_MODEL"],
                         "reviewer_effort": agent_effort("fable-advisor")},
    }[review]


def strict_scope_reason(s):
    """Why this task's Files must be an exhaustive allowlist, or None."""
    if flag(s, "strict_scope"):
        return "requested"
    risks = [k for k in STRICT_SCOPE_RISKS if flag(s, k)]
    return ",".join(risks) if risks else None


def lane_args(record):
    """The codex-lane.sh flags that carry this decision, so no one retypes them."""
    if record.get("lane") != "codex-implementer":
        return None
    args = "--model %s --effort %s --route-id %s" % (record["model"], record["effort"], record["id"])
    return args + (" --strict-scope" if record.get("strict_scope") else "")


def failures(s):
    return s.get("prior_failures", 0)


def luna_max_eligible(s):
    """luna_max is a narrow retry, never a first attempt or a hard-task default.

    One failure (two already pin claude_opus_high), a runnable verification, a
    known and small file count, no breadth (multi_component, interface_change —
    that is sol_high's shape), no risk flag, and no sign the approach itself is
    wrong (that goes to a Fable consult, not to more reasoning on the same spec).
    """
    return (failures(s) == 1 and flag(s, "verification_available")
            and s.get("file_count") is not None and s["file_count"] <= LUNA_MAX_MAX_FILES
            and not flag(s, "multi_component") and not flag(s, "interface_change")
            and not high_risk(s)
            and not flag(s, "architectural_deadlock") and not flag(s, "opus_failed"))


def deterministic_route(s):
    """(route, rule, obvious). obvious=True means Jev is never consulted."""
    if flag(s, "context_bound"):
        return "self", "context_bound", True
    if flag(s, "below_spawn_floor"):
        return "self", "below_spawn_floor", True
    if failures(s) >= 2:
        return "claude_opus_high", "failed_twice", True
    # The approach itself is in doubt: fable-advisor is consulted first (see
    # consult_reason) and the implementation stays with Opus until the consult
    # produces a new spec, which is then routed as a new decision.
    if flag(s, "architectural_deadlock"):
        return "claude_opus_high", "architectural_deadlock", True
    if flag(s, "opus_failed"):
        return "claude_opus_high", "opus_failed", True
    if flag(s, "judgment_dominated"):
        return "claude_opus_high", "judgment_dominated", True
    if (flag(s, "mechanical") and s.get("file_count") is not None and s["file_count"] <= 1
            and flag(s, "verification_available") and failures(s) == 0
            and not high_risk(s) and not flag(s, "interface_change")
            and not flag(s, "multi_component")):
        return "luna_low", "mechanical_one_file", True
    # A first retry stays at luna_high by rule; luna_max is an eligible option
    # (Jev in active mode, or the caller) until the ledger shows it earns more.
    return "luna_high", "retry" if failures(s) else "default", False


def consult_reason(s):
    """Why fable-advisor must be consulted before implementing, or None.

    Fable reframes: it questions the approach and the problem statement, and its
    answer becomes a new spec that a Luna/Sol/Opus lane implements.
    """
    if failures(s) >= 3:
        return "failed_three_times"
    for key in ("architectural_deadlock", "opus_failed"):
        if flag(s, key):
            return key
    if any(flag(s, k) for k in ("api_change", "schema_change", "data_migration", "irreversible")):
        return "expensive_to_reverse"
    return None


def route_floor(s):
    """The cheapest route nothing — Jev or caller — may go below.

    Two failures pin claude_opus_high. Anything that keeps a task off the
    mechanical_one_file rule (a risk flag, a failure, no verification, an
    interface change, several components, an unknown size) also keeps Jev and
    the caller off luna_low.
    """
    if failures(s) >= 2:
        return "claude_opus_high"
    if (high_risk(s) or failures(s) >= 1 or not flag(s, "verification_available")
            or flag(s, "interface_change") or flag(s, "multi_component") or s.get("file_count") is None):
        return "luna_high"
    return "luna_low"


def below(route, floor):
    # `self` is outside the ranking: the orchestrator may take any task itself,
    # except one that has already failed twice (that belongs to claude_opus_high).
    if route == "self":
        return floor == "claude_opus_high"
    return route in TIER and TIER[route] < TIER[floor]


def route_refusal(route, s, floor):
    """Why `route` may not run for state `s` (None if it may). Applies to Jev and
    caller alike, so no confidence and no override gets past it."""
    if below(route, floor):
        return "below_risk_floor"
    if route == "luna_max" and not luna_max_eligible(s):
        return "luna_max_ineligible"
    return None


def jev_route_options(s, floor):
    """The routes Jev may pick from in the ambiguous middle.

    First attempts: luna_high / sol_high (and luna_low when the floor allows) —
    Jev never sends a first attempt to Claude. After one failure: luna_high,
    sol_high, claude_opus_high, and luna_max when eligible. Two failures never
    reach Jev (hard rule), and Fable is never an option.
    """
    return {k: v for k, v in ROUTE_OPTIONS.items()
            if route_refusal(k, s, floor) is None
            and not (k == "claude_opus_high" and failures(s) < 1)}


def deterministic_review(s):
    """(review, rule, obvious). fable_review is exceptional: the approach itself
    is contested. Ordinary high risk is a senior review by Opus."""
    exceptional = [k for k in ("architectural_deadlock", "opus_review_inconclusive", "lane_disagreement")
                   if flag(s, k)]
    if exceptional:
        return "fable_review", "exceptional:" + ",".join(exceptional), True
    risks = high_risk(s) + (["wide_blast_radius"] if flag(s, "wide_blast_radius") else [])
    if risks:
        return "opus_review", "high_risk:" + ",".join(risks), True
    if s.get("attempts", 1) >= 2:
        return "opus_review", "resisted_two_attempts", True
    if not flag(s, "verification_passed"):
        return "self_review", "verification_not_passed", True
    if (flag(s, "mechanical") and s.get("file_count") is not None and s["file_count"] <= 1
            and not s.get("silence_gap")):
        return "none", "one_file_mechanical_verified", True
    return "self_review", "ordinary", False


# `none` and `fable_review` are only ever rule outcomes. In the middle Jev may
# keep self_review or escalate to opus_review — never skip review (the
# fail-open), and never spend Fable on its own say-so.
REVIEW_JEV_OPTIONS = {k: v for k, v in REVIEW_OPTIONS.items() if k in ("self_review", "opus_review")}


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


# Fallbacks raised before the state left this process: Jev read nothing.
JEV_NOT_SENT = ("adapter_missing", "adapter_error", "invalid_backend", "executable_missing",
                "state_too_large")


def jev_input(fields, state):
    """The state as Jev read it, for the decision row — or None when it never got there."""
    return None if fields.get("jev_reason") in JEV_NOT_SENT else state


# --- Imajev shadow: the same decision, logged only ---------------------------------

def imajev_start(question, state, options):
    """Start an Imajev call in the background; imajev_finish() collects it.

    A daemon thread, so a server that never answers cannot hold the process
    open; the join in imajev_finish is the hard deadline. Nothing here raises.
    """
    sys.path.insert(0, HERE)
    try:
        import imajev_route  # noqa: E402 — lazy by design: off mode never imports it
    except Exception:
        return {"result": {"ok": False, "reason": "adapter_missing"}}
    timeout = jev_timeout("FABLE_IMAJEV_TIMEOUT")
    box = {"started": time.monotonic(), "deadline": time.monotonic() + timeout + 1.0}

    def run():
        try:
            box["result"] = imajev_route.classify(question, state, options, timeout)
        except Exception:
            box["result"] = {"ok": False, "reason": "adapter_error"}

    box["thread"] = threading.Thread(target=run, name="imajev-shadow", daemon=True)
    box["thread"].start()
    return box


def imajev_finish(box, options):
    """imajev_* ledger fields for a started call. Shadow only: never a route."""
    thread = box.get("thread")
    if thread is not None:
        thread.join(max(0.0, box["deadline"] - time.monotonic()))
    result = box.get("result")
    if not isinstance(result, dict):  # still running past its deadline
        result = {"ok": False, "reason": "timeout",
                  "latency_ms": int((time.monotonic() - box["started"]) * 1000)}
    fields = {"imajev_backend": result.get("backend"), "imajev_model": result.get("model"),
              "imajev_latency_ms": result.get("latency_ms")}
    if not result.get("ok"):
        fields.update(imajev_status="fallback", imajev_reason=result.get("reason") or "error",
                      imajev_route=result.get("choice"), imajev_confidence=result.get("confidence"))
        return fields
    choice, confidence = result["choice"], result["confidence"]
    fields.update(imajev_route=choice, imajev_confidence=round(confidence, 4),
                  imajev_server_ms=result.get("server_ms"),
                  imajev_probabilities=result.get("probabilities") or None,
                  imajev_unknown_probability=result.get("unknown_probability"),
                  imajev_abstained=result.get("abstained"),
                  imajev_calibration_version=result.get("calibration_version"))
    reason = None
    if choice not in options:
        reason = "unknown_choice"
    elif result.get("abstained") is True:
        reason = "abstained"  # its top choice is kept above, but it said it cannot tell
    elif confidence < min_confidence("FABLE_IMAJEV_MIN_CONFIDENCE", "Imajev"):
        reason = "low_confidence"
    fields.update(imajev_status="shadow", imajev_would_accept=reason is None, imajev_reason=reason)
    return fields


# Fallbacks raised before the state reached the server: Imajev read nothing.
IMAJEV_NOT_SENT = ("adapter_missing", "adapter_error", "invalid_url", "state_too_large", "unavailable")


def imajev_input(fields, state):
    """The state as Imajev read it — the very object Jev was given — or None."""
    return None if fields.get("imajev_reason") in IMAJEV_NOT_SENT else state


def consult(jev, imajev, question, state, options):
    """Jev exactly as before, plus Imajev (shadow) on the same question, state and options.

    Both start before either is awaited, so the added wait is the slower of the
    two, not their sum. Only Jev's choice is returned; Imajev only adds fields.
    """
    pending = imajev_start(question, state, options) if imajev == "shadow" else None
    fields, choice = consult_jev(jev, question, state, options) if jev != "off" else ({}, None)
    if pending is not None:
        fields.update(imajev_finish(pending, options))
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

def skip(record, mode, imode):
    """An obvious case: rules decide it, and neither model is asked."""
    if mode != "off":
        record["jev_status"] = "skipped"
    if imode != "off":
        record["imajev_status"] = "skipped"


def log_inputs(record, fields, state, mode, imode):
    if mode != "off":
        record["jev_input"] = jev_input(fields, state)
    if imode != "off":
        record["imajev_input"] = imajev_input(fields, state)


def cmd_route(args, text):
    state, ignored = parse_state(text, ROUTE_FIELDS)
    mode, imode = jev_mode(), imajev_mode()
    legacy, rule, obvious = deterministic_route(state)
    floor = route_floor(state)
    record = {"event": "decision", "id": uuid.uuid4().hex[:12], "ts": now(),
              "policy_version": POLICY_VERSION,
              "task": args.task or state.get("objective", "")[:80], "class": args.cls,
              "jev_mode": mode, "legacy_route": legacy, "rule": rule, "floor": floor}
    if imode != "off":
        record.update(imajev_mode=imode, imajev_experiment_tag=experiment_tag())
    if luna_max_eligible(state):
        record["luna_max_eligible"] = True
    actual, decided_by = legacy, "rule" if obvious else "legacy"

    if args.route:
        refusal = route_refusal(args.route, state, floor)
        if refusal:
            record["override_rejected"] = refusal
        else:
            actual, decided_by = args.route, "caller"
    elif mode != "off" or imode != "off":
        if obvious:
            skip(record, mode, imode)
        else:
            options = jev_route_options(state, floor)
            jev_state = {k: v for k, v in state.items() if k not in ROUTE_RULE_ONLY}
            fields, choice = consult(mode, imode, ROUTE_QUESTION, jev_state, options)
            record.update(fields)
            log_inputs(record, fields, jev_state, mode, imode)
            # consult_jev only accepts a choice from `options`; the refusal check
            # is repeated so no future option list can smuggle past the floor.
            if choice is not None and route_refusal(choice, state, floor) is None:
                actual, decided_by = choice, "jev"

    lane = lane_for(actual)
    risks = high_risk(state)
    record.update(actual_route=actual, decided_by=decided_by, **lane)
    if risks:
        record["risk"] = risks
    reason = consult_reason(state)
    if reason:
        # Fable reframes before anyone implements; the route above implements
        # the spec that comes out of the consult.
        record.update(consult_first="fable-advisor", consult_reason=reason)
    if flag(state, "claude_only_tool"):
        record["tool_bridge"] = True  # run the tool op Claude-side; the lane keeps the code
    strict = strict_scope_reason(state)
    if strict and actual != "self":
        record.update(strict_scope=True, strict_scope_reason=strict)
    append(record)
    record["lane_args"] = lane_args(record)
    lane_text = " ".join(str(lane[k]) for k in ("lane", "model", "effort") if lane.get(k))
    record["declare"] = "route: %s (%s) -> %s" % (actual, decided_by if decided_by != "rule" else rule, lane_text)
    if ignored:
        record["ignored_keys"] = ignored
    emit(record)


def observed_route(model, effort):
    """The route a lane's own model/effort amounts to, or "unmapped".

    Exact matches only. A model/effort pair no route runs (Luna at medium or
    xhigh, Sol at anything but high, another model) is "unmapped" rather than
    the nearest route: folding xhigh into luna_high would contaminate exactly
    the high-vs-max comparison the ledger exists for. The record keeps the
    real model and effort either way.
    """
    if model == os.environ["FABLE_CODEX_STRONG_MODEL"]:
        return "sol_high" if effort == "high" else "unmapped"
    if model == os.environ["FABLE_CODEX_DEFAULT_MODEL"]:
        if effort == "low":
            return "luna_low"
        if effort == "max":
            return "luna_max"
        if effort == os.environ["FABLE_CODEX_DEFAULT_EFFORT"]:
            return "luna_high"
    return "unmapped"


def cmd_backfill(args):
    """A decision for a lane run that skipped the router, written by codex-lane.sh.

    The lane has already chosen its model and effort, so nothing here may change
    them: the actual route is what runs, and Jev — in shadow and active alike —
    is only logged. That turns every unrouted run into shadow evidence instead
    of a run the report cannot join to anything.
    """
    state = {"file_count": args.file_count}
    if args.objective:
        state["objective"] = args.objective[:OBJECTIVE_MAX]
    if args.verification:
        state["verification_available"] = True
    mode, imode = jev_mode(), imajev_mode()
    legacy, rule, obvious = deterministic_route(state)
    actual = observed_route(args.model, args.effort)
    record = {"event": "decision", "id": uuid.uuid4().hex[:12], "ts": now(),
              "policy_version": POLICY_VERSION,
              "task": args.task or state.get("objective", "")[:80], "class": "implement",
              "jev_mode": mode, "legacy_route": legacy, "rule": rule, "floor": route_floor(state),
              "backfilled": True}
    if imode != "off":
        record.update(imajev_mode=imode, imajev_experiment_tag=experiment_tag())
    if mode != "off" or imode != "off":
        if obvious:
            skip(record, mode, imode)
        else:
            options = jev_route_options(state, record["floor"])
            fields, _ = consult("shadow" if mode != "off" else "off", imode, ROUTE_QUESTION, state, options)
            record.update(fields)
            log_inputs(record, fields, state, mode, imode)
    record.update(actual_route=actual, decided_by="lane", lane="codex-implementer",
                  model=args.model, effort=args.effort)
    append(record)
    emit(record)


def lane_verification(route_id):
    """The acceptance result codex-lane.sh recorded for this id (last run), or None."""
    result = None
    for rec in read_ledger():
        if rec.get("id") == route_id and rec.get("event") == "attempt" and rec.get("verify") in ("pass", "fail"):
            result = rec["verify"]
    return result


def cmd_review(args, text):
    state, ignored = parse_state(text, REVIEW_FIELDS)
    # The harness already ran the acceptance command on a codex lane; use its
    # result rather than asking anyone to restate it. A stated value wins.
    source = "caller" if "verification_passed" in state else None
    if source is None and args.id:
        verdict = lane_verification(args.id)
        if verdict:
            state["verification_passed"], source = verdict == "pass", "lane"
    mode, imode = jev_mode(), imajev_mode()
    legacy, rule, obvious = deterministic_review(state)
    record = {"event": "review", "id": args.id or uuid.uuid4().hex[:12], "ts": now(),
              "policy_version": POLICY_VERSION,
              "task": args.task, "jev_mode": mode, "legacy_review": legacy, "rule": rule,
              "verification_source": source}
    if imode != "off":
        record.update(imajev_mode=imode, imajev_experiment_tag=experiment_tag())
    actual, decided_by = legacy, "rule" if obvious else "legacy"
    if mode != "off" or imode != "off":
        if obvious:
            skip(record, mode, imode)
        else:
            # Review rows log no state for either model (unchanged for Jev).
            jev_state = {k: v for k, v in state.items() if k not in REVIEW_RULE_ONLY}
            fields, choice = consult(mode, imode, REVIEW_QUESTION, jev_state, REVIEW_JEV_OPTIONS)
            record.update(fields)
            if choice in REVIEW_JEV_OPTIONS:
                actual, decided_by = choice, "jev"
    reviewer = review_lane_for(actual)
    record.update(review=actual, review_decided_by=decided_by, **reviewer)
    append(record)
    record["declare"] = "review: %s (%s)%s" % (
        actual, decided_by if decided_by != "rule" else rule,
        " -> " + " ".join(str(reviewer[k]) for k in ("reviewer", "reviewer_model", "reviewer_effort")
                          if reviewer.get(k)) if reviewer else "")
    if ignored:
        record["ignored_keys"] = ignored
    emit(record)


OUTCOMES = ("success", "retry", "failover", "blocked", "unavailable", "timeout")
VERDICTS = ("ship", "fix_first", "rethink", "escalate")


LANE_STATUSES = ("ok", "empty_diff", "unavailable", "timeout", "blocked", "error")


def cmd_attempt(args):
    """One codex lane run, recorded by codex-lane.sh itself — no one has to remember."""
    previous = sum(1 for r in read_ledger() if r.get("id") == args.id and r.get("event") == "attempt")
    record = {"event": "attempt", "id": args.id, "ts": now(), "policy_version": POLICY_VERSION,
              "attempt": previous + 1,
              "lane_status": args.lane_status, "rc": args.rc, "duration_s": args.duration,
              "model": args.model, "effort": args.effort, "touched": args.touched,
              "scope_violations": args.violations,
              "reason": args.reason[:200] if args.reason else None,
              "unrouted": True if args.unrouted else None,
              "strict_scope": True if args.strict_scope else None,
              "verify": args.verify, "verify_s": args.verify_s}
    append(record)
    emit(record)


def cmd_outcome(args):
    decision, review, attempts = {}, {}, []
    for rec in read_ledger():
        if rec.get("id") == args.id and rec.get("event") == "decision":
            decision = rec
        elif rec.get("id") == args.id and rec.get("event") == "review":
            review = rec
        elif rec.get("id") == args.id and rec.get("event") == "attempt":
            attempts.append(rec)
    if not decision:
        warn("no decision with id %s in the ledger; writing the outcome alone" % args.id)
    # An outcome belongs to the policy that made its decision: copied from the
    # decision (absent on a pre-5.4 one), or the current policy when there is none.
    record = {k: v for k, v in decision.items() if k not in ("event", "ts", "declare")}
    if not decision:
        record["policy_version"] = POLICY_VERSION
    for key, value in review.items():
        if key in ("legacy_review", "review", "review_decided_by", "reviewer", "reviewer_model",
                   "reviewer_effort", "reviewer_role"):
            record[key] = value
        elif key.startswith(("jev_", "imajev_")):
            record["review_" + key] = value
    # Lane runs recorded by codex-lane.sh fill in what the caller left out.
    lane_seconds = [a["duration_s"] for a in attempts
                    if isinstance(a.get("duration_s"), (int, float)) and not isinstance(a.get("duration_s"), bool)]
    count = args.attempts if args.attempts is not None else (len(attempts) or 1)
    duration = args.duration if args.duration is not None else (sum(lane_seconds) if lane_seconds else None)
    verified = [a["verify"] for a in attempts if a.get("verify") in ("pass", "fail")]
    record.update(event="outcome", id=args.id, ts=now(), outcome=args.outcome,
                  attempts=count, duration_s=duration, note=args.note,
                  verify=verified[-1] if verified else None,
                  review_verdict=args.verdict, review_findings=args.findings)
    append(record)
    emit(record)


def cmd_config(_args):
    info = {k: os.environ[k] for k in sorted(os.environ) if k.startswith("FABLE_")}
    info["policy_version"] = POLICY_VERSION
    info["jev_mode_effective"] = jev_mode()
    info["imajev_mode_effective"] = imajev_mode()  # never probed here: shadow only, and a probe is a network call
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
    r.add_argument("--route", choices=("self",) + ROUTES,
                   help="the architect's explicit choice (still subject to the floor and luna_max eligibility)")
    r.add_argument("--state", default="-", help="state file, or - for stdin")
    v = sub.add_parser("review", help="decide a review from a review state on stdin")
    v.add_argument("--id", help="the route decision's id, to join them in the ledger")
    v.add_argument("--task", default=None)
    v.add_argument("--state", default="-")
    o = sub.add_parser("outcome", help="record how a routed task ended")
    o.add_argument("--id", required=True)
    o.add_argument("--outcome", required=True, choices=OUTCOMES)
    o.add_argument("--attempts", type=int, default=None, help="default: lane attempts recorded for the id")
    o.add_argument("--duration", type=float, default=None, help="default: their summed duration")
    o.add_argument("--note", default=None)
    o.add_argument("--verdict", default=None, choices=VERDICTS, help="the reviewer's verdict, if reviewed")
    o.add_argument("--findings", type=int, default=None, help="how many review findings survived")
    a = sub.add_parser("attempt", help="record one lane run (codex-lane.sh does this)")
    a.add_argument("--id", required=True)
    a.add_argument("--lane-status", required=True, choices=LANE_STATUSES)
    a.add_argument("--rc", type=int, default=None)
    a.add_argument("--duration", type=float, default=None)
    a.add_argument("--model", default=None)
    a.add_argument("--effort", default=None)
    a.add_argument("--touched", type=int, default=None)
    a.add_argument("--violations", type=int, default=None)
    a.add_argument("--reason", default=None)
    a.add_argument("--unrouted", action="store_true", help="the lane ran without a route id")
    a.add_argument("--strict-scope", action="store_true")
    a.add_argument("--verify", default=None, choices=("pass", "fail", "not_run"))
    a.add_argument("--verify-s", type=float, default=None)
    b = sub.add_parser("backfill", help="record a decision for a lane run without a route id (codex-lane.sh does this)")
    b.add_argument("--model", required=True)
    b.add_argument("--effort", required=True)
    b.add_argument("--file-count", type=int, required=True)
    b.add_argument("--objective", default=None)
    b.add_argument("--verification", action="store_true", help="the spec names a verification command")
    b.add_argument("--task", default=None)
    sub.add_parser("config", help="print the effective configuration")
    argv = sys.argv[1:] if argv is None else argv
    if "--route=claude_fable" in argv or any(
            x == "--route" and y == "claude_fable" for x, y in zip(argv, argv[1:])):
        # Retired in 5.4.0. Say where the work went instead of argparse's bare list.
        warn("route claude_fable was retired in 5.4.0: implementation that needs Claude is "
             "claude_opus_high; Fable is consulted (consult_first: fable-advisor), not routed to")
        return 2
    args = parser.parse_args(argv)
    try:
        if args.command in ("route", "review"):
            text = sys.stdin.read() if args.state == "-" else open(args.state).read()
            (cmd_route if args.command == "route" else cmd_review)(args, text)
        elif args.command == "outcome":
            cmd_outcome(args)
        elif args.command == "attempt":
            cmd_attempt(args)
        elif args.command == "backfill":
            cmd_backfill(args)
        else:
            cmd_config(args)
    except (StateError, OSError) as exc:
        warn(str(exc))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
