---
name: orchestration
description: Routing doctrine for the architect-as-orchestrator pattern — how an Opus session delegates routine implementation to a cheaper cross-vendor lane, escalates high-complexity one-offs to Fable, and gates every deliverable with architect verification plus a fresh-context Codex review, escalating to the Fable advisor only on named triggers. Codex is the default lane; work stays Claude-side only under five named exceptions. USE WHEN delegating implementation work, classifying a task as commit/implement/explore/ingest/review/hardest, deciding whether something is worth a codex round trip or should stay in-session, choosing between codex-implementer/fable-implementer/claude-committer lanes, setting the codex reasoning effort for a task, writing a spec for a subagent, deciding whether to consult fable-advisor, handling a codex quota or rate-limit failover, handling a lane that reports `need_tool` or hits a capability it cannot reach (MCP, browser, simulator, an OAuth'd service, or a verification its sandbox cannot run), managing session cost or token spend, or running any multi-task build where the session is the architect.
---

# Orchestration — the architect's routing doctrine

The session is the architect: it owns requirements, architecture, decomposition, specs, routing, and verification. It should almost never type implementation code. Every implementation task gets routed to the cheapest lane that is adequate for it — escalation to Fable is deliberate, per task, never a fixed binding — and every finished deliverable passes a Tier 1 gate: the architect verifies it and `codex-implementer` reviews it in a fresh context. Tier 2 sends it to Fable only on named triggers.

## Cost discipline — the prime directive

The economics of this pattern: Opus orchestrates (judgment-heavy, volume-light), GPT-5.6 Luna does the routine typing (volume-heavy, cheap, cross-vendor), and Fable — the most expensive model available — is spent only where it changes outcomes: the hardest one-off implementations and a triggered final review. Three rules follow.

**Emit judgment, not volume.** The architect's output is decomposition, specs, routing decisions, verdicts on diffs, and short reports. It does not type implementation code, test bodies, boilerplate, or config files. A code block longer than an interface signature or a few illustrative lines is a spec that hasn't been delegated yet — stop and delegate it. Fixing a lane's bug by hand is the same failure in disguise: send a corrected spec back to the lane instead.

**Keep the context lean.** Everything in the architect's context is re-read at architect prices on every turn. Delegate broad exploration, codebase searches, and log-grepping to a cheap read-only agent and keep only the conclusions; read files yourself only when the decision genuinely depends on the exact code. Don't paste long files, full diffs, or verbose command output into the conversation when a path reference or an excerpt will do.

**Reason once, then hand off.** Do the hard thinking — the architecture, the interface design, the debugging hypothesis — in one pass, capture it in the spec, and let the lane carry it from there. Re-deriving decisions across turns burns the premium twice.

What stays with the architect regardless of cost: decomposition, interface design, hypothesis selection when debugging, spec writing, lane routing, and judging verification evidence. Those tokens are what the premium is for — everything else is a candidate for delegation.

## The lanes

| Lane | Producer | Invoke | Route here when |
|---|---|---|---|
| Routine | GPT-5.6 Luna (reasoning effort by task class — see Codex lane effort) | `codex-implementer` agent | The spec fully determines the outcome: boilerplate, wiring, CRUD, mechanical edits, straightforward features. **Default lane.** Requires the codex CLI. |
| High-complexity | Fable 5 | `fable-implementer` agent | The outcome depends heavily on judgment the spec can't capture: subtle concurrency, non-trivial algorithms, security-sensitive paths, hard debugging, wide-blast-radius refactors — or the routine lane has already failed the task once. One-off escalations, never the default. |
| Floor | Claude Haiku 4.5 | `claude-committer` agent | Mechanical, fully-determined edits below the codex spawn floor but too repetitive for the architect's own context: bulk renames, import fixes, applying one known pattern across many files. Nothing that requires a decision. |
| Failover | Claude Sonnet 5, `effort: high` pinned | `failover-implementer` agent | Not selected by task class — the sole fixed target when codex itself returns `unavailable`, `timeout`, rate-limit, or quota-exhausted. Never `claude-committer`, never `fable-implementer`. See Quota failover below. |
| Tool bridge | Claude Haiku 4.5 (`model: sonnet` for multi-step work) | `tool-bridge` agent | Not an implementation lane. A lane hit a capability it cannot reach — MCP, browser control, the simulator, an OAuth'd connector, image inspection, or a verification its sandbox cannot run. The bridge performs the tool operation only; the lane that asked resumes. See The tool handoff below. |
| Review | GPT-5.6 Luna (Tier 1); Fable 5 (Tier 2) | `codex-implementer` (Tier 1) or `fable-advisor` (Tier 2) | Not an implementation lane. Tier 1 is the default gate for every deliverable; Tier 2 is the triggered Fable review — see below. |

Deciding rule: how much does the outcome depend on judgment the spec can't capture? Little → the default codex lane; you will verify anyway. A lot, and mistakes are costly → escalate to `fable-implementer`, or keep that piece with the architect. A routine-lane task that fails its spec once gets a corrected spec; twice, it escalates to Fable — repetition is evidence the task was misclassified.

The codex lane is cross-vendor from the Claude architect. In Tier 1, the codex reviewer shares a model family with the codex implementer that produced the diff, so it is a fresh-context check, not a cross-family one. The architect's own diff read and verification are the cross-vendor element at this tier. Tier 2 adds Fable only when a named trigger fires.

If the codex lane returns `unavailable` or `timeout`, re-route the same spec to `failover-implementer` — see Quota failover below for why this is a fixed, pinned-effort target rather than the class-dependent Fable escalation — and say so explicitly in your report; never quietly absorb the substitution or the cost change.

## Task classes and the Claude-side exceptions

This session runs a Claude subscription and a ChatGPT subscription side by side, and the Claude side is the scarcer of the two: the architect burns it on every turn just by thinking. So the default is inverted from "use the cheap lane when it obviously wins" to **codex by default; keep work on the Claude side only when Claude obviously wins**. Classify each task, then check the exceptions — the classification is a label, not a permission to skip the check.

| Class | What it is | Default |
|---|---|---|
| `commit` | Trivial edits: typo, one-line fix, version bump, config value | codex — unless exception 2 |
| `implement` | Code that a complete spec fully determines | codex (`codex-implementer`) |
| `explore` | Open-ended search: where does X live, how does Y work | codex — unless exception 1 or 2 |
| `ingest` | Reading long material: logs, dumps, docs, transcripts | codex. Never route here for context economy reasons alone — high token volume is exactly what the ChatGPT side is for |
| `review` | Adversarial checking of a diff or design | Tier 1: fresh-context `codex-implementer` review by default; Tier 2: `fable-advisor` only on `deadlock`, `irreversible`, or `user-request` |
| `hardest` | Judgment-dominated work, or a task the routine lane already failed twice | `fable-implementer` — the one class that is Claude-side by default |

### Codex lane effort

The codex lane ran pinned at `max` until 2026-08-10. The ledger never showed that pin preventing a failure: across 59 successful `implement` runs and 6 spec-retries, the retries traced to spec gaps, sandbox reach, and one procedural miss — not one of them to reasoning depth. A depth setting that costs latency on every call and has no measured save is not a default — so effort is now set per class, and `max` has to be earned.

| Class | Effort | Why |
|---|---|---|
| `implement` | `high` | The default. The spec determines the outcome and the architect verifies afterwards; depth past `high` buys wall clock, not correctness |
| `implement`, exceptional | `max` | Only when one holds: **(a)** the change spans three or more files, **(b)** the spec leaves a *local* shape to the lane — an internal helper's signature, an error type — or **(c)** it is the retry attempt itself (`attempts` = 2) after a `spec-retry` |
| `commit` | `low` | The spec names the change literally. Rare in this lane anyway — exception 2 keeps almost all of this class in-session |
| `explore` | `medium` | The output is a location report, and the architect can check it against the tree cheaply |
| `ingest` | `medium` | The failure mode is missing something. That is context coverage, and reasoning depth does not fix it |

Any class not listed — a Tier 1 `review` sent to `codex-implementer` for a fresh-context read — takes the default `high`.

(b) is not a licence to defer design. A public API shape, a schema, or a cross-module boundary stays architect work — a spec you couldn't finish is an unmade decision, not a `max` task. (b) covers only the shapes that are genuinely internal to the change being delegated.

Name the value on an `EFFORT:` line next to the five-part spec; the lane runs `high` when the line is absent. **When you use `max`, name which of (a)/(b)/(c) applies**, in the prompt and in the ledger `note`, the same way a Claude-side exception gets a number. "This one looks hard" is not one of the three.

Calibrate at 20 `implement` runs at `high`: if no spec-retry in that window has reasoning depth as its cause, tighten the `max` conditions further; if two or more do, move the default back up and record which condition was missing.

### The five exceptions — keep it on the Claude side only when one applies

1. **Context-bound.** The task depends on conversation state — decisions made, paths already ruled out, "the thing we just changed". Writing a self-contained five-part spec would cost more than doing the work. Delegating here doesn't save money, it launders context loss into a bad diff.
2. **Below the spawn floor.** A codex round trip on this machine costs **11–25 s before the model does any work at all**, and ~6–9 k tokens for a no-op. If the architect is confident it can finish in about that time, the round trip is pure latency. Measured 2026-08-01 on codex 0.146.0: 11 s (`--ignore-user-config`, low effort), 24 s (user config, high effort), 86 s for a one-line fix end to end.
3. **Judgment-dominated** — the `hardest` class. Subtle concurrency, security-sensitive paths, non-trivial algorithms, or a spec the routine lane has now failed twice. Re-sending a misclassified task to codex is a third failure with extra steps.
4. **The Tier 2 review gate.** `fable-advisor` reads the deliverable with fresh eyes when a named trigger fires. Tier 1 stays with `codex-implementer`; this exception is the Fable escalation.
5. **Claude-only tooling — and it licenses the tool operation, not the implementation.** The work needs MCP servers, browser control, the iOS simulator, an OAuth'd connector, or anything else reachable from this session but not from `codex exec`. Route the tool work to `tool-bridge` and return the result to the lane that asked; the implementation never changes hands. Two things look like this exception and are not:
   - **The harness's subagent policy.** "This session may not spawn agents" is never evidence of a capability gap — and the bridge is itself a subagent, so treating it as exception 5 takes the whole pattern offline in one move. Standing permission from the user does not settle it either, in either direction: the only thing that settles it is an attempted spawn. See **Delegation availability is not a judgment call** below, and log it there — never as exception 5.
   - **Codex sandbox reach.** A service on a local port, a path outside the workspace, a directory that is not a git repo, a live runtime config, or something `--ignore-user-config` removed. That is codex-side configuration, and the fix is in the invocation or in a bridged verification — not in the architect writing the code. See Capability triage.

None of these apply? It goes to codex. "It felt faster to just do it" is exception 2 only if the architect can name the number.

### Delegation availability is not a judgment call

Every exception above assumes the architect *chose* to keep the work. Being unable to delegate at all is not a choice and not an exception — it is a fault, and in this ledger it is the single largest source of in-session implementation. Two rules:

**Attempt the spawn.** A sentence in the harness, a policy remembered from another session, or the absence of an explicit user request is not evidence that delegation is unavailable. The only evidence is an attempted spawn that came back a hard error. Do not infer the answer — call the tool and read what it returns.

**Quote the error.** When a spawn genuinely fails, log `lane: "architect"` with `exception: "delegation-unavailable"` — a string, deliberately not a number, because it does not belong in the same population as the five exceptions and must never dilute their calibration. Put the verbatim error in `note`. An entry that cannot quote an error was an inference, and the next retro reads it as one.

### Missing capability is not a change of owner

> **Missing capability causes a tool handoff, not an implementation handoff.**
>
> **Tool access does not grant implementation ownership.**
>
> **The architect MUST NOT continue implementation merely because the delegated implementer cannot access a required tool.**

This is the exact failure the bridge exists to prevent: codex hits a Claude-only tool, the architect runs the tool because only it can, and — already holding the result — types the rest of the diff. The capability gap was two minutes of tool work; the ownership transfer costs the whole remaining task at architect prices. The same rule binds every other lane: `tool-bridge` does not finish an implementation it unblocked, and `fable-advisor` never stops advising to start writing.

### Capability triage — three questions, in order

Before anything gets bridged, establish that the capability is genuinely unreachable from the implementer. **A codex subprocess that is merely under-configured is not a Claude-only tool.**

1. **Can codex reach it directly?** Check MCP availability, network access, `PATH` and `HOME`, environment variables, CLI credentials, OAuth or session dependence, and sandbox scope — and check whether the lane's own `--ignore-user-config` is what removed the tool. Fix the invocation and the task never leaves the lane. If the task genuinely needs the user's codex config or MCP servers, that is a spec-level decision for the architect, not a bridge.
2. **Can `tool-bridge` do it?** OAuth'd sessions, MCP servers, browser control, the simulator, image inspection — and any verification the codex sandbox cannot run: a local database, a dev server, a browser flow.
3. **Only then, the architect** — and even here the architect performs the tool operation and hands the result back, under the rule above.

### Quota failover

The two subscriptions have independent limits, and codex-by-default means the ChatGPT side is now the one that gets drained first. When codex returns a rate-limit, quota, `unavailable`, or `timeout` error, re-route the same spec to `failover-implementer` — a dedicated agent with `model: sonnet` and `effort: high` pinned in its own frontmatter. That pin is deliberate: this lane's effort is fixed and does not inherit, track, or get pulled up/down by whatever the architect's own session effort is set to (see Architect effort below) — it is always exactly `high`, independent of session state. It is a single fixed target: never a choice between `claude-committer` and `fable-implementer` by task class, and never Fable — Fable stays reserved for deliberate `hardest`-class escalation and a triggered final review. **Say so in the report** — a silent failover turns a routing policy into a cost surprise. If the failover fires more than once in a session, stop and tell the user which side is exhausted; the correct fix is a routing decision, not more retries.

### The tool handoff

A lane that hits an unreachable capability returns `STATUS: need_tool` with a `TOOL REQUEST` block instead of failing, guessing, or handing the task back. The architect judges the request — is it real, or is it triage step 1? — spawns `tool-bridge`, and returns the result to **the same lane**.

```
codex → need_tool → tool-bridge → structured result → codex resumes
```

Two statuses, no more. `need_tool`: the lane can continue once a tool operation is done for it. `blocked`: no available capability finishes this and a decision is needed. Approval is already covered — the codex lane runs `approval_policy="never"` inside a `workspace-write` sandbox, so anything requiring approval surfaces as a refused or failed action and the existing approval rules decide it.

Distinguish the handoff from failover, which looks similar and is not:

| Trigger | Route |
|---|---|
| Codex is unavailable, timed out, rate-limited, quota-exhausted | `failover-implementer` — **implementation moves**. See Quota failover above |
| Codex is fine but cannot reach a tool or a verification target | `tool-bridge` — **only the tool operation moves**; implementation ownership does not |

A tool gap is never a reason to move a task to `failover-implementer`, to `fable-implementer`, or to the architect.

**Resuming.** Do not use `codex exec resume` — it silently re-resolves the model unless `--model` is passed again, so a resumed run can come back from a different model than the one you routed to. Send a fresh invocation whose spec carries six things and nothing else: objective, current progress, the relevant diff and files, the tool result, remaining work, verification. Claude-side tool transcripts do not travel; the bridge's structured result does.

**Verification by proxy.** The commoner shape is not a missing fact but a verification the sandbox cannot run — a local database, a dev server, a browser flow, a visual check on an image. The bridge runs the verification and returns the evidence; a failure goes back to the lane as a corrected spec. The architect *judging* that evidence is verification. The architect *fixing the code* because it already has the evidence in hand is the ownership transfer this section forbids.

**When the bridge fails.** `STATUS: blocked` is a stopping point, not a licence to implement. Options, in order: an alternative capability (a different tool, a different verification path), a reduced scope the lane can finish without it, or escalation to the user. The architect does not quietly start writing the remainder.

### Architect effort

The architect's own session effort is a separate knob from any lane's effort — raising or lowering it never touches `failover-implementer`'s pinned `effort: high`, or any other agent's frontmatter-pinned effort. Default to whatever the session started at (normally `high`). Ask the user to raise it to `xhigh` for one specific high-stakes judgment call, not the whole session, when: the decision is architecturally hard to reverse (schema or API shape, a data-migration design), the exception classification itself is genuinely ambiguous rather than just unfamiliar, or a lane has already failed the same task twice and the architect is about to take it on directly. There is no in-session lever to do this automatically — Claude Code's effort control (`/effort`) is an interactive command the user runs, not something callable from a tool mid-session — so the architect's job is to name the moment and the reason, then drop back to the session default once the call is made.

## The spec contract

Implementers share none of your conversation context. Every delegation prompt carries all five parts:

1. **Objective** — what to build or change, one paragraph
2. **Files** — exact paths to create or modify
3. **Interfaces** — signatures, types, or API shapes the code must match
4. **Constraints** — project conventions, things not to touch
5. **Verification** — the command(s) that prove it works

For the codex lane, one routing line rides alongside the spec — `EFFORT: low|medium|high|max`, per Codex lane effort above. It is not a sixth spec part: the spec says what to build, the effort line says how deep the lane thinks about it.

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
- `fable-advisor` at the Tier 2 final review → `facts` on the first pass, `briefed` only on the reconcile pass (see below)
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

## Commitment boundaries and the review tiers

Consult `fable-advisor` (read-only, verdict in under 300 words) at the moments that decide whether the next hour is wasted:

- Before committing to an architecture, data migration, API shape, or refactor strategy
- Whenever the same problem has resisted two distinct attempts

The end-of-deliverable gate has two tiers:

- **Tier 1 — the default gate, every deliverable.** The architect reads the diff and re-runs the verification command, then sends a fresh-context `review`-class task to `codex-implementer`. The codex reviewer shares a model family with the codex implementer that produced the diff, so this is a fresh-context check, not a cross-family one. The architect's own verification is the cross-vendor element at this tier.
- **Tier 2 — `fable-advisor`, only on one of three triggers.**
  - `deadlock` — the same problem has resisted two distinct attempts, a Tier 1 review finding has survived two fix cycles, or a finding has reappeared after being fixed.
  - `irreversible` — a data migration, a public API or schema shape, an auth / billing / permission boundary, or a destructive operation. Not every commitment boundary; only what cannot be undone.
  - `user-request` — the user asked for it.

These are deliberately the same three trigger names `sol-advisor`'s Challenger uses for calling Claude from the Codex side. The symmetry is the point: codex is the house; Claude is outside counsel.

Never use Tier 2 for a routine feature, a deliverable whose Tier 1 review passed, or one more opinion for comfort. The commitment-boundary consults above stay in place; they already fire on a condition rather than on every deliverable.

Pass it the decision (or, for a Tier 2 review, the diff and the stated goal), the constraints, and the options considered. Act on the verdict or surface the disagreement — never silently ignore it.

One honest caveat about Tier 2: when the deliverable came from `fable-implementer`, the reviewer and the implementer are the same model. The review is still worth it — it reads the diff in a clean context, against the goal rather than the conversation — but it is a fresh-eyes check there, not an independent-model one. When the deliverable came from the codex lane, Tier 2 is genuinely cross-vendor.

### The Tier 2 final review runs in two passes

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

### When the advisor lane is unavailable

A `fable-advisor` spawn that dies on an API error — a safeguard rejection, a quota exhaustion, a rate limit — is a lane failure, not a completed review. Retry once. If it fails the same way, re-spawn the same agent with an explicit `model: opus` override and run the identical pass-1 prompt: the review still happens, it just loses cross-model independence, and that loss belongs in the report. Log `lane: "fable-advisor"`, `outcome: "failover"`, with the verbatim error in `note`.

The option that does not exist is reporting done after a Tier 2 trigger fires but without its review. A gate that could not be spawned is still a gate. If a deliverable with a fired Tier 2 trigger ever ships without that review, the ledger entry is `outcome: "blocked"` and it reads as an incident, not as a completed task. A deliverable with no Tier 2 trigger is not shipping without a gate — it shipped through Tier 1.

## Verification

Reports are claims, not evidence. Before accepting any lane's work: read the diff, and re-run the verification command (or spot-check its quoted output against the working tree). "Should work", "tests should pass", or a report with no command output means the task is not done. A lane that reports a spec gap gets a corrected spec, not a "use your judgment".

## Routing ledger

Every routing decision is a data point for tuning this doctrine — the spawn floor, the exception boundaries, and the failover frequency are all calibrated from it. The architect appends one JSON line to `~/.claude/fable-advisor/routing.jsonl` (outside this public repo — ledger entries contain task details and must never be committed here) at each of these moments:

- a delegated task reaches its final outcome (verified, escalated, or abandoned)
- a task is **kept in-session via an exception** — these entries are what calibrate exceptions 1, 2, and 5
- a failover fires (quota, rate limit, `unavailable`, `timeout`)

Fields:

```json
{"ts":"<ISO8601>","task":"<short label>","class":"commit|implement|explore|ingest|review|hardest","lane":"codex-implementer|fable-implementer|claude-committer|tool-bridge|fable-advisor|architect","exception":null,"ctx":"blind|facts|briefed|full|facts→briefed","effort":"low|medium|high|max","outcome":"success|spec-retry|escalated|failover|blocked|abandoned","attempts":1,"duration_s":90,"note":""}
```

- A `review`-class Tier 1 line uses `lane: "codex-implementer"`; a Tier 2 final-review line uses `lane: "fable-advisor"` with `exception: 4`.
- `lane: "architect"` with `exception: 1–5` records work kept in-session; `duration_s` is the actual time it took, so exception-2 claims are checkable against the spawn floor.
- `exception: "delegation-unavailable"` is the one non-numeric value, and it is not an exception: it records that spawning a lane actually failed, with the verbatim error in `note`. Keep it out of every statistic computed over exceptions 1–5. Audit it by reading `note`: no quoted error means the architect inferred unavailability instead of testing it — the failure mode described in Delegation availability is not a judgment call.
- `lane: "tool-bridge"` records a tool handoff. Put `bridge_model=haiku|sonnet` in `note`, plus `escalated=yes` when a simple-mode run had to be re-spawned in multi-step mode. `class` stays the class of the task that asked — the bridge owns no task of its own. A bridge line never carries `outcome: "escalated"`; that value means implementation moved to `fable-implementer`, which a tool handoff never does. `outcome: "blocked"` means no capability finished it and the decision went upstream. With the bridge in place an `exception: 5` line should become rare: a genuine tool gap now logs a `tool-bridge` line instead of an architect one.
- `effort` is the codex reasoning effort the lane actually ran with, `null` for every non-codex lane. It exists so the next retro can answer the question the old `max` pin was set without: did a `high` run ever fail in a way more depth would have caught?
- `ctx` is the context inheritance grade that was actually passed. A Tier 2 two-pass final review logs `"facts→briefed"`.
- `outcome: "spec-retry"` means the lane failed once and got a corrected spec; put the one-line cause of the spec gap in `note`. `"escalated"` means it moved to `fable-implementer`; `"failover"` means quota/availability re-routing (name the direction in `note`).
- `attempts` counts spec submissions to the final lane; `duration_s` is a rough wall-clock estimate, not a stopwatch reading.

Append with a plain shell redirect — no jq, no wrapper script:

```bash
echo '{"ts":"2026-08-01T10:00:00+09:00","task":"add retry to sync client","class":"implement","lane":"codex-implementer","exception":null,"ctx":"facts","effort":"high","outcome":"success","attempts":1,"duration_s":180,"note":""}' >> ~/.claude/fable-advisor/routing.jsonl
```

Logging is part of finishing the task, not optional telemetry — an unlogged delegation is invisible to the next retro. But keep it to one line per outcome; the ledger records decisions, not narration.

### Calibration: when to split the tool bridge

`tool-bridge` is one agent at two depths — Haiku by default, `model: sonnet` for browser driving, multi-MCP investigation, OAuth'd services, and tool-error recovery. Splitting it into two lanes is a decision for data, not for taste.

**Review at 10 `tool-bridge` lines.** If three or more started in simple mode and had to be re-spawned in multi-step mode, the depth is not obvious at spawn time and the two modes should become two agents. If bridge lines are still in single digits by 2026-09-30, the volume does not justify a second lane either way — and if `exception: 5` architect lines still outnumber bridge lines in that window, the problem was never the lane count: it is that the handoff is not being taken.

## Calibration: when to retire the two-pass review

The two-pass review and the silence gap earn their cost only if anchoring actually happens. Decide that from the ledger, not from impression — and decide it on a date, or the machinery outlives its justification by default.

Count only **substantive Tier 2 reviews**: a Tier 2 review of a diff touching three or more files, or any non-trivial logic change. A one-line fix can never produce an anchoring event and must not dilute the sample.

A Tier 2 final review logs one line, with the review-specific counters in place of `duration_s` detail:

```json
{"ts":"…","task":"…","class":"review","lane":"fable-advisor","exception":4,"ctx":"facts→briefed","effort":null,"outcome":"success","attempts":1,"duration_s":120,"note":"p1=4 killed_ev=1 killed_assert=0 gap=3 gap_hit=1 verdict_changed=no"}
```

- `p1` — findings returned by pass 1
- `killed_ev` — pass-1 findings withdrawn against named evidence
- `killed_assert` — pass-1 findings the advisor tried to withdraw on the implementer's word alone. **This is the anchoring event.** Any non-zero value is the mechanism catching exactly what it exists for
- `gap` / `gap_hit` — silence gap size, and how many real defects were found inside it
- `verdict_changed` — whether pass 2 moved ship / fix-first / rethink
- The `p1=… killed_ev=… killed_assert=… gap=… gap_hit=… verdict_changed=…` note format applies to Tier 2 `fable-advisor` lines; Tier 1 `codex-implementer` review lines use ordinary outcome notes.

**Review at 10 substantive Tier 2 reviews or 2026-09-30, whichever comes first.** Tier 2 triggers are deliberately rare, so this sample may accrue more slowly; the date remains the backstop.

Two-pass review — read the two kill columns together, not separately:

| `killed_ev` | `killed_assert` | Read as | Action |
|---|---|---|---|
| ~0 | 0 | Pass 2 changes nothing in either direction | **Retire it.** Collapse to a single `facts` pass — note the collapse is to facts-only, *not* back to a briefed single pass: zero on both columns means the claims were not informative either |
| >0 | 0 | The claims are honest and useful; pass 2 is killing false positives | Keep — it is paying for itself in reviewer precision |
| any | >0 | Anchoring is real and was caught | Keep, and stop re-litigating this |

Silence gap — an empty gap and a noisy gap both argue for retirement, but they have different fixes:

| Observation over 10 Tier 2 reviews | Read as | Action |
|---|---|---|
| Gap nearly always empty | Implementers already cover their own blast radius | Retire the computation; the reports are doing the job |
| Gap large, `gap_hit` stays 0 | The impact query is producing noise, not attention | Tighten the query first; retire only if a tighter query still finds nothing |
| `gap_hit` > 0 even occasionally | It is finding what summaries hide | Keep — it is the cheaper half of the mechanism |

If both retire, one thing survives and costs nothing to follow: implementers get `facts`; judges get the target and the criterion and never the process.
