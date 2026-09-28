---
name: orchestration
description: How this session routes implementation to the codex lane by default (GPT-6 Luna at high; Luna at max for a narrow retry; Sol for broad integration-heavy work), when work instead goes Claude-side (Opus 5.5 at high after two failures or for judgment a spec cannot carry), when Fable is consulted to reframe the problem, and when a deliverable earns an Opus or Fable review — with the obvious cases decided by rule, the ambiguous middle optionally classified by Jev behind a confidence gate, and every decision in a versioned ledger. USE WHEN deciding whether a task can go to codex, choosing a route, model or reasoning effort, writing a spec for a subagent, running a lane in its isolated worktree, handling a codex quota failure, wall-clock timeout or repeated failure, or deciding whether a deliverable needs an independent review before you report done.
---

# Orchestration

**Implementation goes to the codex lane by default.** The two subscriptions are
not interchangeable: Claude quota is the scarce resource and is what your own
reasoning, review and integration consume, while the ChatGPT side runs GPT-6
Luna and Sol with far more headroom. Every routine implementation you type yourself
spends the scarce budget on the abundant task.

So the question is never "is this worth delegating" — it is "is there a reason
this one cannot go to codex".

## When work stays Claude-side

Five reasons. Declare the routing decision before you act on it — the condition
that decided it and the lane it lands in, one line, before the spawn. The router
below prints this line as `declare`:

    route: luna_high (legacy) -> codex-implementer gpt-6-luna high
    route: self (below_spawn_floor) -> self

1. **Context-bound.** The task depends on conversation state that a
   self-contained spec would cost more to write down than to act on.
2. **Below the spawn floor.** A round trip costs real seconds and tokens before
   any work happens. Applies when you can name the number, not when it merely
   feels faster.
3. **Judgment-dominated.** The outcome turns on judgment a spec cannot carry, or
   the codex lane has already failed this task twice. That is Opus 5.5
   (`claude_opus_high`) — not Fable, and not merely "the code is hard".
4. **Review.** `opus-reviewer` (or, exceptionally, `fable-advisor`) reads the
   deliverable. See *Review*.
5. **Claude-only tooling** — and it licenses the tool operation, not the
   implementation. Run the tool, hand the result back, let the lane keep the code.

None of these apply? It goes to codex.

## Choosing the route

Who does what:

| | Role |
|---|---|
| Claude (you) | Architect: integration and the judgment that is worth Claude quota. |
| GPT-6 Luna | Default implementation (`luna_high`); `luna_low` for mechanical one-file work; `luna_max` to think harder on a narrow task that failed once. |
| GPT-6 Sol | Broad, integration-heavy implementation (`sol_high`): several interacting components, interface-heavy work, wide-search debugging. |
| Claude Opus 5.5 | Implementation after two codex failures or when judgment dominates (`claude_opus_high`); routine senior review (`opus_review`). |
| Fable | Frontier consult: reframes the problem when attempts keep failing or the architecture is deadlocked (`consult_first`); exceptional review (`fable_review`). Never an implementation route. |
| Jev | Optional control-plane classifier for the ambiguous middle. Never writes, reviews or designs. |

Claude quota is still the scarce side. Opus is an escalation for repeated
failure, judgment or genuine ambiguity — "a bit harder than usual" is
`luna_high`, and "broad" is `sol_high`.

Describe the task as a decision state — facts, not prose, never code or diffs —
and let the router decide:

```bash
echo '{"objective":"Add retry handling to payment API","file_count":4,"verification_available":true}' \
  | "${CLAUDE_PLUGIN_ROOT}/scripts/fable-route.py" route --task "payment retry"
```

Flags (all default false): `mechanical`, `multi_component`, `interface_change`,
`api_change`, `schema_change`, `data_migration`, `security_sensitive`,
`concurrency_sensitive`, `irreversible`, `context_bound`, `below_spawn_floor`,
`judgment_dominated`, `claude_only_tool`, `architectural_deadlock` (the approach
itself is stuck between options), `opus_failed` (a `claude_opus_high` attempt
failed), and `verification_available` — set it when the spec has a runnable
verification command; counts: `file_count`, `prior_failures`.

It prints one JSON line: `actual_route`, `lane`, `model`, `effort`, `declare`,
and an `id` for the ledger. Unknown keys are dropped. Pass `--route sol_high`
(or any route) when you have decided yourself.

