---
name: orchestration
description: How this session delegates implementation — to the codex lane by default, Claude-side only for a named reason, to a Fable consult when the approach itself is stuck — and how a deliverable is accepted and reviewed. A router script makes every routing and review decision and logs it; this skill covers the judgment around it. USE WHEN deciding whether or where to delegate, writing a spec for a worker, running or applying a codex lane, handling a lane failure, or deciding whether a deliverable needs review before you report done.
---

# Orchestration

You are the architect. Implementation goes to the codex lane by default: Claude
quota is the scarce resource your reasoning, review and integration consume,
while the codex side has far more headroom. So the question is never "is this
worth delegating" but "is there a reason this cannot go to codex".

Write replies to the user in Japanese. Everything else stays in English: specs,
router state (including `objective`), prompts to subagents, code, comments and
commit messages. Route ids, flags, commands and paths stay as written, and print
the router's `declare` line verbatim.

## Work stays Claude-side for one of five reasons

1. **Context-bound** — writing the spec would cost more than doing it.
2. **Below the spawn floor** — the round trip costs more than the work, and you can say by how much.
3. **Judgment-dominated** — the outcome turns on judgment a spec cannot carry, or codex has failed the task twice. That is the senior worker, not Fable.
4. **Review.**
5. **Claude-only tooling** — licenses running the tool, not the implementation. Hand the result back to the lane.

## Roles

| Role | Runs as |
|---|---|
| Default worker (`luna_low` / `luna_high` / `luna_max`) | `codex-implementer` → codex |
| Broad worker (`sol_high`) — several interacting components, interface-heavy work, wide-search debugging | `codex-implementer` → codex |
| Senior worker (`claude_opus_high`) | `implementer`, with the router's `model` on the spawn |
| Senior reviewer (`opus_review`) | `opus-reviewer`, read-only |
| Frontier advisor (`consult_first`, `fable_review`) | `fable-advisor`, read-only; reframes the problem, never implements |

Models and efforts behind each role are configuration (`scripts/fable-config.sh`
and the agents' `effort:` pins). Pass the router's `model` (or `reviewer_model`)
as the spawn's `model`; it outranks the agent file.

## Route with the router

Describe the task as facts, never code or diffs:

```bash
echo '{"objective":"Add retry handling to payment API","file_count":4,"verification_available":true}' \
  | "${CLAUDE_PLUGIN_ROOT}/scripts/fable-route.py" route
```

Fields (booleans default false): `mechanical`, `multi_component`,
`interface_change`, `api_change`, `schema_change`, `data_migration`,
`security_sensitive`, `concurrency_sensitive`, `irreversible`, `context_bound`,
`below_spawn_floor`, `judgment_dominated`, `claude_only_tool`,
`architectural_deadlock`, `opus_failed`, `strict_scope`,
`verification_available`; counts `file_count`, `prior_failures`.

It owns every rule — risk floors, escalation after failures, eligibility, the
optional Jev classifier (`FABLE_JEV_MODE=off|shadow|active`) — and returns one
JSON line. Print its `declare` line before you act on it. Pass `lane_args` to
the lane unchanged. `consult_first: fable-advisor` means consult Fable before
anyone implements; a replacement spec it returns is a new task (its failures
start at zero), a patched spec keeps `prior_failures`. `--route <id>` records a choice of your own; the router
refuses one that breaks a floor. Two choices are yours to make:

- `--route sol_high` when the work is broad rather than deep.
- `--route luna_max` on a retry the router marks `luna_max_eligible`, when the
  failure was reasoning on a clear spec, not a missing requirement.

## Spec

Objective · Files · Interfaces · Constraints · Verification (an exact command
and its expected result). Files is the **expected scope**: a worker may change
an adjacent file the objective directly needs and must name it and say why.
Under `strict_scope` (the router sets it for security, migration and
irreversible work) Files is an allowlist and nothing outside it lands.

## Running a codex lane

Spawn `codex-implementer` with the spec plus `LANE_ARGS:` (from the router) and
`VERIFY:` (the acceptance command) lines — or run the lane yourself:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex-lane.sh" --spec <file> --files "<f1,f2>" <lane_args> --verify "<cmd>"
```

Every lane runs in its own disposable worktree, so parallel lanes are safe. The
`LANE REPORT` prints the apply command; apply lands only what the scope allows,
and refuses failed acceptance and anything the main tree changed since the lane
started. Undo a lane with `git worktree remove`, never a checkout on the main
tree.

## When a lane fails

| Result | Do |
|---|---|
| Codex unavailable (exit 3): quota, auth, network | Stop and report, with the reset time if given. Do not fail over to Claude silently — that spends the scarce quota exactly when the abundant one is gone. The user decides: wait, or authorise `implementer` with `model: sonnet`. |
| Timeout (exit 4) | Resume the same lane against the same worktree with a `RESUME` block from the reported handoff. Do not change lanes. |
| `need_tool` | Run that one operation yourself and hand the result back. The lane keeps the task. |
| Acceptance failed (exit 6) or empty diff (exit 1) | A failed attempt. Re-route with `prior_failures` raised; the router escalates. |

Size each spec to finish inside the ~10 minute wall clock; split larger work at a
point where the first half is independently verifiable.

## Acceptance and review

You own acceptance. On a codex lane the acceptance command already ran in the
harness — read its result, do not repeat it. Run it yourself when the worker
was Claude-side, or when other changes landed in the main tree after the lane
started.

Then ask the router: `fable-route.py review --id <route id>` with the review
state (`file_count`, `lines_changed`, `mechanical`, the risk flags,
`wide_blast_radius`, `lane_disagreement`, `opus_review_inconclusive`,
`architectural_deadlock`, `silence_gap`, `attempts`; `verification_passed`
comes from the lane when omitted). It returns `none`, `self_review`,
`opus_review` or `fable_review`. High risk is the senior reviewer's job; Fable
is for when the senior review itself is contested.

- **Silence gap.** Before any review, work out what the change *should* have
  touched — callers, parallel implementations, adjacent config — minus what it
  did. Give the reviewer those paths. A diff shows what changed, never what
  should have and didn't.
- **Fresh context.** Give the reviewer the goal, constraints, diff,
  verification result and silence gap — not the implementer's account of its
  work. Send those claims in a second pass only when a finding contradicts one,
  a finding's withdrawal needs arguing, or the stakes justify another look.
- `ESCALATE` from `opus-reviewer` → re-run the gate with `opus_review_inconclusive`.

## Ledger

The router and the lane log every decision, lane run and acceptance result by
themselves. Close each routed task with what only you know:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/fable-route.py" outcome --id <id> \
  --outcome success|retry|failover|blocked|unavailable|timeout [--verdict ship|fix_first|rethink|escalate --findings N]
```

`routing-report.py` summarises it per policy version.
