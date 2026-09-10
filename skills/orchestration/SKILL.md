---
name: orchestration
description: How this session decides between doing the work itself, handing it to a cross-vendor implementation lane, and getting an independent review. USE WHEN deciding whether a task is worth delegating, writing a spec for a subagent, choosing a lane, handling a codex quota failure or wall-clock timeout, or deciding whether a deliverable needs an independent review before you report done.
---

# Orchestration

You implement by default. You are the most capable model in this system and you
already hold the conversation state; moving work out of the session costs a spec,
a round trip, and a re-verification. Delegate when the delegation itself buys
something you cannot get by typing the code yourself.

## The four reasons to delegate

Name one before you spawn. If you cannot name one, do the work.

1. **Cross-vendor independence.** You want the answer from a different model
   family — a second implementation to compare, or a reviewer who did not write
   the code.
2. **Quota distribution.** The work is large and mechanical and the ChatGPT side
   can absorb it, saving Claude quota for judgment.
3. **Isolation or parallelism.** Several independent pieces can run at once, or
   the work would flood this session with output you do not need to see.
4. **Stronger review.** The deliverable is risky enough that a fresh reader is
   worth a round trip. See *Review*.

"It felt like it should be delegated" is not a reason. Neither is habit.

## The lanes

| Lane | Model | Use for |
|---|---|---|
| `codex-implementer` | GPT via `codex exec` | Cross-vendor implementation and quota distribution. Well-specified work whose outcome a spec fully determines. |
| `implementer` | you choose per spawn: `haiku`, `sonnet`, or `fable` | Claude-side implementation you want out of this session — bulk mechanical edits (`haiku`), the codex quota failover target (`sonnet`), judgment-heavy one-offs (`fable`). |
| `fable-advisor` | Fable 5 | Independent review and second opinions. Advises only — it holds no write tools. |

Set the model on the spawn itself; it outranks the agent file's frontmatter.
One implementer file, three depths — do not add per-model agent files.

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
| Codex unavailable, rate-limited, or quota-exhausted | Implementation moves: respawn as `implementer` with `model: sonnet`. |
| Codex ran out of wall clock with work in progress | Do **not** move lanes. Respawn the same lane with a `RESUME` block naming what landed and what remains. |
| Codex cannot reach a tool or a verification target | Run that one operation yourself, hand the result back, and let the lane keep the implementation. A capability gap is not a change of owner. |
| Same task failed twice in the same lane | Stop retrying. Either implement it yourself or escalate to `implementer` with `model: fable`. |

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
| One file, mechanical, verified by a passing command | None. Your own verification is the review. |
| Ordinary feature or fix | Your own verification, plus a re-read of the diff. |
| Wide blast radius, security-sensitive, data migration, API or schema change, concurrency | `fable-advisor`. |
| Irreversible, or you and a lane disagree | `fable-advisor`, and consider a second independent implementation to compare. |

Also consult it *before* committing to an architectural decision you would find
expensive to reverse, and whenever the same problem has resisted two attempts.

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

## Ledger (optional)

One JSON line per routing decision, appended to
`~/.claude/fable-advisor/routing.jsonl`:

```json
{"ts":"<iso8601>","task":"<short>","class":"implement|review|explore|commit","lane":"<lane>","reason":"<one of the four, or 'self'>","outcome":"success|retry|failover|blocked","attempts":1,"duration_s":0,"note":"<what you learned>"}
```

Its only purpose is to let you answer "is this routing policy actually working?"
with numbers instead of impressions. If you are not going to read it, do not
write it.
