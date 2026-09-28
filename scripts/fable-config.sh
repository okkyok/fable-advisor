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
# Route ids (luna_high, sol_high, ...) are stable; the models behind them are
# set here, so a model update is a config change, never a prompt edit.
# Codex routes (scripts/fable-route.py): luna_low = default model at low,
# luna_high = default model at FABLE_CODEX_DEFAULT_EFFORT, luna_max = default
# model at max (a narrow retry, never a default), sol_high = strong model at high.
: "${FABLE_CODEX_DEFAULT_MODEL:=gpt-6-luna}"   # default worker (luna_* routes)
: "${FABLE_CODEX_DEFAULT_EFFORT:=high}"        # the luna_high effort; keep high — max is luna_max, not a default
: "${FABLE_CODEX_STRONG_MODEL:=gpt-6-sol}"     # broad worker (sol_high)
# Claude-side roles: the value passed as the Agent tool's `model` on the spawn.
# Their effort is NOT set here: the Agent tool takes no effort and no env var
# sets a subagent's effort, so it is the `effort:` pin in agents/implementer.md
# and agents/opus-reviewer.md. The router reads those pins into the ledger, so
# switching high -> medium is one line there and the report compares both.
: "${FABLE_SENIOR_MODEL:=opus}"                # senior worker (claude_opus_high) and senior reviewer (opus_review)
: "${FABLE_FRONTIER_MODEL:=fable}"             # frontier advisor (consult_first, fable_review)

# --- Routing ledger (permanent) ------------------------------------------------
: "${FABLE_LEDGER:=$HOME/.claude/fable-advisor/routing.jsonl}"   # "off" disables writing

# --- Jev adaptive routing (optional; removable) ---------------------------------
: "${FABLE_JEV_MODE:=shadow}"                  # off | shadow | active
: "${FABLE_JEV_MIN_CONFIDENCE:=0.80}"          # below this, active mode uses the deterministic route
: "${FABLE_JEV_TIMEOUT:=8}"                    # seconds; a slower Jev is a fallback, not a wait
: "${FABLE_JEV_BACKEND:=auto}"                 # auto | semdecide | jev-cli

export FABLE_CODEX_DEFAULT_MODEL FABLE_CODEX_DEFAULT_EFFORT FABLE_CODEX_STRONG_MODEL \
       FABLE_SENIOR_MODEL FABLE_FRONTIER_MODEL \
       FABLE_LEDGER FABLE_JEV_MODE FABLE_JEV_MIN_CONFIDENCE FABLE_JEV_TIMEOUT FABLE_JEV_BACKEND
