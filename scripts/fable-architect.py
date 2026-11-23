#!/usr/bin/env python3
"""Who is the session's architect? The primary once it acknowledges, else the fallback.

    fable-architect.py claim    a task starts: open the acknowledgement window
    fable-architect.py wait     block (no tokens) until the primary acks or the window closes
    fable-architect.py status   one JSON line: architect, model, effort, state, reason
    fable-architect.py ack      the primary: I have the task (first action of its turn)
    fable-architect.py beat     the primary: still alive (before each lane and major step)
    fable-architect.py done     the primary: the task is finished, the role is released

Only inside Orca (an ORCA_* session variable is set) and with
FABLE_ARCHITECT_MODE=orca. Anywhere else the answer is `session`: the current
session keeps the architect role and nothing changes.

States: no ack within FABLE_ARCHITECT_ACK_TIMEOUT of the claim -> fallback
(`no_ack`); acked and beating -> primary (`working`); acked but silent for
FABLE_ARCHITECT_WORK_TIMEOUT -> fallback (`lost`, tell the person); `done` ->
released. While the window is open the state is `pending` and `wait` blocks.

This script never starts, calls or wraps the primary model. The primary runs as
an interactive session a person drives and writes its own state. The plugin
cannot switch a running session's model: `status` names the model that should
hold the role. Standard library only.
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config():
    pattern = re.compile(r'^:\s*"\$\{(\w+):=(.*)\}"')
    with open(os.path.join(HERE, "fable-config.sh")) as handle:
        for line in handle:
            match = pattern.match(line.strip())
            if match and not os.environ.get(match.group(1)):
                os.environ[match.group(1)] = os.path.expandvars(match.group(2))


def in_orca():
    return bool(os.environ.get("ORCA_AGENT_SESSION_ID") or os.environ.get("ORCA_APP_VERSION"))


def read_state():
    try:
        with open(os.environ["FABLE_ARCHITECT_STATE"]) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def write_state(state):
    path = os.environ["FABLE_ARCHITECT_STATE"]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d" % (path, os.getpid())
    with open(tmp, "w") as handle:
        json.dump(state, handle)
    os.replace(tmp, path)


def role(prefix, name, state, reason):
    return {"architect": name, "model": os.environ["FABLE_ARCHITECT_%s_MODEL" % prefix],
            "effort": os.environ["FABLE_ARCHITECT_%s_EFFORT" % prefix], "state": state, "reason": reason}


def status():
    if os.environ["FABLE_ARCHITECT_MODE"] != "orca":
        return {"architect": "session", "reason": "mode_off"}
    if not in_orca():
        return {"architect": "session", "reason": "not_orca"}
    st, now = read_state(), time.time()
    if "claimed_at" not in st:
        return role("FALLBACK", "fallback", "no_claim", "no_claim")
    if "done_at" in st:
        return {"architect": "released", "state": "done", "reason": "done"}
    if "acked_at" not in st:
        if now - st["claimed_at"] <= float(os.environ["FABLE_ARCHITECT_ACK_TIMEOUT"]):
            return {"architect": "pending", "state": "pending", "reason": "awaiting_ack"}
        return role("FALLBACK", "fallback", "no_ack", "no_ack")
    if now - st.get("beat_at", st["acked_at"]) > float(os.environ["FABLE_ARCHITECT_WORK_TIMEOUT"]):
        return role("FALLBACK", "fallback", "lost", "lost")
    return role("PRIMARY", "primary", "working", "working")


def mark(**fields):
    st = read_state()
    st.update(fields)
    write_state(st)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    load_config()
    now = time.time()
    if command == "claim":
        if status().get("state") != "working":   # a primary already at work keeps the role
            write_state({"claimed_at": now})
    elif command == "ack":
        st = read_state()
        st.pop("done_at", None)
        st.setdefault("claimed_at", now)
        st.update(acked_at=now, beat_at=now)
        write_state(st)
    elif command == "beat":
        mark(beat_at=now)
    elif command == "done":
        mark(done_at=now)
    elif command in ("status", "wait"):
        if command == "wait":
            while status()["architect"] == "pending":
                time.sleep(1)
        print(json.dumps(status(), separators=(",", ":")))
        return
    else:
        sys.exit(__doc__)
    print("%s ok" % command)   # no output looks like a failure to a model; say it worked


main()
