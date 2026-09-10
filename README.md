# fable-advisor

A small control plane for delegation in Claude Code.

Your session implements by default. It delegates only when the delegation itself
buys something: cross-vendor independence, ChatGPT-quota distribution, isolation
or parallelism, or a stronger review. Reviews are sized to blast radius rather
than applied to everything.

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
| `agents/fable-advisor` | Read-only reviewer and second opinion (Fable 5). Holds no write tools, so "advises only" is mechanical rather than aspirational. |

## The routing policy in one paragraph

Name one of four reasons before you spawn — cross-vendor independence, quota
distribution, isolation/parallelism, stronger review — or do the work yourself.
Write a five-part spec (objective, files, interfaces, constraints, verification);
anything you leave out, the lane invents. Codex quota exhaustion moves the
implementation to `implementer` with `model: sonnet`; a codex *timeout* does not
move lanes, it resumes the same one. A capability the lane cannot reach is a
one-off tool operation you run for it, not a transfer of ownership. Review in
proportion to blast radius, and before reviewing, compute the *silence gap* —
what the change should have touched minus what it did — because a diff shows
what changed and never what should have changed and didn't.

## 5.0.0

Rebuilt around measured behaviour rather than the original doctrine. Over 1,065
logged routing decisions on the author's machine, the previous "delegate to Codex
by default" policy produced a 60.8% success rate against 92.5% for the same class
of work done in-session, at the same median wall clock, with a 27% wasted-retry
overhead against 3%. The default is now inverted.

**Breaking.** `fable-implementer`, `failover-implementer` and `claude-committer`
are merged into `implementer` — they differed only by `model:`, and Claude Code
resolves a per-spawn `model` parameter ahead of agent frontmatter. `tool-bridge`
is removed: over five weeks it was used 4 times against 47 cases of the situation
it existed to prevent, so it was doctrine that did not describe reality.

**Also.** The orchestration skill drops from 39.8 KB to ~7 KB — the routing
matrix, the four reasons, the failure table, the spec contract, the silence gap
and the two-pass review survive; the cost-discipline preamble, effort-selection
ceremony, context-inheritance grades, mandatory ledger prose and two
self-referential calibration sections do not. The codex preflight no longer uses
`codex --version`, which hangs on some builds and made a healthy install look
unavailable.

## License

MIT. See [LICENSE](LICENSE).
