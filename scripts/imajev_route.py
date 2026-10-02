"""Imajev adapter for fable-route.py — shadow measurement only, never raises.

Imajev (https://github.com/mohit67890/imajev, open weights) serves TypeSafe
Jev's System One contract locally: POST /v1/systemone with
{"state", "questions"} and, per choice question, {"choice", "probabilities",
"confidence", "unknown_probability", "abstained"}. fable-route.py sends it the
exact question, state and options it sends Jev, and only ever logs the answer:
there is no active mode, so nothing here can change a route or a review.

The contract mirrors jev_route.classify(); the HTTP call is the standard
library's urllib, so no dependency is added. A loopback URL bypasses any
HTTP(S)_PROXY in the environment (a local server is never reached through a
proxy). The state-size cap is jev_route's, so both models see the same limit.

Every failure returns {"ok": False, "reason": <code>}; the caller logs it and
routing is untouched. Reasons: invalid_url, state_too_large, unavailable,
timeout, http_<status>, malformed, missing_answer, unknown_choice,
no_confidence, error.

    python3 scripts/imajev_route.py probe    # one trivial classification against FABLE_IMAJEV_URL
"""
from __future__ import annotations

import ipaddress
import json
import math
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "http://127.0.0.1:8765/v1/systemone"
STATE_MAX_BYTES = 2048      # jev_route.STATE_MAX_BYTES: the same cap for both models
RESPONSE_MAX_BYTES = 65536  # one choice answer is well under 1 KB


def _url():
    return (os.environ.get("FABLE_IMAJEV_URL") or DEFAULT_URL).strip()


def _loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def backend_name(url=None):
    host = urllib.parse.urlsplit(url or _url()).hostname or ""
    return "imajev-local" if _loopback(host) else "imajev-remote"


def _fail(reason, backend, started=None, **extra):
    result = {"ok": False, "reason": reason, "backend": backend}
    if started is not None:
        result["latency_ms"] = int((time.monotonic() - started) * 1000)
    result.update(extra)
    return result


def _unit(value):
    """A probability-like number in [0, 1], or None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    if -1e-9 <= value <= 1 + 1e-9:
        return min(1.0, max(0.0, float(value)))
    return None


def _post(url, body, timeout):
    request = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Accept": "application/json"})
    host = urllib.parse.urlsplit(url).hostname or ""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if _loopback(host) \
        else urllib.request.build_opener()
    with opener.open(request, timeout=timeout) as response:
        return response.read(RESPONSE_MAX_BYTES + 1)


def _is_timeout(exc):
    return isinstance(exc, (socket.timeout, TimeoutError)) or "timed out" in str(exc).lower()


def classify(question, state, options, timeout):
    """Return the normalised answer (see the module docstring) or a failure."""
    url = _url()
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return _fail("invalid_url", None)
    backend = backend_name(url)
    payload = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
    if len(payload.encode()) > STATE_MAX_BYTES:
        return _fail("state_too_large", backend)
    body = json.dumps({"state": state,
                       "questions": {"answer": {"type": "choice", "instructions": question,
                                                "criteria": dict(options)}}},
                      ensure_ascii=False, separators=(",", ":")).encode()
    started = time.monotonic()
    try:
        raw = _post(url, body, timeout)
    except urllib.error.HTTPError as exc:
        return _fail("http_%d" % exc.code, backend, started)
    except urllib.error.URLError as exc:
        return _fail("timeout" if _is_timeout(exc.reason) else "unavailable", backend, started)
    except (socket.timeout, TimeoutError):
        return _fail("timeout", backend, started)
    except OSError as exc:  # connection reset, server closed mid-response
        return _fail("timeout" if _is_timeout(exc) else "unavailable", backend, started)
    except Exception:  # http.client.IncompleteRead and anything else the transport raises
        return _fail("unavailable", backend, started)
    if len(raw) > RESPONSE_MAX_BYTES:
        return _fail("malformed", backend, started)
    try:
        document = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return _fail("malformed", backend, started)
    if not isinstance(document, dict):
        return _fail("malformed", backend, started)
    model = document.get("model")
    model = model[:60] if isinstance(model, str) else None
    answers = document.get("answers")
    answer = answers.get("answer") if isinstance(answers, dict) else None
    if not isinstance(answer, dict):
        return _fail("missing_answer", backend, started, model=model)
    choice = answer.get("choice")
    if not isinstance(choice, str):
        return _fail("malformed", backend, started, model=model)
    confidence = _unit(answer.get("confidence"))
    if choice not in options:
        failure = _fail("unknown_choice", backend, started, model=model, choice=choice[:40])
        if confidence is not None:
            failure["confidence"] = round(confidence, 4)
        return failure
    if answer.get("confidence") is None:
        return _fail("no_confidence", backend, started, model=model)
    if confidence is None:
        return _fail("malformed", backend, started, model=model)
    latency = int((time.monotonic() - started) * 1000)
    # Only the offered options: the map stays as small as the option list.
    probabilities = answer.get("probabilities")
    probabilities = {k: round(p, 4) for k, p in ((k, _unit(probabilities.get(k))) for k in options)
                     if p is not None} if isinstance(probabilities, dict) else {}
    unknown = _unit(answer.get("unknown_probability"))
    abstained = answer.get("abstained")
    usage = document.get("usage")
    server_ms = usage.get("total_ms") if isinstance(usage, dict) else None
    calibration = answer.get("calibration_version")
    return {"ok": True, "choice": choice, "confidence": confidence, "backend": backend,
            "model": model, "latency_ms": latency,
            "server_ms": round(float(server_ms), 1) if isinstance(server_ms, (int, float))
            and not isinstance(server_ms, bool) and math.isfinite(server_ms) else None,
            "probabilities": probabilities,
            "unknown_probability": None if unknown is None else round(unknown, 4),
            "abstained": abstained if isinstance(abstained, bool) else None,
            "calibration_version": calibration[:60] if isinstance(calibration, str) else None}


if __name__ == "__main__":
    if sys.argv[1:] != ["probe"]:
        print(__doc__.strip().splitlines()[-1].strip())
        raise SystemExit(2)
    result = classify("Is this a routine one-line change?",
                      {"objective": "Fix a typo in a README heading", "file_count": 1},
                      {"yes": "A routine one-line change", "no": "Anything larger"},
                      float(os.environ.get("FABLE_IMAJEV_TIMEOUT", "8")))
    print(json.dumps(result))
    raise SystemExit(0 if result["ok"] else 1)
