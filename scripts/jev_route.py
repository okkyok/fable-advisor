"""Jev adapter for fable-route.py — one typed choice, never raises, never guesses.

Jev (TypeSafe's System One model) is used here strictly as a classifier: it
picks one key from a fixed option map and reports its confidence. It writes no
text and sees no code — only the whitelisted decision state fable-route.py
builds.

Backends, both optional and both existing OSS CLIs:

  semdecide  https://github.com/sharziki/semdecide  `semdecide choose ... --json`
             (response validation, per-attempt timeout, exit 4 on provider failure)
  jev-cli    https://pypi.org/project/jev-cli/        `jev choice ... --json-state`
             (exit 3 auth, 4 network/rate limit, 1 invalid response)

FABLE_JEV_BACKEND=auto prefers semdecide, then jev-cli. Credentials are each
tool's own (TYPESAFE_API_KEY, or the jev-cli credential store); this module never
reads or logs them.

Every failure returns {"ok": False, "reason": <code>}; the caller then keeps the
deterministic route. Reasons: executable_missing, invalid_backend, timeout,
auth, network, provider_error, malformed, unknown_choice, no_confidence,
state_too_large, error.

    python3 scripts/jev_route.py probe    # one trivial live classification
"""
from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
import time

BACKENDS = {"semdecide": "semdecide", "jev-cli": "jev"}  # backend -> executable
STATE_MAX_BYTES = 2048  # a routing state is ~15 small fields; anything larger is a leak


def _resolve():
    preference = os.environ.get("FABLE_JEV_BACKEND", "auto").strip().lower()
    order = {"auto": ["semdecide", "jev-cli"], "semdecide": ["semdecide"],
             "jev-cli": ["jev-cli"]}.get(preference)
    if order is None:
        return None, None, "invalid_backend"
    for name in order:
        exe = shutil.which(BACKENDS[name])
        if exe:
            return name, exe, None
    return None, None, "executable_missing"


def describe_backend():
    name, exe, reason = _resolve()
    return "%s (%s)" % (name, exe) if name else reason


def _argv(name, exe, question, options, timeout):
    pairs = []
    for key, description in options.items():
        pairs += ["--option", "%s=%s" % (key, description)]
    if name == "semdecide":
        # --min-confidence 0: the confidence gate belongs to fable-route, which
        # also needs the choice in shadow mode. --retries 0: the budget is ours.
        return [exe, "choose", question, "--json", "--retries", "0",
                "--timeout", str(max(1.0, timeout - 1.0)), "--min-confidence", "0"] + pairs
    return [exe, "choice", "--question", question, "--json-state"] + pairs


def _fail(reason, name=None, started=None):
    result = {"ok": False, "reason": reason, "backend": name}
    if started is not None:
        result["latency_ms"] = int((time.monotonic() - started) * 1000)
    return result


EXIT_REASONS = {
    "semdecide": {2: "error", 4: "provider_error"},
    "jev-cli": {1: "malformed", 2: "error", 3: "auth", 4: "network"},
}


def classify(question, state, options, timeout):
    """Return {"ok", "choice", "confidence", "backend", "latency_ms"} or a failure."""
    name, exe, reason = _resolve()
    if reason:
        return _fail(reason)
    payload = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
    if len(payload.encode()) > STATE_MAX_BYTES:
        return _fail("state_too_large", name)
    started = time.monotonic()
    try:
        proc = subprocess.run(_argv(name, exe, question, options, timeout), input=payload,
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return _fail("timeout", name, started)
    except OSError:
        return _fail("executable_missing", name, started)
    if proc.returncode != 0:
        return _fail(EXIT_REASONS[name].get(proc.returncode, "error"), name, started)
    try:
        document = json.loads(proc.stdout)
        answer = document if name == "semdecide" else document["answers"]["answer"]
        if not isinstance(answer, dict):
            raise TypeError
    except (ValueError, KeyError, TypeError):
        return _fail("malformed", name, started)
    choice, confidence = answer.get("choice"), answer.get("confidence")
    if not isinstance(choice, str):
        return _fail("malformed", name, started)
    if choice not in options:
        failure = _fail("unknown_choice", name, started)
        failure["choice"] = choice[:40]
        if isinstance(confidence, (int, float)) and not isinstance(confidence, bool) \
                and math.isfinite(confidence):
            failure["confidence"] = round(float(confidence), 4)
        return failure
    if confidence is None:
        return _fail("no_confidence", name, started)
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) \
            or not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
        return _fail("malformed", name, started)
    return {"ok": True, "choice": choice, "confidence": float(confidence), "backend": name,
            "latency_ms": int((time.monotonic() - started) * 1000)}


if __name__ == "__main__":
    if sys.argv[1:] != ["probe"]:
        print(__doc__.strip().splitlines()[-1].strip())
        raise SystemExit(2)
    result = classify("Is this a routine one-line change?",
                      {"objective": "Fix a typo in a README heading", "file_count": 1},
                      {"yes": "A routine one-line change", "no": "Anything larger"},
                      float(os.environ.get("FABLE_JEV_TIMEOUT", "8")))
    print(json.dumps(result))
    raise SystemExit(0 if result["ok"] else 1)
