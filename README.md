# fable-advisor

A small control plane for delegation in Claude Code.

Implementation goes to the Codex lane by default, because the two subscriptions
are not interchangeable: Claude quota is the scarce resource that your reasoning,
review and integration consume, while the ChatGPT side runs GPT-6 Luna and Sol
with far more headroom. Work stays Claude-side only for one of five named reasons;
when it does, it runs on Claude Opus 5.5. Fable is kept for what only it is for:
questioning the approach when everything else has stalled.

Every Codex lane runs in its own disposable git worktree, so a lane cannot reach
the main tree or another lane's tree, a spec's Files are the expected scope
(strict only where it matters), the harness runs the acceptance command itself,
nothing lands over newer main-tree work, and undoing a lane is `git worktree remove` rather than a `git checkout`
that takes a co-resident lane's uncommitted work with it. Reviews are sized to
blast radius rather than applied to everything.

This is a fork of [DannyMac180/fable-advisor](https://github.com/DannyMac180/fable-advisor).

## Adaptive Routing

```bash
# Jev completely disabled — back to deterministic routing
export FABLE_JEV_MODE=off

# Measure Jev without changing behavior (the default)
export FABLE_JEV_MODE=shadow

# Let Jev participate in routing
export FABLE_JEV_MODE=active
```

| Mode | What happens |
|---|---|
| `off` | Legacy deterministic routing only. Jev code is never imported; no Jev binary, key, MCP or network is needed. |
| `shadow` | Log only. Jev classifies the ambiguous cases; its answer goes to the ledger next to the route that actually ran. |
| `active` | Jev + confidence gate + deterministic fallback. Jev's route is used only at confidence ≥ `FABLE_JEV_MIN_CONFIDENCE`, never below the risk floor and only when the route is eligible for the task; any failure falls back and is logged. |

**To stop using Jev: `export FABLE_JEV_MODE=off`.** Nothing else.

```
decision state ──► hard rules ──obvious──────────────────────────┐
                      │   (≥3 failures, deadlock, opus_failed,    │
                      │    schema/API/migration/irreversible      │
                      │    ──► also consult_first: fable-advisor) │
                      └─ambiguous──► Jev (shadow/active only)     │
                                      │ eligible options only     │
                                      │ confidence ≥ 0.80?        │
                                      │ above the risk floor?     │
                                      ├─no / error / timeout ─► deterministic route
                                      └─yes (active) ─────────────┤
                                                                  ▼
             luna_low · luna_high · luna_max · sol_high · claude_opus_high · self
                                                                  │
                                              verification ◄──────┘
                                                  │
         review hard rules ──obvious──► none / self_review / opus_review / fable_review
                                                  │
                                      ambiguous ──► Jev (same gate) ──► self_review / opus_review
```

The implementation routes form a ladder with one fork, not a line:

```
luna_low ──► luna_high ──┬──► luna_max  (narrow, failed once, verifiable) ──┐
                         └──► sol_high  (broad, integration-heavy)       ──┴──► claude_opus_high
                                                                                      │
                                                          Fable: consult / exceptional review only
```

| Route | Runs as | For |
|---|---|---|
| `luna_low` | codex, `gpt-6-luna`, effort `low` | Mechanical, one file, runnable verification, no risk flag. |
| `luna_high` | codex, `gpt-6-luna`, effort `high` | Ordinary implementation — the default, first attempt and first retry. |
| `luna_max` | codex, `gpt-6-luna`, effort `max` | A narrow retry: failed once, runnable verification, ≤ 3 files, not multi-component, no interface change, no risk flag. Never a first attempt. |
| `sol_high` | codex, `gpt-6-sol`, effort `high` | Breadth: several interacting components, integration, interface-heavy work, wide-search debugging. |
| `claude_opus_high` | `implementer`, `model: opus` (Opus 5.5), effort `high` | Two failed attempts, or judgment a spec cannot carry. Not "hard code". |
| `self` | the orchestrator | Context-bound, or below the spawn floor. |

| Fable | Runs as | For |
|---|---|---|
| `consult_first: fable-advisor` | `fable-advisor` (read-only) | Three failures, an architectural deadlock, an Opus attempt that failed, or a schema/API/migration/irreversible decision. Fable reframes; a Luna/Sol/Opus lane implements the result. |
| `fable_review` | `fable-advisor` (read-only) | Exceptional review: an Opus review could not settle it, a lane/model disagreement, or the framing itself in doubt. |

| Review | Runs as | For |
|---|---|---|
| `none` | — | One file, mechanical, verification passed, no silence gap. Rule only. |
| `self_review` | the orchestrator | Ordinary change. |
| `opus_review` | `opus-reviewer` (Opus 5.5, `high`) | Security, schema, API, migration, concurrency, irreversible, wide blast radius, or resisted two attempts. |
| `fable_review` | `fable-advisor` (Fable 5) | Exceptional only (above). Rule only. |

Jev is a cheap control-plane classifier that exists to avoid *unnecessary* Sol,
Max and Opus calls — not a cheap substitute for any of them. It picks one key
from a fixed list and returns a confidence; it never writes code, reviews code,
or sees any: the router sends it a whitelisted decision state (objective ≤ 280
chars, file count, risk flags, prior failures, verification availability) and
drops every other key. Rules still own the obvious cases — Jev is not called for
them — and the high-risk rules (security, data migration, schema, public API,
concurrency, irreversible, two failures) cannot be overridden by any Jev answer.
Jev only ever sees the routes the task is eligible for: a first attempt is
offered `luna_high`/`sol_high`, a first retry adds `luna_max` (when eligible)
and `claude_opus_high`, and Fable is never an option. `luna_low` is never a Jev
option: only the `mechanical_one_file` rule (or a caller's explicit `--route`)
picks it. In review
gating Jev can only escalate (`self_review` → `opus_review`); `none` and
`fable_review` are rule outcomes, never Jev answers.

Settings live in one file, [`scripts/fable-config.sh`](scripts/fable-config.sh),
all as environment variables:

| Variable | Default | |
|---|---|---|
| `FABLE_JEV_MODE` | `shadow` | `off` \| `shadow` \| `active`; anything else is treated as `off` |
| `FABLE_JEV_MIN_CONFIDENCE` | `0.80` | below it, active mode uses the deterministic route |
| `FABLE_JEV_TIMEOUT` | `8` | seconds before a Jev call counts as a fallback |
| `FABLE_JEV_BACKEND` | `auto` | `semdecide` \| `jev-cli`; `auto` prefers semdecide |
| `FABLE_CODEX_DEFAULT_MODEL` | `gpt-6-luna` | the codex default; change models here, not in scripts |
| `FABLE_CODEX_DEFAULT_EFFORT` | `high` | the `luna_high` effort; keep it `high` (`luna_low` and `luna_max` fix their own) |
| `FABLE_CODEX_STRONG_MODEL` | `gpt-6-sol` | the `sol_high` model |
| `FABLE_SENIOR_MODEL` | `opus` | the senior worker (`claude_opus_high`) and senior reviewer (`opus_review`), passed as the spawn's `model` |
| `FABLE_FRONTIER_MODEL` | `fable` | the frontier advisor (`consult_first`, `fable_review`) |
| `FABLE_LEDGER` | `~/.claude/fable-advisor/routing.jsonl` | `off` disables the ledger |

Claude-side **effort** is not an environment variable: the Agent tool takes no
effort per spawn and Claude Code has no variable for subagent effort, so the only
switch that takes effect is the `effort:` line in `agents/implementer.md`
(senior worker) and `agents/opus-reviewer.md` (senior reviewer). The router reads
those pins into every ledger row, so changing one from `high` to `medium` is
the whole experiment: `routing-report.py` shows `outcomes_by_model_effort`
(e.g. `claude_opus_high opus/medium` beside `opus/high`) and
`review.results_by_reviewer` (verdicts and findings per reviewer model/effort).

**Jev answers (shadow or active)** need one existing OSS CLI and a TypeSafe key —
neither is needed for `off`, and without them shadow logs each ambiguous case as
`jev_status: fallback` and routes exactly as `off` would:
[semdecide](https://github.com/sharziki/semdecide) (preferred: validates responses,
per-attempt timeout) or [jev-cli](https://pypi.org/project/jev-cli/)
(`uv tool install jev-cli`), plus `TYPESAFE_API_KEY`. Check the setup with
`python3 scripts/jev_route.py probe`, then read the results with
`scripts/routing-report.py`.

Measurement data accumulates mostly on its own: routing and review decisions
are logged by the router, and every lane run is logged by `codex-lane.sh
--route-id <id>` (status, duration, model, effort, scope violations) — the
report's `lane_attempts` and `shadow_disagreement_lanes` need nothing else. A lane
run without `--route-id` is still logged, as `unrouted`, and gets a *backfilled*
decision: the lane reads the objective, file count and whether a verification
command is named off the spec, records the model/effort it runs as the actual
route, and logs Jev's answer beside it (always log-only — a running lane's model
and effort never change). The observed route is an exact match — Luna at
`low`/`high`/`max` is `luna_low`/`luna_high`/`luna_max`, Sol at `high` is
`sol_high` — and anything else (Luna at `xhigh`, say) is `unmapped` rather than
folded into the nearest route; the real model and effort stay on the row. The
`LANE REPORT` prints that `route id:`. The one manual step is
`fable-route.py outcome --id <id> --outcome success|...`, which records whether
the result was accepted.

**Every new row carries `policy_version`** (currently `5.6.0`). The report never averages
policies together: `current_policy` is the headline, `by_policy_version` holds
one full section per policy (rows written before 5.4 have no version and form
`pre-5.4`), and `historical_all` is the labelled mix. A row belongs to the policy
of the decision it joins. Each section has `lane_attempts.by_route` (first-try
and eventual success, retry rate, average/p50/p90 lane seconds, timeout rate,
scope violations), `by_model_effort` (the same per attempt, keyed by what
actually ran, e.g. `gpt-6-luna/max`), outcome stats by route (Opus included),
Jev's `jev_recommendation_distribution`, agreement, disagreements, confidence
buckets, and the shadow counterfactuals — `jev=luna_max ran=luna_high` with how
the route that actually ran did, and how many of those `active` would have
adopted. Nothing in an existing ledger is rewritten.

Each section's `compliance` block says whether the data can be trusted before you
draw conclusions from it: the share of lane runs that carried a route id,
unrouted runs, backfilled decisions, codex decisions with no lane run, outcome rates (codex and
Claude-side routes separately), reviews linked to a decision, and the most
recent decisions still open. If the routed share stays under ~90% or the outcome
rate under ~70%, the next step is a warning hook — not before.

## Install

```
/plugin marketplace add okkyok/fable-advisor
/plugin install fable-advisor@fable-advisor
```

The `codex` lane additionally needs the [OpenAI Codex CLI](https://github.com/openai/codex)
installed and authenticated. Without it the lane reports `unavailable` and the
caller reroutes; it never silently substitutes a different model.

## What ships

| | |
|---|---|
| `skills/orchestration` | The routing policy. Loads when you are deciding whether and how to delegate. |
| `agents/codex-implementer` | Runs `codex exec` (GPT-6 Luna at `low`/`high`/`max`, or Sol, as routed). The cross-vendor implementation lane. |
| `agents/implementer` | Claude-side implementation. Depth chosen on the spawn: `model: haiku` / `sonnet` / `opus` (`claude_opus_high`), effort pinned `high`. |
| `scripts/fable-route.py` | The routing policy as code (`POLICY_VERSION`): hard rules, risk floor, `luna_max` eligibility, Fable consult triggers, review gate, ledger. Optional Jev layer behind `FABLE_JEV_MODE`. |
| `scripts/fable-config.sh` | Every setting, as an environment variable with a safe default. |
| `scripts/lane-preamble.md` | What codex reads before every spec: no delegation, the handoff file, NEED_TOOL, acceptance. Sent by `codex-lane.sh`, so no caller pastes it. |
| `scripts/prompt-budget.py` | Estimated tokens per prompt surface and per execution path (normal codex task, senior worker, review, Fable), against any git revision with `--ref`. |
| `scripts/jev_route.py` | The only Jev-specific file: a typed-choice adapter over semdecide / jev-cli. Never imported when Jev is off. |
| `scripts/routing-report.py` | Ledger summary per policy version: route and model/effort success, retries, p50/p90 duration and timeouts; Jev recommendations, agreement, confidence buckets and shadow counterfactuals. |
| `scripts/codex-lane.sh` | Runs a Codex lane inside an isolated worktree with `--model`/`--effort` from the caller, runs the acceptance command (`--verify`), and reports what it touched, inside and outside the expected scope (`--strict-scope` makes Files an allowlist). With `--route-id` it records every run in the ledger itself. |
| `scripts/codex-lane-apply.sh` | Lands a lane in the main tree: its scope plus any extra path codex named, never a strict-scope violation, never a lane that failed acceptance (without `--force`), never over a file the main tree changed since the lane started. Purely additive — never checkout/reset/clean/stash. |
| `scripts/verify-codex-lane.sh` | End-to-end check: runs a real lane against a scratch repo and asserts a co-resident lane's uncommitted work survives. |
| `tests/run.sh` | Offline suite (stub codex and Jev): routing in all three modes, every fallback, hard rules, `luna_max` eligibility, Opus escalation, Fable consult triggers, review gate, ledger, policy-versioned report, backfill, lane model/effort, expected/strict scope, harness acceptance, apply guards, isolation, concurrent lanes, prompt budgets. |
| `agents/opus-reviewer` | `opus_review`: read-only senior reviewer (Opus, effort pinned `high`), fresh-context review with the silence gap; a second pass only when needed. |
| `agents/fable-advisor` | Read-only frontier consult and exceptional reviewer (Fable 5): reframes stuck problems, never implements. Holds no write tools, so "advises only" is mechanical rather than aspirational. |

## The routing policy in one paragraph

Implementation goes to codex unless one of five reasons keeps it Claude-side:
context-bound, below the spawn floor, judgment-dominated (Opus 5.5, as are two
codex failures), review, or Claude-only tooling (which licenses the tool
operation, not the implementation). Fable does not implement: when attempts
keep failing or the design is deadlocked it is consulted to reframe the problem,
and a lane implements what comes back. Write a
five-part spec — objective, files, interfaces, constraints, verification — and
run the lane through `codex-lane.sh`; anything you leave out, the lane invents,
and Files is the expected scope — an extra file lands only if the lane names it,
and never under `strict_scope`. Codex *quota*
exhaustion stops and reports rather than failing over to Claude, because failing
over spends the scarce subscription exactly when the abundant one is unavailable.
A codex *timeout* does not move lanes — it resumes against the same worktree.
Review in proportion to blast radius — Opus for risk, Fable only when the
review itself is contested — and before reviewing compute the *silence
gap*: what the change should have touched minus what it did, because a diff shows
what changed and never what should have changed and didn't.

## 5.6.0

**`luna_low` is rule-only (policy 5.6.0).** Jev is no longer offered
`luna_low`; a first attempt in the ambiguous middle chooses between
`luna_high` and `sol_high`. `luna_low` is still chosen by the
`mechanical_one_file` rule, the risk floor is unchanged (a caller may still pass
`--route luna_low` above it), and backfilled decisions log Jev against the same
narrower list. An off-list `luna_low` answer is logged as `jev_status:
fallback`, `jev_reason: unknown_choice`, so it stays visible in the report.

Why: in the ledger, Jev recommended `luna_low` three times. The two that failed
were multi-file work (one with 13 scope violations) at confidence 0.35 and
0.47, which active mode's 0.80 gate would have refused anyway; the one that
succeeded was a confidence-1.0 comment rewrite that the rule covers. Removing
the option gives up only the few minutes low effort saves on light work in the
middle, which by definition is not the one-file mechanical case.

What this does not change: Jev's lean towards `sol_high` on first attempts
remains, now as a two-way split. Whether that lean is justified cannot be
judged until the state sent to Jev is kept in the ledger. `luna_max` is
unchanged — it is offered only on an eligible first retry, and the ledger has no
retry decisions from Jev yet.

**Compatibility.** Jev's option list changed, so 5.6.0 is its own
`policy_version`; judge `active` on 5.6.0 rows only. Route ids, CLI, ledger
format and `FABLE_*` variables are unchanged.

## 5.5.0

**Thin control plane: policy as code, goals as prompts (policy 5.5.0).** The
routes, rules, floors and Jev's options are unchanged. What changed is where
policy lives: rules that a script can guarantee moved out of the prompts, and
the prompts now carry goals, constraints and acceptance criteria rather than a
walk-through of the model's reasoning.

- **Prompts.** The orchestration skill holds roles, the five Claude-side
  reasons, the two routing choices left to judgment (`sol_high`, `luna_max`),
  the failure table and the review principles; every rule the router enforces
  is described only in `fable-route.py`. `codex-implementer` loses its codex
  preflight (the lane detects an unusable codex and exits `3`), the spec
  boilerplate (now `scripts/lane-preamble.md`, sent by the lane) and the flag
  reference. No prompt names a model version; models are configuration.
  Measured with `scripts/prompt-budget.py --ref 50fe90c` (the 5.4.0 commit), a normal codex-routed task
  carries about 71% fewer Claude-side instruction tokens (≈10.2k → ≈2.9k), and
  the descriptions loaded every turn 45% fewer.
- **Scope.** Files is the *expected* scope: codex may change an adjacent file
  the objective needs, and it lands when codex's final message names it (an
  unnamed one is reported and left behind). `strict_scope` — set by the router
  for security-sensitive, data-migration and irreversible work, or requested in
  the state — makes Files an allowlist, enforced by `codex-lane-apply.sh`. The
  attempt row's `scope_violations` still counts paths outside Files in both
  modes, so it stays comparable with 5.4.
- **Acceptance.** `codex-lane.sh --verify <cmd>` runs the acceptance command in
  the worktree after codex exits (exit `6` on failure, worktree kept) and
  records `verify` on the attempt row. The supervisor no longer re-runs it, the
  orchestrator re-runs only when other work landed in the main tree meanwhile or
  the worker was Claude-side, and `fable-route.py review --id` takes
  `verification_passed` from the lane when the state omits it. `lane_status`
  keeps its 5.4 meaning (codex's own result); acceptance is a separate field.
- **Apply guards.** `codex-lane-apply.sh` without `--files` lands what the scope
  allows, refuses a lane whose acceptance failed (unless `--force`), and skips
  any file the main tree changed after the lane started (exit `7`, worktree
  kept) — which is what makes an expected scope safe beside other lanes. The
  lane also diffs against its recorded baseline, so a codex that commits in its
  worktree is no longer read as an empty diff, and prints codex's handoff file
  itself on a timeout.
- **Review.** Fresh context stays: the reviewer gets goal, constraints, diff,
  acceptance result and silence gap. The second pass with the implementer's
  claims is now conditional (a contradicted claim, a disputed withdrawal, or
  stakes that justify it) instead of mandatory.
- **Measurement.** Decision rows carry `role`; codex decisions print
  `lane_args`; attempt rows add `verify`, `verify_s` and `strict_scope`;
  `outcome` takes `--verdict` and `--findings`. The Claude-side effort is read
  from the agent's `effort:` pin, so an Opus `medium` vs `high` comparison is a
  one-line change with honest ledger rows. The report adds
  `verify_first_pass`/`verify_eventually_pass` per route, `verify_pass_rate` per
  model/effort, `outcomes_by_model_effort` and `review.results_by_reviewer`.

**Jev.** Unchanged: `off`/`shadow`/`active`, the same options, question and
decision state (`strict_scope` is rule-only and never sent). Because the lane
prompt, scope and acceptance changed, outcomes are not comparable across the
boundary, so 5.5.0 is its own `policy_version` and the report keeps it apart
from 5.4.0 and `pre-5.4`. Judge `active` on 5.5.0 rows only.

**Compatibility.** Route ids, the router's CLI and output fields, the ledger
format, `FABLE_*` variables and every existing `codex-lane.sh` /
`codex-lane-apply.sh` invocation keep working; the new flags are optional.
Callers of `codex-implementer` that send `MODEL:`/`EFFORT:`/`ROUTE_ID:` lines
still work. Behaviour changes to know about: a lane run with `--files` now
treats them as the expected scope (use `--strict-scope`, or the router's
`lane_args`, for the old allowlist), and its report says `OUTSIDE EXPECTED
SCOPE` where it said `SCOPE VIOLATIONS`.

## 5.4.0

**Routing re-tiered for GPT-6 Luna Max and Claude Opus 5.5 (policy 5.4.0).**
This changes routing semantics, so the ledger now says which policy decided
each row.

- **`luna_max`** (GPT-6 Luna, effort `max`) is new, and it is a *narrow retry*,
  not a harder default: eligible only after exactly one failure, with a runnable
  verification, a known file count ≤ 3, no multi-component or interface change,
  and no risk flag (`luna_max_eligible()`). The deterministic first retry stays
  `luna_high`; `luna_max` is chosen by the caller (`--route luna_max`, refused
  when ineligible) or by Jev in `active`. `luna_high` is still the default and
  `FABLE_CODEX_DEFAULT_EFFORT` is still `high`.
- **`sol_high`** is now described by breadth — several interacting components,
  integration, interface-heavy work — as the peer of `luna_max`, not a rung above it.
- **`claude_opus_high`** (`implementer`, `model: opus`, effort pinned `high`)
  replaces `claude_fable`: two failures and judgment-dominated work go to Opus
  5.5. `opus` is Claude Code's alias for the latest Opus (`claude-opus-5-5` in
  Claude Code 2.1.283's model catalog) and a value the Agent tool's per-spawn
  `model` accepts. `--route claude_fable` is refused with a pointer here.
- **Fable is consult and exceptional review only.** Three failures,
  `architectural_deadlock`, `opus_failed` (new flags), or the existing
  schema/API/migration/irreversible triggers return `consult_first:
  fable-advisor` with a `consult_reason`; Fable reframes and a lane implements.
  Fable is never an implementation route and never a Jev option.
- **Reviews:** `none` · `self_review` · `opus_review` (new `opus-reviewer` agent:
  high risk, wide blast radius, two attempts) · `fable_review` (lane/model
  disagreement, `opus_review_inconclusive`, `architectural_deadlock`). Jev may
  choose only `self_review` or `opus_review`.
- **Jev's options follow eligibility:** first attempts `luna_low`/`luna_high`/
  `sol_high`; one failure adds `luna_max` (if eligible) and `claude_opus_high`;
  two failures are a hard rule and skip Jev. Shadow still never changes a route;
  active still needs confidence, floor and now eligibility. `off` is unchanged.

**Measurement.** Decision, review, attempt and outcome rows carry
`policy_version: "5.4.0"` (`POLICY_VERSION`). `routing-report.py` reports
`current_policy`, `by_policy_version` and a labelled `historical_all`, with
`policy_version_distribution`, so v5.3 and v5.4 numbers are never averaged into
one headline; old rows (no version, `claude_fable`, high-risk `fable_review`)
stay readable as `pre-5.4`. New per-section fields: `p50_lane_s`, `p90_lane_s`,
`timeout_rate` and `retry_rate` per route, `by_model_effort` per attempt (the
real model/effort), duration percentiles in outcome stats,
`jev_recommendation_distribution`, `would_accept_in_active` on shadow
counterfactuals, and review-side Jev recommendations. **Backfill fix:** Luna at
`max` was recorded as `luna_high`; it is now `luna_max`, and a pair no route runs
(Luna `xhigh`, Sol `xhigh`) is `unmapped` instead of being folded into High.
Existing ledgers are read as they are — nothing to migrate.

**Breaking for report consumers:** the report's per-policy numbers moved under
`current_policy` / `by_policy_version`; the old top-level keys (`jev`,
`lane_attempts`, `compliance`, …) are now inside each section.

## 5.3.0

**Unrouted lane runs feed shadow mode.** Jev is only asked inside
`fable-route.py route`, so a `codex-lane.sh` call without `--route-id` left
shadow with nothing to measure — in practice most lane runs. Such a run now
backfills a routing decision (`fable-route.py backfill`) from what the spec
states — objective, file count, whether a verification command is named — with
the lane's model/effort as the actual route and Jev's answer logged beside it.
Jev stays log-only there even in `active`, because the lane has already chosen.
The attempt row keeps `unrouted`, so `compliance.routed_lane_run_rate` still
measures the skipped router (backfills no longer count as routed), and the
report adds `backfilled_decisions` and `jev.consulted_on_backfill`. With
`FABLE_LEDGER=off` nothing is backfilled and Jev is not called.

## 5.2.0

**Shadow is the default.** `FABLE_JEV_MODE` now defaults to `shadow`, so every
install starts collecting the data that decides whether `active` is worth
turning on. Shadow never changes a route or a review: Jev is asked only about
the ambiguous middle and its answer is logged next to the route that ran. With
no Jev backend or `TYPESAFE_API_KEY` each such call is logged as
`jev_status: fallback` at no latency cost. `export FABLE_JEV_MODE=off` restores
the previous behaviour.

## 5.1.1

A codex that cannot reach the API does not exit — it logs "Reconnecting...
waiting for network" until the wall clock kills it, which the lane used to
report as a timeout to resume. Seen with real codex 0.157.1 behind a proxy that
refused the API. A timeout that wrote nothing and ends in that state is now
`unavailable` (exit `3`), naming the network cause and keeping the log; a
timeout after work landed is still a resumable timeout.

## 5.1.0

**Permanent (independent of Jev).** GPT-6 Luna is the default codex model, and
`codex-lane.sh` takes `--model` and `--effort` from the caller (defaults in
`fable-config.sh`), so the next model is a config change. Effort values follow
codex 0.157 (`low|medium|high|xhigh|max`); `ultra` is refused because it means
automatic delegation. The routing policy is now code (`fable-route.py`) with a
risk floor, a `sol_high` route, and a review gate; the ledger is written
automatically and joined into outcome rows that `routing-report.py` summarises.
The lane now exits `3` on missing codex, auth, quota or model access (as the agent
doc always claimed), keeps codex's transcript in a log and replays only its tail,
and passes `--add-dir ~/.codex/sol-advisor` only when that directory exists.
`codex-implementer` no longer refers to the removed `tool-bridge` and
`failover-implementer`.

**Measurement without memory.** Every lane run writes its own `attempt` row
(status, duration, model, effort, scope violations) — with `--route-id` joined to
its routing decision, without one as `unrouted` — and `routing-report.py` adds a
`compliance` block that says whether the data is complete enough to judge from.
The only manual step left is recording whether a result was accepted.

**Optional (Jev).** `FABLE_JEV_MODE=shadow|active` adds Jev as a classifier for
the ambiguous middle of implementation routing and review gating. Off by
default; delete `scripts/jev_route.py` and everything else still works.

## 5.0.0

Rebuilt around 1,065 logged routing decisions. Codex stays the default lane — the
quota asymmetry that makes it the right default is not visible in a success-rate
column — but the two failure modes the log actually shows are now handled by
mechanism rather than by instruction.

**Worktree isolation.** The log's costly failures were not model errors: a lane
edited files its spec never listed, and the cleanup (`git checkout -- <path>` on
the shared tree) destroyed another lane's uncommitted work. Lanes now run in
disposable worktrees, so that chain cannot form. Concurrency, incidentally, was
never the cause — lanes overlapping 3+ deep succeeded at 81.3% against 62.4% for
lanes running alone.

**Quota exhaustion no longer fails over silently.** 23% of codex failures were
ChatGPT quota, and the old rule moved those 47 tasks onto Claude — spending the
scarce subscription precisely when the abundant one was unavailable. The lane now
reports the reset time and lets the user decide.

**Breaking.** `fable-implementer`, `failover-implementer` and `claude-committer`
are merged into `implementer` — they differed only by `model:`, and Claude Code
resolves a per-spawn `model` parameter ahead of agent frontmatter. `tool-bridge`
is removed: over five weeks it was used 4 times against 47 cases of the situation
it existed to prevent, so it was doctrine that did not describe reality.

**Also.** The orchestration skill drops from 39.8 KB to ~9.5 KB — the routing
matrix, the five reasons, the failure table, the spec contract, the silence gap
and the two-pass review survive; the cost-discipline preamble, effort-selection
ceremony, context-inheritance grades, mandatory ledger prose and two
self-referential calibration sections do not. The codex preflight no longer uses
`codex --version`, which hangs on some builds and made a healthy install look
unavailable.

## Future work

Routing (decide from 5.4.0 data, not before):

- Whether `luna_max` should become the *deterministic* first retry for eligible
  tasks — read `jev=luna_max ran=luna_high` against `luna_high` retries, and
  `luna_max`'s `p90_lane_s` / `timeout_rate` against the 570 s wall clock.
- Whether Opus earns more of the first-retry share than it gets, from
  `jev=claude_opus_high ran=…` counterfactuals.
- Whether Jev is worth `active`, judged on `current_policy` only.

Context management, kept out of 5.1 on purpose, because a context-management mistake has a larger
blast radius than a routing mistake — a discarded tool result silently lowers
quality instead of failing loudly:

- **Jev-driven context compaction** (e.g. fast-jev-compaction). Not a dependency.
- **Tool-output pruning** (e.g. Winnow) as an optional context-filtering layer,
  evaluated separately with its own ledger before it touches any lane.

## License

MIT. See [LICENSE](LICENSE).
