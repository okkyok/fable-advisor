---
name: orchestration
description: Routing doctrine for the architect-as-orchestrator pattern — how an Opus session delegates routine implementation to a cheaper cross-vendor lane, escalates high-complexity one-offs to Fable, and gets every deliverable reviewed by the Fable advisor before reporting done. Codex is the default lane; work stays Claude-side only under five named exceptions. USE WHEN delegating implementation work, classifying a task as commit/implement/explore/ingest/review/hardest, deciding whether something is worth a codex round trip or should stay in-session, choosing between codex-implementer/fable-implementer/claude-committer lanes, writing a spec for a subagent, deciding whether to consult fable-advisor, handling a codex quota or rate-limit failover, managing session cost or token spend, or running any multi-task build where the session is the architect.
---

# Orchestration — the architect's routing doctrine

The session is the architect: it owns requirements, architecture, decomposition, specs, routing, and verification. It should almost never type implementation code. Every implementation task gets routed to the cheapest lane that is adequate for it — escalation to Fable is deliberate, per task, never a fixed binding — and every finished deliverable gets a Fable review before the architect reports done.

## Cost discipline — the prime directive

The economics of this pattern: Opus orchestrates (judgment-heavy, volume-light), GPT-5.6 Sol does the routine typing (volume-heavy, cheap, cross-vendor), and Fable — the most expensive model available — is spent only where it changes outcomes: the hardest one-off implementations and the final review. Three rules follow.

**Emit judgment, not volume.** The architect's output is decomposition, specs, routing decisions, verdicts on diffs, and short reports. It does not type implementation code, test bodies, boilerplate, or config files. A code block longer than an interface signature or a few illustrative lines is a spec that hasn't been delegated yet — stop and delegate it. Fixing a lane's bug by hand is the same failure in disguise: send a corrected spec back to the lane instead.

**Keep the context lean.** Everything in the architect's context is re-read at architect prices on every turn. Delegate broad exploration, codebase searches, and log-grepping to a cheap read-only agent and keep only the conclusions; read files yourself only when the decision genuinely depends on the exact code. Don't paste long files, full diffs, or verbose command output into the conversation when a path reference or an excerpt will do.

**Reason once, then hand off.** Do the hard thinking — the architecture, the interface design, the debugging hypothesis — in one pass, capture it in the spec, and let the lane carry it from there. Re-deriving decisions across turns burns the premium twice.

What stays with the architect regardless of cost: decomposition, interface design, hypothesis selection when debugging, spec writing, lane routing, and judging verification evidence. Those tokens are what the premium is for — everything else is a candidate for delegation.

## The lanes

| Lane | Producer | Invoke | Route here when |
|---|---|---|---|
| Routine | GPT-5.6 Sol (high reasoning) | `codex-implementer` agent | The spec fully determines the outcome: boilerplate, wiring, CRUD, mechanical edits, straightforward features. **Default lane.** Requires the codex CLI. |
| High-complexity | Fable 5 | `fable-implementer` agent | The outcome depends heavily on judgment the spec can't capture: subtle concurrency, non-trivial algorithms, security-sensitive paths, hard debugging, wide-blast-radius refactors — or the routine lane has already failed the task once. One-off escalations, never the default. |
| Floor | Claude Haiku 4.5 | `claude-committer` agent | Mechanical, fully-determined edits below the codex spawn floor but too repetitive for the architect's own context: bulk renames, import fixes, applying one known pattern across many files. Nothing that requires a decision. |
| Review | Fable 5 | `fable-advisor` agent | Not an implementation lane. Commitment boundaries and the mandatory end-of-deliverable review — see below. |

Deciding rule: how much does the outcome depend on judgment the spec can't capture? Little → the default codex lane; you will verify anyway. A lot, and mistakes are costly → escalate to `fable-implementer`, or keep that piece with the architect. A routine-lane task that fails its spec once gets a corrected spec; twice, it escalates to Fable — repetition is evidence the task was misclassified.

The codex lane is also the cross-vendor half of the pattern: its output comes from a non-Anthropic family, so the Claude architect's verification and the Fable review are genuine cross-vendor checks, not same-family self-review.

If the codex lane returns `unavailable` or `timeout`, re-route the same spec to `fable-implementer` and say so explicitly in your report — never quietly absorb the substitution or the cost change.

## Task classes and the Claude-side exceptions

This session runs a Claude subscription and a ChatGPT subscription side by side, and the Claude side is the scarcer of the two: the architect burns it on every turn just by thinking. So the default is inverted from "use the cheap lane when it obviously wins" to **codex by default; keep work on the Claude side only when Claude obviously wins**. Classify each task, then check the exceptions — the classification is a label, not a permission to skip the check.

