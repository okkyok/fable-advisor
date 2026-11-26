# Guardrails — read on demand

Read this when a review returns `GUARDRAIL:` lines, before a merge, on the
first task in a repo, when its gate configuration changed, or when asked to
audit it. Not on ordinary tasks.

## Verification tiers: what runs where

CI minutes are scarce (free tiers run out), local runs are free. So the full
suite runs locally before every merge, and CI keeps only what is cheap.

| When | What | Where |
|---|---|---|
| Per task | the spec's Verification, narrow | the lane's acceptance (local) |
| Before every merge | the whole suite — E2E, coverage, browser included — as one command | local, required |
| Every PR | fast checks only | CI |

- **Before a merge you are asked to do:** run the project's full command
  locally first. Merge only on exit 0; otherwise stop and report. Put the
  command, exit status and a few proving lines in the PR body or the report,
  never the whole log. Never run the full suite inside a lane: it is for
  merge time, and a lane has ~10 minutes.
- **What stays in CI:** only checks that are all of: they protect main, they
  are fast, they are deterministic without external services or secrets, and
  they are easy to skip locally (typecheck, lint, unit tests, a cheap secret
  scan). Anything else is merge-time local, scheduled, manual, or limited to
  the paths it concerns.
- **Budget:** runs per month ≈ free minutes × 0.5 ÷ minutes per run; the other
  half is headroom for re-runs. Read the free minutes from the provider's
  billing page, never from memory: plans change and multipliers differ by OS.
  Trigger on PRs to the main branch, cancel superseded runs, skip docs-only
  changes, cache dependencies, use the cheapest runner, and keep one required
  job.
- **CI calls the light command; it never has its own steps**, so passing it
  locally means CI passes.
- **A check absent from CI is not a missing gate** when the tiers list it as
  local. Follow the tiers. A local-only check touching an area the change
  covers is `verification_required` for the lane.
- **Limit:** a local merge check cannot be enforced the way branch protection
  is; it rests on this rule and its record. Suggest a pre-push hook or a small
  merge script in the project that runs the full command, so skipping it takes
  effort.

The project declares its tiers in `AGENTS.md` / `CLAUDE.md`:

```markdown
## Verification tiers
- Before every merge (local, required): <full command>
- CI on every PR (fast only): <light command>
- Per task: the spec's Verification (narrow)
```

If a repo has none, work as before and, on the first task there, propose tiers
from its existing CI and scripts with an estimated minutes-per-month figure.
Never write them into the repo unasked.

## The project's own guardrails

Find what the repo already enforces before writing a spec that relies on it:
`AGENTS.md` / `CLAUDE.md`, package scripts / `Makefile` / `Taskfile`, CI
workflows, lint/type/test/coverage config, DB constraints and migration
checks, architecture rules, a feature map, project skills. Use them as the
spec's Verification and Constraints; do not invent a parallel check.

- A CI file is not proof CI runs or blocks a merge. Branch protection and
  required checks live outside the repo: record them as `unknown` unless you
  can read them.
- Keep the findings in auto-memory with the commit that last touched the files
  you read (`git log -1 --format=%h -- <those files>`). Re-audit only when that
  changes.
- Paths whose change should always get an independent review (an auth route
  inventory test, RLS policies, a contract file) go in a `.fable-gates` file at
  the repo root, one glob per line. Suggest it to the user; it is their repo.
- If the project requires verification for a kind of change, route it with
  `verification_required: true`.

## Choosing the verification

Prefer the project's own command at the narrowest scope that proves the
objective: a unit or API test, then integration, then a browser run
(Playwright) or an E2E script, against test data and fakes or sandboxes the
project provides. Startup, seed and teardown belong in a project script, not
the spec. Never production, real payments, customer data or real email.
Return the exit status and the lines that prove it, not whole logs or
screenshots. A check that cannot fit the lane's ~10 minutes is split at an
independently verifiable point; a check that cannot run is `not_run` or
`infra_error`, and is reported as unverified.

## A feature map, if the repo has one

Read only the entry for the feature at hand — its files, routes, tables, tests,
spec section, invariants — and use it for Files, the silence gap and the
Verification. If the repo has none, propose one only when the same exploration
keeps recurring, changes keep missing a sibling file, or autonomous UI/API
checks need the operation steps. Never generate one unasked.

## Turning a `GUARDRAIL:` into prevention

Prefer, in order, whatever is surest and cheapest to keep: an existing type, DB
constraint or shared helper; an existing lint or static check; a regression or
invariant test; an architecture rule; CI or permissions; a verification script;
documentation or a prompt last.

- Small and inside the current task's scope (one regression test, one lint
  rule) → fold it into the fix-first round.
- Wider (shared infrastructure, a new dependency, several modules) → tell the
  user and route it as its own task. It never delays the task that found it.
- Record the count: `fable-route.py outcome ... --guardrails N`.

## What this plugin guarantees, and what it cannot

The lane, apply and router checks make the honest path the short one: an
unverified, stale or partial result is never reported as a pass, and quality-gate
changes get an independent review. They are not a security boundary — anyone
with a shell can copy files or edit the scripts. Gates that must hold go in the
repository: required CI checks, branch protection, CODEOWNERS.
