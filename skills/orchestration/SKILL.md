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

## Context inheritance grades

Inherited context is safe in proportion to how falsifiable it is. Four grades, in increasing order of what they carry and decreasing order of what the receiver can check:

| Grade | Carries | Can the receiver falsify it? |
|---|---|---|
| `blind` | The artifact alone — the diff, the stated goal | Yes, completely |
| `facts` | + tool-derived facts: impact set, test output, which lane produced the diff | Yes, by recomputing them |
| `briefed` | + the producing agent's claims: "X is safe because Y", "that file is unrelated" | **No — unverified belief** |
| `full` | + conversation state: options ruled out, decisions already made | No — path-dependent and unverifiable |

**The deciding rule: producers inherit, judges are cut off — but a judge always gets the target and the criterion. What it must not inherit is the process.** A wrong prior costs a producer little, because verification comes after it. A wrong prior costs a judge everything, because removing the prior *is* the verification.

When the grade isn't obvious, one test: **does this widen the receiver's attention or narrow it?** An impact set widens. "That file is unrelated" narrows. Widening inherits; narrowing does not.

Defaults:

- `codex-implementer`, `fable-implementer`, `claude-committer` → `facts`. The five-part spec is already a facts-grade payload; keep it that way.
- `fable-advisor` at a commitment boundary → `facts`
- `fable-advisor` at final review → `facts` on the first pass, `briefed` only on the reconcile pass (see below)
- Work kept in-session under exception 1 → `full` by definition; that is what exception 1 *means*

Record the grade in the ledger (`ctx`). Never raise the grade mid-task without first putting the lower-grade output on the record.

### Passing an impact set without narrowing attention

Whenever a spec or a review carries a tool-derived impact set, label it as a floor, not a ceiling:

> Impact set (**the minimum to check, not the complete set**): …

An over-predicting impact analysis is the right kind of wrong here. A tight one that misses a caller is the wrong kind.

### Retries carry inverted claims, never the process

A lane that failed once gets a corrected spec. The previous attempt is `briefed` material and must arrive polarity-inverted, or the next attempt inherits the same blind spot:

> ✗ "The previous attempt tried solving this in the cache layer and the tests failed."
> ✓ "The previous attempt *believed* the cache layer could solve this. That belief produced failure Y. Treat the premise as false."

## Parallelism

Independent specs (no shared files, no ordering dependency) launch as parallel agents in a single message. Sequential chains and single-file surgery stay serial. For high-stakes work, run `codex-implementer` and `fable-implementer` on the same spec and let the architect pick the stronger diff — two model families, one judged result.

## Commitment boundaries and the final review

Consult `fable-advisor` (read-only, verdict in under 300 words) at the moments that decide whether the next hour is wasted:

- Before committing to an architecture, data migration, API shape, or refactor strategy
- Whenever the same problem has resisted two distinct attempts
- **Always, once, at the end of a deliverable** — the advisor reads the accumulated changes with fresh eyes, against the stated goal rather than the conversation, and returns ship / fix-first / rethink. The architect does not report done before this review.

Pass it the decision (or, for final review, the diff and the stated goal), the constraints, and the options considered. Act on the verdict or surface the disagreement — never silently ignore it.

One honest caveat: when the deliverable came from `fable-implementer`, the reviewer and the implementer are the same model. The final review is still worth it — it reads the diff in a clean context, against the goal rather than the conversation — but it is a fresh-eyes check there, not an independent-model check. Cross-vendor independence comes from the codex lane.

### The final review runs in two passes

Independence comes from ordering, not isolation. The reviewer can have both a clean read *and* the implementer's claims — as long as the clean read is on the record first.

1. **Pass 1 — `facts`.** Spawn `fable-advisor` with the diff, the stated goal, the constraints, the *name* of the lane that produced it, and the silence gap (below). No implementer report, no conversation. It returns a **numbered findings list** and a verdict.
2. **Pass 2 — `briefed`.** Continue the *same* agent with `SendMessage`, handing it the implementer's claims as a falsification list, not as background. It answers two questions only: which numbered findings die, and which claims now look doubtful. **A finding may be withdrawn only against named file:line evidence — "the implementer says it's handled" is not evidence.**

Pass 2 is short: same agent, same context, nothing to re-read. It costs a fraction of a second review, and pass 1 cannot be retro-edited by what pass 2 reveals.

If your harness can't continue a finished subagent, spawn pass 2 fresh and paste the pass-1 findings back verbatim. What makes this work is that the clean read is already fixed in writing — not that it lives in the same context.

The lane's *identity* is a fact and travels in pass 1. The lane's *report* is a claim and waits for pass 2.

### The silence gap

The most dangerous thing a summary carries is what it silently omits: the implementer never considered concurrency, so its report contains no concurrency, so the reviewer's attention never goes there. A summary cannot report its own blind spots — so construct them:

```
impact set   = changed files ∪ their callers, dependents, and covering tests
               (any structural query that resolves symbols across the repo:
                a call-graph or code-intelligence MCP, an LSP, or grep on the
                changed symbol names — the source doesn't matter, the coverage does)
mentioned    = files in the diff ∪ files the implementer's report names
silence gap  = impact set − mentioned
```

