# shellcheck shell=bash
# fable-advisor configuration — the one place settings live.
#
# Every value is an environment variable with a safe, backward-compatible
# default. Export a variable to override it; nothing else needs editing.
# Bash sources this file; scripts/fable-route.py reads the same `:=` lines, so
# a default changed here changes it everywhere.
#
# Rolling Jev back is one line:   export FABLE_JEV_MODE=off
# (off never touches Jev code, binaries or keys. The default is shadow: Jev is
# asked about the ambiguous middle and only logged, never used; without a Jev
# backend or key each such call is logged as a fallback and routing is unchanged.)

# --- Worker and reviewer models (permanent; independent of Jev) -----------------
# Route ids (terra_low, sol_medium, ...) are stable; the models behind them are
# set here, so a model update is a config change, never a prompt edit.
# Codex routes (scripts/fable-route.py): luna_low = light model at low,
# terra_low = default model at FABLE_CODEX_DEFAULT_EFFORT, terra_medium = deep
# model at medium (a narrow retry, never a default), sol_medium = strong model at
# FABLE_CODEX_STRONG_EFFORT.
: "${FABLE_CODEX_DEFAULT_MODEL:=gpt-6.1-terra}" # default worker (terra_low)
: "${FABLE_CODEX_DEFAULT_EFFORT:=low}"          # the terra_low effort
: "${FABLE_CODEX_LIGHT_MODEL:=gpt-6-luna}"      # mechanical worker (luna_low)
: "${FABLE_CODEX_STRONG_MODEL:=gpt-6.2-sol}"   # broad worker (sol_medium)
: "${FABLE_CODEX_STRONG_EFFORT:=medium}"      # the sol_medium effort
: "${FABLE_CODEX_DEEP_MODEL:=gpt-6.1-terra}"   # deep worker (terra_medium)
: "${FABLE_CODEX_DEEP_EFFORT:=medium}"         # the terra_medium effort
# Claude-side roles: the value passed as the Agent tool's `model` on the spawn.
# Their effort is NOT set here: the Agent tool takes no effort and no env var
# sets a subagent's effort, so it is the `effort:` pin in agents/implementer.md
# and agents/opus-reviewer.md. The router reads those pins into the ledger, so
# switching high -> medium is one line there and the report compares both.
: "${FABLE_SENIOR_MODEL:=opus}"                # senior worker (claude_opus_high) and senior reviewer (opus_review)
: "${FABLE_FRONTIER_MODEL:=claude-fable-5-2}"  # frontier advisor (consult_first, fable_review); pinned in agents/fable-advisor.md too

# --- Routing ledger (permanent) ------------------------------------------------
: "${FABLE_LEDGER:=$HOME/.claude/fable-advisor/routing.jsonl}"   # "off" disables writing

# --- Quality gates (codex-lane.sh) -----------------------------------------------
# A lane path matching these is reported as a quality-gate change and puts the
# review at opus_review: the reviewer tells a real improvement from a weakened
# gate. Generic names only (ERE); a project adds its own globs, one per line, in
# a `.fable-gates` file at its repo root (read from the main tree, not the lane's).
: "${FABLE_GATE_PATHS:=(^|/)(\.github/workflows/|\.gitlab-ci\.yml$|\.circleci/|Jenkinsfile$|\.pre-commit-config\.yaml$|\.fable-gates$|CODEOWNERS$|codecov\.ya?ml$|\.coveragerc$|(jest|vitest|playwright|cypress|karma)\.config\.[cm]?[jt]s$|pytest\.ini$|tox\.ini$|conftest\.py$|\.eslintrc|eslint\.config\.|biome\.jsonc?$|tsconfig[^/]*\.json$|mypy\.ini$|ruff\.toml$|\.golangci\.ya?ml$)}"
: "${FABLE_TEST_PATHS:=(^|/)(tests?|__tests__|spec)/|[._-](test|spec)\.[A-Za-z]+$}"   # a deleted test, or a skip added to one, is a gate change
: "${FABLE_SKIP_MARKERS:=\.(skip|only)\(|(^|[^A-Za-z_.])(xit|xdescribe|xtest)\(|@pytest\.mark\.(skip|xfail)|@unittest\.skip|t\.Skip\(|#\[ignore\]}"

# --- Jev adaptive routing (optional; removable) ---------------------------------
: "${FABLE_JEV_MODE:=shadow}"                  # off | shadow | active
: "${FABLE_JEV_MIN_CONFIDENCE:=0.80}"          # below this, active mode uses the deterministic route
: "${FABLE_JEV_TIMEOUT:=8}"                    # seconds; a slower Jev is a fallback, not a wait
: "${FABLE_JEV_BACKEND:=auto}"                 # auto | semdecide | jev-cli

# --- Imajev-4B shadow comparison (optional; removable; measurement only) -------
# Asks a local Imajev server the same question, with the same state and options,
# at exactly the decisions where Jev is asked, and logs imajev_* beside jev_*.
# There is no active mode: Imajev never changes a route or a review. Off by
# default, so an update never starts connecting to a local server on its own.
: "${FABLE_IMAJEV_MODE:=off}"                  # off | shadow (anything else is off)
: "${FABLE_IMAJEV_URL:=http://127.0.0.1:8765/v1/systemone}"
: "${FABLE_IMAJEV_TIMEOUT:=8}"                 # seconds; same budget as Jev's
: "${FABLE_IMAJEV_MIN_CONFIDENCE:=0.80}"       # only decides imajev_would_accept
: "${FABLE_IMAJEV_EXPERIMENT_TAG:=}"           # free text logged on each row, e.g. mlx-4b-rot4-cal

export FABLE_CODEX_DEFAULT_MODEL FABLE_CODEX_DEFAULT_EFFORT FABLE_CODEX_LIGHT_MODEL \
       FABLE_CODEX_STRONG_MODEL FABLE_CODEX_STRONG_EFFORT \
       FABLE_CODEX_DEEP_MODEL FABLE_CODEX_DEEP_EFFORT \
       FABLE_SENIOR_MODEL FABLE_FRONTIER_MODEL \
       FABLE_LEDGER FABLE_JEV_MODE FABLE_JEV_MIN_CONFIDENCE FABLE_JEV_TIMEOUT FABLE_JEV_BACKEND \
       FABLE_IMAJEV_MODE FABLE_IMAJEV_URL FABLE_IMAJEV_TIMEOUT FABLE_IMAJEV_MIN_CONFIDENCE \
       FABLE_IMAJEV_EXPERIMENT_TAG FABLE_GATE_PATHS FABLE_TEST_PATHS FABLE_SKIP_MARKERS