**Rules decide the obvious cases, in order, and Jev never sees them:**
context-bound or below the spawn floor → `self` · two failed attempts,
`architectural_deadlock`, `opus_failed` or judgment-dominated →
`claude_opus_high` · one file, mechanical, verifiable, no risk flag, no prior
failure → `luna_low`. Everything else is the ambiguous middle, whose
deterministic answer is `luna_high` — including the first retry.

| Route | Runs as | For |
|---|---|---|
| `luna_low` | codex `gpt-6-luna` `low` | Mechanical, one file, runnable verification, no risk flag, no failure. |
| `luna_high` | codex `gpt-6-luna` `high` | Ordinary implementation — the default, first attempt and first retry. |
| `luna_max` | codex `gpt-6-luna` `max` | A narrow retry: one prior failure, runnable verification, ≤ 3 files, no multi-component or interface change, no risk flag. Never a first attempt. |
| `sol_high` | codex `gpt-6-sol` `high` | Breadth: several interacting components, integration, interface-heavy work, wide-search debugging. |
| `claude_opus_high` | `implementer`, `model: opus` (effort pinned `high`) | Two failures, judgment a spec cannot carry, or the implementation after a Fable reframe of a stuck task. |

`luna_max` and `sol_high` are not a ladder: narrow-but-deep → `luna_max`,
broad → `sol_high`. `luna_max` runs under the same ~570 s wall clock as every
lane and takes much longer than `high`, which is why it is gated to narrow work.
The router marks an eligible retry `luna_max_eligible: true`; choose it with
`--route luna_max` when the failure was reasoning on a clear spec, not a missing
requirement. An ineligible `--route luna_max` is refused (`override_rejected:
luna_max_ineligible`).

**Risk floor.** A security, migration, schema, public-API (`api_change`),
concurrency or irreversible flag, a prior failure, no runnable verification, an
interface change, several components, or an unknown `file_count` puts the floor
at `luna_high`: nothing — not Jev, not an override — routes such a task to
`luna_low`. Two failures pin it at `claude_opus_high`, `--route self` included.

**Fable consult.** Three failures, `architectural_deadlock`, `opus_failed`, or
an expensive-to-reverse flag (schema, API, migration, irreversible) return
`consult_first: fable-advisor` with a `consult_reason`. Consult before anyone
implements. Fable questions the approach and hands back either "keep it, but do
X differently" or a replacement spec. A replacement spec is a new task: route it
as a new decision (failures of the discarded approach do not carry over); a
patched spec keeps its `prior_failures`. Fable does not implement.

**Jev** (`FABLE_JEV_MODE`, default `shadow`): `off` never touches Jev; `shadow`
asks Jev about the middle and logs its answer without using it; `active` uses
Jev's answer only when its confidence is at least `FABLE_JEV_MIN_CONFIDENCE`
(0.80), it respects the floor, and the route is eligible — any failure, timeout
or doubt falls back to the deterministic route and is logged as
`jev_status: fallback`. Jev's options depend on the state: a first attempt is
offered `luna_low` (when the floor allows), `luna_high`, `sol_high`; after one
failure `luna_high`, `sol_high`, `claude_opus_high`, and `luna_max` when
eligible. Two failures never reach Jev, and Fable is never an option.

Run the lane with exactly what the router returned, and its `id` — the lane then
records every run (status, duration, model, effort, scope violations) in the
ledger by itself:

```bash
scripts/codex-lane.sh --spec <specfile> --files "<f1,...>" --model <model> --effort <effort> --route-id <id>
```

Handing the task to `codex-implementer`? Put `MODEL:`, `EFFORT:` and `ROUTE_ID:`
lines next to the spec.

## Every codex lane runs in its own worktree

Not a preference — the mechanism that prevents the one failure that costs real
work. `codex exec` runs outside Claude Code's PreToolUse hooks, so nothing can
police what it writes. Scoped at a repository root it will occasionally edit
files its spec never listed, and the natural cleanup for that —
`git checkout -- <path>` on the shared tree — destroys whatever *other*
uncommitted work happened to live in those paths.

`scripts/codex-lane.sh` removes that chain: the lane gets a disposable worktree
seeded with the current tree state, so it cannot reach the main tree or another
lane's tree; anything it writes outside its Files is reported and left behind;
and undoing a lane is `git worktree remove`, never a checkout. Parallel lanes are
therefore safe by construction — run as many as the work splits into.

```bash
scripts/codex-lane.sh --spec <specfile> --files "<f1,f2,...>" --model gpt-6-luna --effort high
# then, after reading its LANE REPORT:
scripts/codex-lane-apply.sh --worktree <wt> --repo <repo> --files "<f1,f2,...>" --remove
```

