# fable-advisor

A small control plane for delegation in Claude Code.

Implementation goes to the Codex lane by default, because the two subscriptions
are not interchangeable: Claude quota is the scarce resource that your reasoning,
review and integration consume, while the ChatGPT side runs GPT-6 Luna and Sol
with far more headroom. Work stays Claude-side only for one of five named reasons.

Every Codex lane runs in its own disposable git worktree, so a lane cannot reach
the main tree or another lane's tree, scope violations are reported instead of
landing, and undoing a lane is `git worktree remove` rather than a `git checkout`
that takes a co-resident lane's uncommitted work with it. Reviews are sized to
blast radius rather than applied to everything.

This is a fork of [DannyMac180/fable-advisor](https://github.com/DannyMac180/fable-advisor).

## Adaptive Routing

```bash
# Jev completely disabled (the default) — back to deterministic routing
export FABLE_JEV_MODE=off

# Measure Jev without changing behavior
export FABLE_JEV_MODE=shadow

# Let Jev participate in routing
export FABLE_JEV_MODE=active
```

| Mode | What happens |
|---|---|
| `off` | Legacy deterministic routing only. Jev code is never imported; no Jev binary, key, MCP or network is needed. |
| `shadow` | Log only. Jev classifies the ambiguous cases; its answer goes to the ledger next to the route that actually ran. |
| `active` | Jev + confidence gate + deterministic fallback. Jev's route is used only at confidence ≥ `FABLE_JEV_MIN_CONFIDENCE` and never below the risk floor; any failure falls back and is logged. |

**To stop using Jev: `export FABLE_JEV_MODE=off`** (or unset it). Nothing else.

```
decision state ──► hard rules ──obvious──────────────────────────┐
                      │                                           │
                      └─ambiguous──► Jev (shadow/active only)     │
                                      │ confidence ≥ 0.80?        │
                                      │ above the risk floor?     │
                                      ├─no / error / timeout ─► deterministic route
                                      └─yes (active) ─────────────┤
                                                                  ▼
                              luna_low · luna_high · sol_high · claude_fable · self
                                                                  │
                                              verification ◄──────┘
                                                  │
                        review hard rules ──obvious──► none / self_review / fable_review
                                                  │
                                      ambiguous ──► Jev (same gate) ──► self_review / fable_review
```

| Route | Runs as | For |
|---|---|---|
| `luna_low` | codex, `gpt-6-luna`, effort `low` | Mechanical, one file, runnable verification, no risk flag. |
| `luna_high` | codex, `gpt-6-luna`, effort `high` | Ordinary implementation — the default. |
| `sol_high` | codex, `gpt-6-sol`, effort `high` | Hard but well-specified: several components, integration, debugging. |
| `claude_fable` | `implementer`, `model: fable` | Judgment a spec cannot carry, or two failed attempts. Not "hard code". |
| `self` | the orchestrator | Context-bound, or below the spawn floor. |

Jev is a cheap control-plane classifier that exists to avoid *unnecessary* Fable
and Sol calls — not a cheap substitute for Fable. It picks one key from a fixed
list and returns a confidence; it never writes code, reviews code, or sees any:
the router sends it a whitelisted decision state (objective ≤ 280 chars, file
count, risk flags, prior failures, verification availability) and drops every
other key. Rules still own the obvious cases — Jev is not called for them — and
the high-risk rules (security, data migration, schema, public API, concurrency,
irreversible, two failures) cannot be overridden by any Jev answer. In review
gating Jev can only escalate (`self_review` → `fable_review`); `none` is a rule
outcome for verified one-file mechanical changes, never a Jev answer.

Settings live in one file, [`scripts/fable-config.sh`](scripts/fable-config.sh),
all as environment variables:

| Variable | Default | |
|---|---|---|
| `FABLE_JEV_MODE` | `off` | `off` \| `shadow` \| `active`; anything else is treated as `off` |
| `FABLE_JEV_MIN_CONFIDENCE` | `0.80` | below it, active mode uses the deterministic route |
| `FABLE_JEV_TIMEOUT` | `8` | seconds before a Jev call counts as a fallback |
| `FABLE_JEV_BACKEND` | `auto` | `semdecide` \| `jev-cli`; `auto` prefers semdecide |
| `FABLE_CODEX_DEFAULT_MODEL` | `gpt-6-luna` | the codex default; change models here, not in scripts |
| `FABLE_CODEX_DEFAULT_EFFORT` | `high` | `low` \| `medium` \| `high` \| `xhigh` \| `max` |
| `FABLE_CODEX_STRONG_MODEL` | `gpt-6-sol` | the `sol_high` model |
| `FABLE_LEDGER` | `~/.claude/fable-advisor/routing.jsonl` | `off` disables the ledger |

**Enabling Jev (shadow or active)** needs one existing OSS CLI and a TypeSafe key —
neither is needed for `off`:
[semdecide](https://github.com/sharziki/semdecide) (preferred: validates responses,
per-attempt timeout) or [jev-cli](https://pypi.org/project/jev-cli/)
(`uv tool install jev-cli`), plus `TYPESAFE_API_KEY`. Check the setup with
`python3 scripts/jev_route.py probe`, then read the results with
`scripts/routing-report.py`.

Measurement data accumulates mostly on its own: routing and review decisions
are logged by the router, and every lane run is logged by `codex-lane.sh
--route-id <id>` (status, duration, model, effort, scope violations) — the
report's `lane_attempts` and `shadow_disagreement_lanes` need nothing else. A lane
run without `--route-id` is still logged, as `unrouted`. The one manual step is
`fable-route.py outcome --id <id> --outcome success|...`, which records whether
the result was accepted.

The report's `compliance` block says whether the data can be trusted before you
draw conclusions from it: the share of lane runs that carried a route id,
unrouted runs, codex decisions with no lane run, outcome rates (codex and
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
| `agents/codex-implementer` | Runs `codex exec` (GPT-6 Luna by default, Sol when routed). The cross-vendor implementation lane. |
| `agents/implementer` | Claude-side implementation. Depth chosen on the spawn: `model: haiku` / `sonnet` / `fable`. |
| `scripts/fable-route.py` | The routing policy as code: hard rules, risk floor, review gate, ledger. Optional Jev layer behind `FABLE_JEV_MODE`. |
| `scripts/fable-config.sh` | Every setting, as an environment variable with a safe default. |
| `scripts/jev_route.py` | The only Jev-specific file: a typed-choice adapter over semdecide / jev-cli. Never imported when Jev is off. |
| `scripts/routing-report.py` | Ledger summary: Jev/legacy agreement, route distribution, success/retry/duration by route, confidence buckets. |
| `scripts/codex-lane.sh` | Runs a Codex lane inside an isolated worktree with `--model`/`--effort` from the caller, and reports what it touched, including paths outside its spec. With `--route-id` it records every run in the ledger itself. |
| `scripts/codex-lane-apply.sh` | Copies only the spec'd paths back into the main tree. Purely additive — never checkout/reset/clean/stash. |
| `scripts/verify-codex-lane.sh` | End-to-end check: runs a real lane against a scratch repo and asserts a co-resident lane's uncommitted work survives. |
| `tests/run.sh` | Offline suite (stub codex and Jev): routing in all three modes, every fallback, hard rules, review gate, ledger, lane model/effort, isolation, concurrent lanes. |
| `agents/fable-advisor` | Read-only reviewer and second opinion (Fable 5). Holds no write tools, so "advises only" is mechanical rather than aspirational. |

## The routing policy in one paragraph

Implementation goes to codex unless one of five reasons keeps it Claude-side:
context-bound, below the spawn floor, judgment-dominated, review, or Claude-only
tooling (which licenses the tool operation, not the implementation). Write a
five-part spec — objective, files, interfaces, constraints, verification — and
run the lane through `codex-lane.sh`; anything you leave out, the lane invents,
and anything it writes outside **Files** stays in the worktree. Codex *quota*
exhaustion stops and reports rather than failing over to Claude, because failing
over spends the scarce subscription exactly when the abundant one is unavailable.
A codex *timeout* does not move lanes — it resumes against the same worktree.
Review in proportion to blast radius, and before reviewing compute the *silence
gap*: what the change should have touched minus what it did, because a diff shows
what changed and never what should have changed and didn't.

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

Kept out of 5.1 on purpose, because a context-management mistake has a larger
blast radius than a routing mistake — a discarded tool result silently lowers
quality instead of failing loudly:

- **Jev-driven context compaction** (e.g. fast-jev-compaction). Not a dependency.
- **Tool-output pruning** (e.g. Winnow) as an optional context-filtering layer,
  evaluated separately with its own ledger before it touches any lane.

## License

MIT. See [LICENSE](LICENSE).
