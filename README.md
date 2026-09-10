# fable-advisor

A small control plane for delegation in Claude Code.

Implementation goes to the Codex lane by default, because the two subscriptions
are not interchangeable: Claude quota is the scarce resource that your reasoning,
review and integration consume, while the ChatGPT side runs Luna at high/max with
far more headroom. Work stays Claude-side only for one of five named reasons.

Every Codex lane runs in its own disposable git worktree, so a lane cannot reach
the main tree or another lane's tree, scope violations are reported instead of
landing, and undoing a lane is `git worktree remove` rather than a `git checkout`
that takes a co-resident lane's uncommitted work with it. Reviews are sized to
blast radius rather than applied to everything.

This is a fork of [DannyMac180/fable-advisor](https://github.com/DannyMac180/fable-advisor).

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
| `agents/codex-implementer` | Runs `codex exec` (GPT-5.6 Luna). The cross-vendor implementation lane. |
| `agents/implementer` | Claude-side implementation. Depth chosen on the spawn: `model: haiku` / `sonnet` / `fable`. |
| `scripts/codex-lane.sh` | Runs a Codex lane inside an isolated worktree and reports what it touched, including paths outside its spec. |
| `scripts/codex-lane-apply.sh` | Copies only the spec'd paths back into the main tree. Purely additive — never checkout/reset/clean/stash. |
| `scripts/verify-codex-lane.sh` | Self-test: runs a real lane against a scratch repo and asserts a co-resident lane's uncommitted work survives. |
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

## License

MIT. See [LICENSE](LICENSE).
