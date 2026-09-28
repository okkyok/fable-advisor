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

# --- Codex lane (permanent; independent of Jev) --------------------------------
# Routes (policy 5.4.0, scripts/fable-route.py): luna_low = default model at low,
# luna_high = default model at FABLE_CODEX_DEFAULT_EFFORT, luna_max = default
# model at max (a narrow retry after one failure, never a default), sol_high =
# strong model at high. claude_opus_high is Claude-side (implementer, model:
# opus, effort pinned high in agents/implementer.md) and is not configured here.
: "${FABLE_CODEX_DEFAULT_MODEL:=gpt-6-luna}"   # default implementation model (luna_* routes)
: "${FABLE_CODEX_DEFAULT_EFFORT:=high}"        # the luna_high effort; keep high — max is luna_max, not a default
: "${FABLE_CODEX_STRONG_MODEL:=gpt-6-sol}"     # the sol_high route: broad, integration-heavy work

# --- Routing ledger (permanent) ------------------------------------------------
: "${FABLE_LEDGER:=$HOME/.claude/fable-advisor/routing.jsonl}"   # "off" disables writing

# --- Jev adaptive routing (optional; removable) ---------------------------------
: "${FABLE_JEV_MODE:=shadow}"                  # off | shadow | active
: "${FABLE_JEV_MIN_CONFIDENCE:=0.80}"          # below this, active mode uses the deterministic route
: "${FABLE_JEV_TIMEOUT:=8}"                    # seconds; a slower Jev is a fallback, not a wait
: "${FABLE_JEV_BACKEND:=auto}"                 # auto | semdecide | jev-cli

export FABLE_CODEX_DEFAULT_MODEL FABLE_CODEX_DEFAULT_EFFORT FABLE_CODEX_STRONG_MODEL \
       FABLE_LEDGER FABLE_JEV_MODE FABLE_JEV_MIN_CONFIDENCE FABLE_JEV_TIMEOUT FABLE_JEV_BACKEND