Files structurally inside the blast radius that no agent has said one word about. That is the reviewer's priority queue, and it is anchor-free by construction: it came from the code, not from anyone's account of the code.

`fable-advisor` has `Read, Grep, Glob` and no Bash or MCP — **the architect computes the gap and passes the paths**; the advisor reads those files itself. An empty gap is a result worth stating in pass 1, not a step to skip.

## Verification

Reports are claims, not evidence. Before accepting any lane's work: read the diff, and re-run the verification command (or spot-check its quoted output against the working tree). "Should work", "tests should pass", or a report with no command output means the task is not done. A lane that reports a spec gap gets a corrected spec, not a "use your judgment".

## Routing ledger

Every routing decision is a data point for tuning this doctrine — the spawn floor, the exception boundaries, and the failover frequency are all calibrated from it. The architect appends one JSON line to `~/.claude/fable-advisor/routing.jsonl` (outside this public repo — ledger entries contain task details and must never be committed here) at each of these moments:

- a delegated task reaches its final outcome (verified, escalated, or abandoned)
- a task is **kept in-session via an exception** — these entries are what calibrate exceptions 1, 2, and 5
- a failover fires (quota, rate limit, `unavailable`, `timeout`)

Fields:

```json
{"ts":"<ISO8601>","task":"<short label>","class":"commit|implement|explore|ingest|review|hardest","lane":"codex-implementer|fable-implementer|claude-committer|fable-advisor|architect","exception":null,"ctx":"blind|facts|briefed|full|facts→briefed","outcome":"success|spec-retry|escalated|failover|abandoned","attempts":1,"duration_s":90,"note":""}
```

- `lane: "architect"` with `exception: 1–5` records work kept in-session; `duration_s` is the actual time it took, so exception-2 claims are checkable against the spawn floor.
- `ctx` is the context inheritance grade that was actually passed. A two-pass final review logs `"facts→briefed"`.
- `outcome: "spec-retry"` means the lane failed once and got a corrected spec; put the one-line cause of the spec gap in `note`. `"escalated"` means it moved to `fable-implementer`; `"failover"` means quota/availability re-routing (name the direction in `note`).
- `attempts` counts spec submissions to the final lane; `duration_s` is a rough wall-clock estimate, not a stopwatch reading.

Append with a plain shell redirect — no jq, no wrapper script:

```bash
echo '{"ts":"2026-08-01T10:00:00+09:00","task":"add retry to sync client","class":"implement","lane":"codex-implementer","exception":null,"ctx":"facts","outcome":"success","attempts":1,"duration_s":180,"note":""}' >> ~/.claude/fable-advisor/routing.jsonl
```

Logging is part of finishing the task, not optional telemetry — an unlogged delegation is invisible to the next retro. But keep it to one line per outcome; the ledger records decisions, not narration.

## Calibration: when to retire the two-pass review

The two-pass review and the silence gap earn their cost only if anchoring actually happens. Decide that from the ledger, not from impression — and decide it on a date, or the machinery outlives its justification by default.

Count only **substantive deliverables**: a diff touching three or more files, or any non-trivial logic change. A one-line fix can never produce an anchoring event and must not dilute the sample.

A final review logs one line, with the review-specific counters in place of `duration_s` detail:

```json
{"ts":"…","task":"…","class":"review","lane":"fable-advisor","exception":4,"ctx":"facts→briefed","outcome":"success","attempts":1,"duration_s":120,"note":"p1=4 killed_ev=1 killed_assert=0 gap=3 gap_hit=1 verdict_changed=no"}
```

- `p1` — findings returned by pass 1
- `killed_ev` — pass-1 findings withdrawn against named evidence
- `killed_assert` — pass-1 findings the advisor tried to withdraw on the implementer's word alone. **This is the anchoring event.** Any non-zero value is the mechanism catching exactly what it exists for
- `gap` / `gap_hit` — silence gap size, and how many real defects were found inside it
- `verdict_changed` — whether pass 2 moved ship / fix-first / rethink

**Review at 10 substantive deliverables or 2026-09-30, whichever comes first.**

Two-pass review — read the two kill columns together, not separately:

| `killed_ev` | `killed_assert` | Read as | Action |
|---|---|---|---|
| ~0 | 0 | Pass 2 changes nothing in either direction | **Retire it.** Collapse to a single `facts` pass — note the collapse is to facts-only, *not* back to a briefed single pass: zero on both columns means the claims were not informative either |
| >0 | 0 | The claims are honest and useful; pass 2 is killing false positives | Keep — it is paying for itself in reviewer precision |
| any | >0 | Anchoring is real and was caught | Keep, and stop re-litigating this |

Silence gap — an empty gap and a noisy gap both argue for retirement, but they have different fixes:

| Observation over 10 | Read as | Action |
|---|---|---|
| Gap nearly always empty | Implementers already cover their own blast radius | Retire the computation; the reports are doing the job |
| Gap large, `gap_hit` stays 0 | The impact query is producing noise, not attention | Tighten the query first; retire only if a tighter query still finds nothing |
| `gap_hit` > 0 even occasionally | It is finding what summaries hide | Keep — it is the cheaper half of the mechanism |

If both retire, one thing survives and costs nothing to follow: implementers get `facts`; judges get the target and the criterion and never the process.
