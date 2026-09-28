#!/usr/bin/env python3
"""How much instruction text each execution path puts in front of a model.

    prompt-budget.py [--ref GIT_REF] [--json]

Measures the plugin's prompt surfaces — the orchestration skill, the agent
files, and the preamble codex-lane.sh prepends to every codex spec — and sums
them along the paths a task actually takes. With --ref it measures that git
revision too and prints the delta, so a prompt change can be judged by how
much active context it removes from the normal path, not by bytes deleted.

Contexts are kept apart because they are paid for differently:

    always_on     skill + agent descriptions: in the main session every turn
    orchestrator  the skill body, once the skill has loaded
    subagent      the spawned agent's own system prompt (its own context)
    codex         what codex receives besides the spec (the abundant side)

Tokens are estimated as ceil(chars / 4). The estimate is crude but identical
for both revisions, which is all a before/after comparison needs.
Standard library only.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = "skills/orchestration/SKILL.md"
AGENTS = ("codex-implementer", "implementer", "opus-reviewer", "fable-advisor")
PREAMBLE = "scripts/lane-preamble.md"

# Each path: (label, orchestrator surfaces, subagent surfaces, codex surfaces).
PATHS = (
    ("implement_codex", "normal task: routed to the codex lane", ["skill"], ["codex-implementer"], ["preamble"]),
    ("implement_claude", "senior worker: claude_opus_high", ["skill"], ["implementer"], []),
    ("review_opus", "adds an opus_review", [], ["opus-reviewer"], []),
    ("consult_fable", "adds a Fable consult or fable_review", [], ["fable-advisor"], []),
)


def read(path, ref):
    if ref is None:
        try:
            with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
                return handle.read()
        except OSError:
            return ""
    try:
        return subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (ref, path)], check=True,
                              capture_output=True, text=True).stdout
    except subprocess.CalledProcessError:
        return ""


def split(text):
    """(description, body) of a file with YAML frontmatter; ('', text) without."""
    if not text.startswith("---\n"):
        return "", text
    end = text.find("\n---", 4)
    if end < 0:
        return "", text
    front, body = text[4:end], text[end + 4:].lstrip("\n")
    desc = next((line[len("description:"):].strip() for line in front.splitlines()
                 if line.startswith("description:")), "")
    return desc, body


def size(text):
    return {"chars": len(text), "words": len(text.split()), "tokens": math.ceil(len(text) / 4)}


def measure(ref):
    desc, body = split(read(SKILL, ref))
    surfaces = {"skill": {"description": size(desc), "body": size(body)}}
    for name in AGENTS:
        adesc, abody = split(read("agents/%s.md" % name, ref))
        surfaces[name] = {"description": size(adesc), "body": size(abody)}
    surfaces["preamble"] = {"description": size(""), "body": size(read(PREAMBLE, ref))}

    always_on = sum(s["description"]["tokens"] for s in surfaces.values())
    paths = {}
    for key, label, main, sub, codex in PATHS:
        tok = {"orchestrator": sum(surfaces[s]["body"]["tokens"] for s in main),
               "subagent": sum(surfaces[s]["body"]["tokens"] for s in sub),
               "codex": sum(surfaces[s]["body"]["tokens"] for s in codex)}
        tok["claude_side"] = tok["orchestrator"] + tok["subagent"]
        paths[key] = dict(label=label, **tok)
    normal = paths["implement_codex"]
    return {"ref": ref or "working tree", "surfaces": surfaces,
            "always_on_tokens": always_on, "paths": paths,
            # The number this tool exists for: Claude-side instruction tokens a
            # normal codex-routed task carries (always-on + skill + supervisor).
            "normal_task_claude_tokens": always_on + normal["claude_side"]}


def render(now, before):
    rows = []

    def line(label, value, old):
        delta = "" if old is None else "  (%+d, %s)" % (value - old, "%.0f%%" % (100.0 * (value - old) / old) if old else "new")
        rows.append("  %-38s %6d%s" % (label, value, delta))

    rows.append("est. tokens (chars/4) — %s%s" % (now["ref"], "" if before is None else " vs " + before["ref"]))
    rows.append("surfaces:")
    for name, parts in now["surfaces"].items():
        for part in ("description", "body"):
            old = None if before is None else before["surfaces"][name][part]["tokens"]
            if parts[part]["tokens"] or old:
                line("%s.%s" % (name, part), parts[part]["tokens"], old)
    rows.append("paths (claude_side = orchestrator + subagent):")
    line("always_on (every turn)", now["always_on_tokens"], None if before is None else before["always_on_tokens"])
    for key, path in now["paths"].items():
        for ctx in ("orchestrator", "subagent", "claude_side", "codex"):
            old = None if before is None else before["paths"][key][ctx]
            if path[ctx] or old:
                line("%s.%s" % (key, ctx), path[ctx], old)
    line("normal_task_claude_tokens", now["normal_task_claude_tokens"],
         None if before is None else before["normal_task_claude_tokens"])
    return "\n".join(rows)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="prompt-budget")
    parser.add_argument("--ref", help="git revision to compare against, e.g. HEAD~1 or a tag")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    now = measure(None)
    before = measure(args.ref) if args.ref else None
    if args.json:
        print(json.dumps({"now": now, "before": before}, indent=2))
    else:
        print(render(now, before))
    return 0


if __name__ == "__main__":
    sys.exit(main())