Apply only the paths in **Files**. A `SCOPE VIOLATIONS` list is a signal the spec
was under-specified — fix the spec, not the tree.

## The lanes

| Lane | Model | Use for |
|---|---|---|
| `codex-implementer` | GPT-6 Luna (default) or Sol via `codex exec`, model and effort passed by you | **The default.** All codex routes (`luna_low`, `luna_high`, `luna_max`, `sol_high`). Runs in its own worktree. |
| `implementer` | per spawn: `haiku`, `sonnet`, `opus` (effort pinned `high`) | Claude-side implementation. `opus` is `claude_opus_high` (reason 3); `sonnet` is the codex quota-failover target, only when the user authorises it; `haiku` for bulk mechanical edits worth removing from your context. |
| `opus-reviewer` | Opus 5.5, effort `high` | `opus_review`: the routine independent senior review. Advises only — no write tools. |
| `fable-advisor` | Fable 5 | `consult_first` reframes and `fable_review`, the exceptional review. Advises only — no write tools. |

Set the model on the spawn itself; it outranks the agent file's frontmatter.
`opus` is Claude Code's alias for the latest Opus (Opus 5.5). One implementer
file, several depths — do not add per-model implementer files.

## Writing a spec

Five parts. Anything you leave out, the lane will invent.

1. **Objective** — what must be true when this is done.
2. **Files** — every path it may touch. It touches nothing else.
3. **Interfaces** — signatures, types, and call sites it must match.
4. **Constraints** — what it must not change, plus the boilerplate below.
5. **Verification** — the exact command that proves the objective, and the
   expected result. Not "run the tests" — the command.

Every codex-lane spec carries these two paragraphs verbatim. The first prevents
a lane from re-delegating and timing out with nothing to show. The second exists
because a lane once ran `git checkout HEAD` and destroyed another lane's
uncommitted work.

> Do not re-delegate to a subagent. This session implements the work directly.

> The working tree may contain another lane's in-progress uncommitted work. It is
> not yours; do not tidy it. Never run a git command that discards uncommitted
> work — `checkout`, `restore` (except bare `--staged`), `reset --hard|--merge|--keep`,
> `clean -f|-d|-x`, `stash`, `switch -f`, `rm -f`. To undo your own edit, write
> back the content you read before editing. If you believe the tree genuinely
> needs a reset, do not do it — report `STATUS: blocked` and let the caller
> decide. Do not touch files not listed in Files.

## What a lane returns

`STATUS` (success | blocked | need_tool) · `OBJECTIVE` restated · `CHANGES` by
file · `VERIFIED` with the command and its actual output · `GAPS` — anything it
could not do or could not check. A lane that reports success without pasting real
command output has not verified anything; treat it as `blocked`.

A lane that finishes with an empty diff has failed. Re-issue it; do not accept it.

## Failure handling

| What happened | What to do |
|---|---|
| **Codex quota exhausted** (lane exit `3`) | **Stop and report the reset time. Do not silently fail over to Claude.** Failing over spends the scarce subscription at the exact moment the abundant one is unavailable — over five weeks this pattern moved 47 tasks and ~5.8 hours onto the Claude side, none of them because the task needed Claude. Tell the user when codex returns and let them choose: wait, or authorise `implementer` with `model: sonnet`. |
| Codex unavailable for a non-quota reason (auth, broken install, no network to the API — lane exit `3`) | Report it with the probe output. This is a fix, not a reroute — a retry will fail the same way. |
| Codex ran out of wall clock with work in progress | Do **not** move lanes. Respawn the same lane against **the same worktree** with a `RESUME` block naming what landed and what remains. |
| Codex cannot reach a tool or a verification target | Run that one operation yourself, hand the result back, and let the lane keep the implementation. A capability gap is not a change of owner. |
| `SCOPE VIOLATIONS` in the lane report | The spec was under-specified. Apply only the allowed paths, widen **Files** if the extra paths were genuinely required, and re-issue. Never reconcile it with a checkout on the main tree. |
| A lane failed once (not quota, not a tool gap) | Re-route with `"prior_failures": 1`. The floor rises to `luna_high`, so a failed `luna_low` retries with more reasoning. If the task is narrow and the spec was right, the router marks it `luna_max_eligible` — `--route luna_max` thinks harder on the same scope; if it was breadth, `sol_high`. |
| Same task failed twice | Stop retrying on codex. Reason 3 now applies: the router returns `claude_opus_high` (`implementer`, `model: opus`). |
| Failed three times, or Opus failed, or the design is deadlocked | The router adds `consult_first: fable-advisor`. Consult Fable about the approach before any further attempt, then route what comes back. |

