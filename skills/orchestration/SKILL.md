---
name: orchestration
description: How this session decides between doing the work itself, handing it to a cross-vendor implementation lane, and getting an independent review. USE WHEN deciding whether a task is worth delegating, writing a spec for a subagent, choosing a lane, handling a codex quota failure or wall-clock timeout, or deciding whether a deliverable needs an independent review before you report done.
---

# Orchestration

**Implementation goes to the codex lane by default.** The two subscriptions are
not interchangeable: Claude quota is the scarce resource and is what your own
reasoning, review and integration consume, while the ChatGPT side runs Luna at
high/max with far more headroom. Every routine implementation you type yourself
spends the scarce budget on the abundant task.

So the question is never "is this worth delegating" — it is "is there a reason
this one cannot go to codex".

## When work stays Claude-side

Five reasons. Name the number when you keep something in-session.

1. **Context-bound.** The task depends on conversation state that a
   self-contained spec would cost more to write down than to act on.
2. **Below the spawn floor.** A round trip costs real seconds and tokens before
   any work happens. Applies when you can name the number, not when it merely
   feels faster.
3. **Judgment-dominated.** The outcome turns on judgment a spec cannot carry, or
   the codex lane has already failed this task twice.
4. **Review.** `fable-advisor` reads the deliverable. See *Review*.
5. **Claude-only tooling** — and it licenses the tool operation, not the
   implementation. Run the tool, hand the result back, let the lane keep the code.

None of these apply? It goes to codex.

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
scripts/codex-lane.sh --spec <specfile> --files "<f1,f2,...>" --effort high
# then, after reading its LANE REPORT:
scripts/codex-lane-apply.sh --worktree <wt> --repo <repo> --files "<f1,f2,...>" --remove
```

Apply only the paths in **Files**. A `SCOPE VIOLATIONS` list is a signal the spec
was under-specified — fix the spec, not the tree.

## The lanes

| Lane | Model | Use for |
|---|---|---|
| `codex-implementer` | Luna via `codex exec` | **The default.** All routine implementation. Runs in its own worktree. |
| `implementer` | per spawn: `haiku`, `sonnet`, `fable` | Claude-side implementation. `sonnet` is the codex quota-failover target; `fable` is for reason 3; `haiku` for bulk mechanical edits worth removing from your context. |
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
| **Codex quota exhausted** | **Stop and report the reset time. Do not silently fail over to Claude.** Failing over spends the scarce subscription at the exact moment the abundant one is unavailable — over five weeks this pattern moved 47 tasks and ~5.8 hours onto the Claude side, none of them because the task needed Claude. Tell the user when codex returns and let them choose: wait, or authorise `implementer` with `model: sonnet`. |
| Codex unavailable for a non-quota reason (auth, broken install) | Report it with the probe output. This is a fix, not a reroute — a retry will fail the same way. |
| Codex ran out of wall clock with work in progress | Do **not** move lanes. Respawn the same lane against **the same worktree** with a `RESUME` block naming what landed and what remains. |
| Codex cannot reach a tool or a verification target | Run that one operation yourself, hand the result back, and let the lane keep the implementation. A capability gap is not a change of owner. |
| `SCOPE VIOLATIONS` in the lane report | The spec was under-specified. Apply only the allowed paths, widen **Files** if the extra paths were genuinely required, and re-issue. Never reconcile it with a checkout on the main tree. |
| Same task failed twice in the same lane | Stop retrying. Reason 3 now applies: escalate to `implementer` with `model: fable`. |

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
write it — but keep it on while the worktree mechanism is new: it is the only
thing that will tell you whether scope violations actually fell, and every
conclusion in the 5.0.0 notes came from reading it rather than guessing.
