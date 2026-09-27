# shellcheck shell=bash
# fable-advisor configuration — the one place settings live.
#
# Every value is an environment variable with a safe, backward-compatible
# default. Export a variable to override it; nothing else needs editing.
# Bash sources this file; scripts/fable-route.py reads the same `:=` lines, so
# a default changed here changes it everywhere.
#
# Rolling Jev back is one line:   export FABLE_JEV_MODE=off
# (off is also the default, and off never touches Jev code, binaries or keys.)

# --- Codex lane (permanent; independent of Jev) --------------------------------
: "${FABLE_CODEX_DEFAULT_MODEL:=gpt-6-luna}"   # default implementation model
: "${FABLE_CODEX_DEFAULT_EFFORT:=high}"        # low | medium | high | xhigh | max
: "${FABLE_CODEX_STRONG_MODEL:=gpt-6-sol}"     # the sol_high route: hard but well-specified work

# --- Routing ledger (permanent) ------------------------------------------------
: "${FABLE_LEDGER:=$HOME/.claude/fable-advisor/routing.jsonl}"   # "off" disables writing

# --- Jev adaptive routing (optional; removable) ---------------------------------
: "${FABLE_JEV_MODE:=off}"                     # off | shadow | active
: "${FABLE_JEV_MIN_CONFIDENCE:=0.80}"          # below this, active mode uses the deterministic route
: "${FABLE_JEV_TIMEOUT:=8}"                    # seconds; a slower Jev is a fallback, not a wait
: "${FABLE_JEV_BACKEND:=auto}"                 # auto | semdecide | jev-cli

export FABLE_CODEX_DEFAULT_MODEL FABLE_CODEX_DEFAULT_EFFORT FABLE_CODEX_STRONG_MODEL \
       FABLE_LEDGER FABLE_JEV_MODE FABLE_JEV_MIN_CONFIDENCE FABLE_JEV_TIMEOUT FABLE_JEV_BACKEND
