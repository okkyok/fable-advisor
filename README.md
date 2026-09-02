# Fable Advisor

**Opus runs the show. Cheaper typing, smarter escalation, and a tiered review gate before anything ships.**

Claude Code lets every subagent run on a different model — and lets the session itself run on a different model than its subagents. This plugin exploits that with the **architect pattern**: your session runs on **Opus**, acting as a full-time architect. It owns requirements, decomposition, specs, and verification — routes every implementation task to the right lane — and gates finished work with architect verification plus a fresh-context Codex review, escalating to Fable only on named triggers:

| Lane | Producer | Invocation | Route here when |
|---|---|---|---|
| Routine | **GPT-5.6 Luna** (reasoning effort by task class) | `codex-implementer` agent (default) | The spec fully determines the outcome — Codex does the typing via the [Codex CLI](https://github.com/openai/codex) |
| High-complexity | **Fable 5** | `fable-implementer` agent | One-off tasks where judgment the spec can't capture decides the outcome: subtle concurrency, hard debugging, security-sensitive paths, wide refactors |
| Tool bridge | **Claude Haiku 4.5** (`model: sonnet` for multi-step work) | `tool-bridge` agent | An implementer hit a capability it cannot reach — MCP, a browser, the simulator, an OAuth'd connector, or a verification its sandbox cannot run. The bridge performs **only** the tool operation and returns a short structured result; the implementer resumes and keeps the code |
| Review | **GPT-5.6 Luna (Tier 1); Fable 5 (Tier 2)** | `codex-implementer` (Tier 1) or `fable-advisor` (Tier 2) | Tier 1 is the default gate for every deliverable; Tier 2 is the triggered Fable review — `deadlock`, `irreversible`, or `user-request` only |

Tokens route by capability: Opus emits judgment and specs, the cheap cross-vendor lane emits the bulk of the code, and Fable — the most expensive model available — is spent only where it changes outcomes: the hardest implementations and triggered Tier 2 reviews. Because the routine lane is a *different model family* than the architect, the architect's verification is the cross-vendor check. Tier 1's Codex reviewer shares a model family with the Codex implementer that produced the diff: it is a fresh-context check, not a cross-family one. For high-stakes work, run `codex-implementer` and `fable-implementer` on the same spec and let the architect pick the stronger diff.

The plugin ships the **orchestration skill** — the routing doctrine that teaches the session when to use each lane, the cost discipline that keeps expensive-model token volume minimal (emit judgment not volume, keep context lean, reason once then hand off), the five-part spec contract that makes context-free delegation safe, the context inheritance grades that decide what a receiving agent may and may not be told, and the verification rules that keep every lane honest.

## Install

```
claude plugin marketplace add DannyMac180/fable-advisor
claude plugin install fable-advisor@fable-advisor
```

Updating an existing installation to the latest release:

```
claude plugin marketplace update fable-advisor
claude plugin update fable-advisor@fable-advisor
```

Then start your session as the architect:

```
/model opus
```

**Lite mode — one file, 30 seconds.** Don't want the full pattern? Copy [`agents/fable-advisor.md`](agents/fable-advisor.md) into `~/.claude/agents/` and keep your session on Sonnet. You get advisor consults at commitment boundaries without the orchestration layer (see "Advisor-only mode" below).

## Requirements

- **Claude Code ≥ 2.1.170** with a subscription that includes Fable 5 (Pro, Max, Team, or Enterprise — all current consumer plans qualify).
- **No Fable access** (e.g. API-key billing)? Change `model: fable` → `model: opus` in the advisor and implementer files. Same pattern, the Fable roles shift down to Opus.
- **Codex lane (the default implementer):** the `codex-implementer` agent needs the [OpenAI Codex CLI](https://github.com/openai/codex) installed and authenticated (`npm i -g @openai/codex`, then `codex login`). It invokes **GPT-5.6 Luna** as `gpt-5.6-luna`, with `model_reasoning_effort` set per task class by the caller — `high` by default, `low`/`medium` for trivial or search-shaped work, and `max` only under the named conditions in the orchestration skill. GPT-5.6 access may be limited during preview; without model access, an installed/authenticated CLI, or successful authentication, the agent reports `STATUS: unavailable` — it never silently falls back to a Claude model — and the Fable lanes remain unaffected.
- Heads-up: if a pinned Claude model isn't available on your account, Claude Code silently falls back to your session model — the pattern degrades quietly rather than erroring. If results feel unremarkable, check your plan. (This quiet fallback applies only to Claude model pins — the codex lane always fails loudly with a structured error.)

Model resolution order in Claude Code: `CLAUDE_CODE_SUBAGENT_MODEL` env var → per-invocation `model` parameter → agent frontmatter → session model.

## Use it

With the session on Opus, just ask for work — the orchestration skill routes it:

```
Add rate limiting to our public API. Design it, delegate the
implementation, and verify the evidence before you call it done.
```

The architect writes the spec, picks the lane (rate limiting touches concurrency — a good case for `fable-implementer`, or for racing it against `codex-implementer` and picking the stronger diff), reads the diff and verification evidence when the report comes back, sends every deliverable through the Tier 1 `codex-implementer` review, escalates to `fable-advisor` only when a Tier 2 trigger fires, and then reports done.

To make the doctrine always-on, add one line to your project's `CLAUDE.md`:

```
You are the architect — minimize your own token volume. Delegate all
implementation through the orchestration skill's routing table (never
type code yourself), delegate broad codebase exploration to cheap
read-only agents, verify evidence before accepting any lane's report,
and get every deliverable through the Tier 1 gate, escalating to `fable-advisor` only on a Tier 2 trigger before reporting done.
```

## Commitment boundaries and review tiers

Even the architect gets a second opinion. The `fable-advisor` agent is a read-only skeptic — consulted before architecture decisions, migrations, API designs, and whenever a problem has resisted two attempts. Its Tier 2 end-of-deliverable review runs only on one named trigger and reads the accumulated diff against the stated goal rather than the conversation, returning ship / fix-first / rethink. It never implements.

**Tier 1 — the default gate, every deliverable.** The architect reads the diff and re-runs the verification command, then sends a fresh-context `review`-class task to `codex-implementer`. The codex reviewer shares a model family with the codex implementer that produced the diff, so this is a fresh-context check, not a cross-family one. The architect's own verification is the cross-vendor element at this tier.

**Tier 2 — `fable-advisor`, only on one of three triggers.**

- `deadlock` — the same problem has resisted two distinct attempts, a Tier 1 review finding has survived two fix cycles, or a finding has reappeared after being fixed.
- `irreversible` — a data migration, a public API or schema shape, an auth / billing / permission boundary, or a destructive operation. Not every commitment boundary; only what cannot be undone.
- `user-request` — the user asked for it.

These are deliberately the same three trigger names `sol-advisor`'s Challenger uses for calling Claude from the Codex side. The symmetry is the point: codex is the house; Claude is outside counsel. Never use Tier 2 for a routine feature, a deliverable whose Tier 1 review passed, or one more opinion for comfort. The commitment-boundary consult remains condition-triggered; it is not an end-of-deliverable requirement.

When Tier 2 fires, the Fable review runs in **two passes**, because a reviewer that inherits the implementer's framing inherits its blind spots. Pass 1 is `facts` grade: the diff, the goal, the constraints, and a *silence gap* — files structurally inside the blast radius that nobody's report mentions — and it returns numbered findings. Pass 2 hands over the implementer's claims as a list of assertions to falsify, and a finding may only be withdrawn against named file:line evidence. Independence comes from the ordering, not from starving the reviewer: the clean read is on the record before the claims arrive. The doctrine ships with dated retreat conditions so the second pass can be retired on ledger evidence if anchoring never shows up.

## Advisor-only mode (the original pattern)

The minimal arrangement, for when you'd rather skip the orchestration layer: run the session on Sonnet and consult `fable-advisor` only at commitment boundaries.

```
Migrate our checkout sessions from Postgres to Redis — plan it,
consult your advisor before committing, then implement.
```

A typical consult costs cents. To make it automatic, add to your project's `CLAUDE.md`:

```
Before committing to any architecture decision, migration, or refactor
touching 3+ files, consult the fable-advisor agent and act on its verdict.
```

## FAQ

**Is this Anthropic's "advisor tool"?** No — that's a server-side API feature. These are plain Claude Code subagents plus a skill: readable, editable, no beta flags.

**Does this work on claude.ai?** No — subagent model routing is Claude Code only (CLI, desktop, VS Code, web).

**Why not just run everything on Fable?** You can. It's excellent. It's also the most expensive lane per token, and most of a session's tokens are orchestration and implementation mechanics that Opus and the codex lane handle at near-parity. Spend the premium where it changes outcomes: the hardest tasks and triggered Tier 2 reviews.

**Upgrading from v3?** v4 restructures the routing: the session architect moves from Fable to **Opus**, the Grok 4.5 lane is **removed**, `codex-implementer` (GPT-5.6 Sol) becomes the default typing lane, and Fable's premium is refocused on the new `fable-implementer` high-complexity lane plus the triggered Tier 2 `fable-advisor` review. If you still want the Grok lane, grab [`grok-implementer.md` from the v3.1 tree](https://github.com/DannyMac180/fable-advisor/blob/b3b50a9/agents/grok-implementer.md).

**Why a GPT lane in a Claude plugin?** Vendor diversity. Models from one family share blind spots; the Claude architect's verification catches what the Codex producer's family misses. Tier 1 adds a fresh-context Codex review, but it shares the implementer's model family rather than providing a cross-family check. Tier 2 brings in Fable only on the named triggers. The architect stays Claude; the routine lane is a producer, and the Tier 1 reviewer is a fresh-context checker.

## Go deeper

I write [**Attention Heads**](https://attentionheads.substack.com/?utm_source=github&utm_medium=readme&utm_campaign=fable-advisor) — deep, evidence-backed writing on AI, cognition, and agentic engineering. The **Agentic Engineering Field Notes** series is where I publish practical advice on the craft of using AI. [Subscribe](https://attentionheads.substack.com/subscribe?utm_source=github&utm_medium=readme&utm_campaign=fable-advisor) to get new posts to your inbox.

## License

MIT