| Class | What it is | Default |
|---|---|---|
| `commit` | Trivial edits: typo, one-line fix, version bump, config value | codex — unless exception 2 |
| `implement` | Code that a complete spec fully determines | codex (`codex-implementer`) |
| `explore` | Open-ended search: where does X live, how does Y work | codex — unless exception 1 or 2 |
| `ingest` | Reading long material: logs, dumps, docs, transcripts | codex. Never route here for context economy reasons alone — high token volume is exactly what the ChatGPT side is for |
| `review` | Adversarial checking of a diff or design | codex first (independent family), then `fable-advisor` as the final gate |
| `hardest` | Judgment-dominated work, or a task the routine lane already failed twice | `fable-implementer` — the one class that is Claude-side by default |

### The five exceptions — keep it on the Claude side only when one applies

1. **Context-bound.** The task depends on conversation state — decisions made, paths already ruled out, "the thing we just changed". Writing a self-contained five-part spec would cost more than doing the work. Delegating here doesn't save money, it launders context loss into a bad diff.
2. **Below the spawn floor.** A codex round trip on this machine costs **11–25 s before the model does any work at all**, and ~6–9 k tokens for a no-op. If the architect is confident it can finish in about that time, the round trip is pure latency. Measured 2026-08-01 on codex 0.146.0: 11 s (`--ignore-user-config`, low effort), 24 s (user config, high effort), 86 s for a one-line fix end to end.
3. **Judgment-dominated** — the `hardest` class. Subtle concurrency, security-sensitive paths, non-trivial algorithms, or a spec the routine lane has now failed twice. Re-sending a misclassified task to codex is a third failure with extra steps.
4. **The final review gate.** `fable-advisor` reads the deliverable with fresh eyes. This never moves.
5. **Claude-only tooling.** The work needs MCP servers, browser control, the iOS simulator, or anything else reachable from this session but not from `codex exec`.

None of these apply? It goes to codex. "It felt faster to just do it" is exception 2 only if the architect can name the number.

### Quota failover

The two subscriptions have independent limits, and codex-by-default means the ChatGPT side is now the one that gets drained first. When codex returns a rate-limit or quota error, treat it exactly like `unavailable`: re-route to the Claude lane, **and say so in the report** — a silent failover turns a routing policy into a cost surprise. If the failover fires more than once in a session, stop and tell the user which side is exhausted; the correct fix is a routing decision, not more retries.

## The spec contract

Implementers share none of your conversation context. Every delegation prompt carries all five parts:

1. **Objective** — what to build or change, one paragraph
2. **Files** — exact paths to create or modify
3. **Interfaces** — signatures, types, or API shapes the code must match
4. **Constraints** — project conventions, things not to touch
5. **Verification** — the command(s) that prove it works

A spec you can't finish writing is a signal the decision isn't made yet — that's architect work, not a reason to hand the ambiguity to a cheaper model.

## Parallelism

Independent specs (no shared files, no ordering dependency) launch as parallel agents in a single message. Sequential chains and single-file surgery stay serial. For high-stakes work, run `codex-implementer` and `fable-implementer` on the same spec and let the architect pick the stronger diff — two model families, one judged result.

## Commitment boundaries and the final review

Consult `fable-advisor` (read-only, verdict in under 300 words) at the moments that decide whether the next hour is wasted:

- Before committing to an architecture, data migration, API shape, or refactor strategy
- Whenever the same problem has resisted two distinct attempts
- **Always, once, at the end of a deliverable** — the advisor reads the accumulated changes with fresh eyes, against the stated goal rather than the conversation, and returns ship / fix-first / rethink. The architect does not report done before this review.

Pass it the decision (or, for final review, the diff and the stated goal), the constraints, and the options considered. Act on the verdict or surface the disagreement — never silently ignore it.

One honest caveat: when the deliverable came from `fable-implementer`, the reviewer and the implementer are the same model. The final review is still worth it — it reads the diff in a clean context, against the goal rather than the conversation — but it is a fresh-eyes check there, not an independent-model check. Cross-vendor independence comes from the codex lane.

## Verification

Reports are claims, not evidence. Before accepting any lane's work: read the diff, and re-run the verification command (or spot-check its quoted output against the working tree). "Should work", "tests should pass", or a report with no command output means the task is not done. A lane that reports a spec gap gets a corrected spec, not a "use your judgment".