**Wall clock.** A lane has a bounded budget and cannot ask for more mid-run. Size
the spec to finish inside it. If a task plausibly exceeds it, split it at a point
where the first half is independently verifiable.

**Preflight.** Before routing to codex, confirm the CLI actually responds —
`codex exec` with a trivial prompt and a timeout. `codex --version` and
`codex --help` are known to hang on some builds, so a hang there means nothing;
only treat codex as unavailable if `codex exec` itself fails.

## Review

Reviews are worth their cost on risky deliverables and are waste on small ones.
Match the review to the blast radius.

| Deliverable | Review |
|---|---|
| One file, mechanical, verified by a passing command | `none`. Your own verification is the review. |
| Ordinary feature or fix | `self_review`: your own verification, plus a re-read of the diff. |
| Wide blast radius, security-sensitive, data migration, API or schema change, concurrency, irreversible, or resisted two attempts | `opus_review` — `opus-reviewer`. |
| You and a lane (or two models) disagree, an Opus review could not settle it, or the approach itself is deadlocked | `fable_review` — `fable-advisor`, and consider a second independent implementation to compare. |

Fable is not "high risk, therefore Fable": high risk is Opus's job. Fable is for
when the senior review itself is contested.

The router applies this table: `fable-route.py review --id <route id>` with a
review state (`file_count`, `lines_changed`, `mechanical`, `verification_passed`,
the same risk flags, `wide_blast_radius`, `lane_disagreement`,
`opus_review_inconclusive`, `architectural_deadlock`, `silence_gap`, `attempts`).
Exceptional rows are `fable_review` and high-risk rows `opus_review`, by rule —
Jev is never asked; one-file mechanical with passing verification and no silence
gap is `none`; failing verification is never `none`. Only the ordinary middle is
left to Jev (shadow/active): its default is `self_review` and Jev may only
escalate it to `opus_review` — skipping review and spending Fable are never
Jev's call. When `opus-reviewer` answers `ESCALATE`, re-run the gate with
`opus_review_inconclusive`. Jev picks a review level; it never performs the
review.

**The silence gap.** Before a review, compute what the change *should* have
touched — callers, subclasses, parallel implementations, adjacent config — and
subtract what the diff *did* touch. Hand the difference to the reviewer as paths
to check. This finds defects of omission, which reading the diff cannot: a diff
shows what changed, never what should have changed and didn't.

**Two passes.** Give the reviewer the diff, the goal, and the gap paths — and
nothing about what the implementer claims. Collect its findings. Only then send
the implementer's claims and ask which findings survive. A reviewer that reads
the claims first inherits the implementer's blind spots; a reviewer that reads
them second can catch a claim that is not true.

## Verification

You own acceptance. A lane's verification is evidence, not proof — re-run the
command yourself when the deliverable matters. Never report done on a lane's
word alone.

## Ledger

`fable-route.py` appends every route and review decision to
`~/.claude/fable-advisor/routing.jsonl` (`FABLE_LEDGER`; `off` disables it), and
`codex-lane.sh` appends one `attempt` row per lane run — that part needs no one
to remember it. A run without `--route-id` is still logged, as `unrouted`, and
the report's `compliance` block counts those: a skipped router shows up as a
number, not as silently missing data. Such a run also backfills a decision from
the spec (Jev logged beside it, never followed) and prints its `route id:` in the
`LANE REPORT` — record the outcome against that id. What only you know is whether the result was
accepted, so close each routed task with its outcome; attempts and duration are
filled in from the lane rows:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/fable-route.py" outcome --id <id> \
  --outcome success|retry|failover|blocked|unavailable|timeout
"${CLAUDE_PLUGIN_ROOT}/scripts/routing-report.py"     # per policy version: routes, model/effort, Jev
```

Every row carries `policy_version` (5.4.0 now; rows without one are the
`pre-5.4` policy). The report's headline is `current_policy`; older policies
sit beside it under `by_policy_version`, never averaged into it, because the
routes and Jev's options changed. Judge Jev's `active` mode only on
current-policy data.

Its only purpose is to answer "is this routing policy actually working?" with
numbers instead of impressions — Luna High against Max, Sol and Opus on
success, retries, duration and timeouts — and, in shadow mode, "would Jev have
done better?" A decision without an outcome is half a data point; record it.
