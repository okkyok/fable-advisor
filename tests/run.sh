#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2209  # variables are read inside check's eval strings
# Offline test suite: routing policy 5.5.0 (luna_max eligibility, claude_opus_high
# escalation, Fable consult triggers, strict scope), Jev modes and fallbacks,
# review gate (self/opus/fable), ledger and the policy-versioned report,
# backfill, the codex lane's model/effort, expected/strict scope, harness
# acceptance and apply guards, isolation, prompt-surface budgets, and the
# Imajev shadow comparison (same decision as Jev, log-only, every failure).
# Uses stub `codex`, `semdecide` and `jev` binaries and a loopback Imajev stub
# server; needs no external network, no credentials, and no real Codex, Jev or
# Imajev install. Run: tests/run.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
S="$ROOT/scripts"
T=$(mktemp -d "${TMPDIR:-/tmp}/fable-tests.XXXXXX")
IMAJEV_PID=""
trap '[ -z "$IMAJEV_PID" ] || kill "$IMAJEV_PID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT   # KEEP=1 keeps the scratch ledger for inspection
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"   # lane worktrees land inside $T and go with it
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else ng "$1" "${3:-}"; fi; }
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

# --- a PATH with exactly the tools we name: no real codex, jev or semdecide ------
BASE="$T/bin-base"; mkdir -p "$BASE"
for c in bash sh env python3 git dirname basename date mkdir cp find awk grep sed sort tr \
         tail head cmp diff rm cat mktemp ls wc sleep timeout gtimeout touch chmod cut \
         uname readlink tee xargs mv id expr cksum; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$BASE/$c"
done
JEVBIN="$T/bin-jev"; mkdir -p "$JEVBIN"
ln -s "$ROOT/tests/stubs/jevstub" "$JEVBIN/semdecide"
ln -s "$ROOT/tests/stubs/jevstub" "$JEVBIN/jev"
CODEXBIN="$T/bin-codex"; mkdir -p "$CODEXBIN"; ln -s "$ROOT/tests/stubs/codex" "$CODEXBIN/codex"

unset TYPESAFE_API_KEY AI_GATEWAY_API_KEY OPENROUTER_API_KEY JEV_API_KEY JEV_PROVIDER
for v in $(env | sed -n 's/^\(FABLE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"; mkdir -p "$HOME"
export FABLE_LEDGER="$T/ledger.jsonl" STUB_JEV_MARK="$T/jev-called" STUB_JEV_LOG="$T/jev-call.json"

MIDDLE='{"objective":"Add retry handling to payment API","file_count":4,"verification_available":true}'
route() {  # route <mode> <state> [extra args...]; PATH decides whether Jev exists
  local mode=$1 state=$2; shift 2
  printf '%s' "$state" | FABLE_JEV_MODE=$mode python3 "$S/fable-route.py" route "$@" 2>"$T/stderr"
}
reset_jev() { rm -f "$STUB_JEV_MARK" "$STUB_JEV_LOG"; unset STUB_JEV STUB_CHOICE STUB_CONF; }
last_line() { tail -n 1 "$FABLE_LEDGER"; }

echo "Jev off"
PATH="$BASE"
r=$(route off "$MIDDLE")
check "routes with no Jev binary and no credentials" '[ "$(field "$r" actual_route)" = luna_high ]' "$r"
check "default model is gpt-6-luna at high" '[ "$(field "$r" model)/$(field "$r" effort)" = gpt-6-luna/high ]' "$r"
check "ledger row carries no jev_* fields" '! last_line | grep -qE "\"jev_(status|route|confidence|reason|backend|latency_ms|would_accept|input)\""' "$(last_line)"
PATH="$JEVBIN:$BASE"; reset_jev
r=$(route off "$MIDDLE")
printf '%s' '{"file_count":3,"verification_passed":true}' | FABLE_JEV_MODE=off python3 "$S/fable-route.py" review >/dev/null
check "Jev on PATH is never invoked in off mode (route and review)" '[ ! -e "$STUB_JEV_MARK" ]'
mkdir -p "$T/noadapter"; cp "$S/fable-route.py" "$S/fable-config.sh" "$T/noadapter/"
r=$(printf '%s' "$MIDDLE" | FABLE_JEV_MODE=off python3 "$T/noadapter/fable-route.py" route)
check "off mode works with jev_route.py deleted" '[ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(printf '%s' "$MIDDLE" | FABLE_JEV_MODE=shadow python3 "$T/noadapter/fable-route.py" route 2>/dev/null)
check "adapter missing in shadow -> fallback adapter_missing" '[ "$(field "$r" jev_reason)" = adapter_missing ] && [ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(route bogus "$MIDDLE")
check "unknown FABLE_JEV_MODE is treated as off" '[ "$(field "$r" jev_mode)" = off ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
PATH="$BASE"
r=$(printf '%s' "$MIDDLE" | python3 "$S/fable-route.py" route 2>/dev/null)
check "unset FABLE_JEV_MODE defaults to shadow" '[ "$(field "$r" jev_mode)" = shadow ]' "$r"
check "default shadow without a Jev backend falls back and keeps the route" '[ "$(field "$r" jev_status)" = fallback ] && [ "$(field "$r" jev_reason)" = executable_missing ] && [ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" decided_by)" = legacy ]' "$r"
check "no backend: Jev read nothing, so no jev_input is logged" '! last_line | grep -q "\"jev_input\""' "$(last_line)"
PATH="$JEVBIN:$BASE"

echo "Jev shadow"
reset_jev; export STUB_CHOICE=luna_low STUB_CONF=0.91
r=$(route shadow "$MIDDLE")
check "Jev's choice does not change the actual route" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" decided_by)" = legacy ]' "$r"
row=$(last_line)
check "ledger keeps legacy, jev route, confidence and actual" '[ "$(field "$row" legacy_route)|$(field "$row" jev_route)|$(field "$row" jev_confidence)|$(field "$row" actual_route)|$(field "$row" jev_status)" = "luna_high|luna_low|0.91|luna_high|shadow" ]' "$row"
check "shadow records whether active would have accepted it" '[ "$(field "$row" jev_would_accept)" = True ]' "$row"
r=$(STUB_CONF=0.4 route shadow "$MIDDLE")
check "shadow low confidence: would_accept false, reason low_confidence" '[ "$(field "$r" jev_would_accept)" = False ] && [ "$(field "$r" jev_reason)" = low_confidence ]' "$r"

echo "Jev active"
reset_jev; export STUB_CHOICE=luna_low STUB_CONF=0.91
r=$(route active "$MIDDLE")
check "confident Jev route is adopted" '[ "$(field "$r" actual_route)" = luna_low ] && [ "$(field "$r" decided_by)" = jev ] && [ "$(field "$r" effort)" = low ]' "$r"
r=$(STUB_CONF=0.79 route active "$MIDDLE")
check "low confidence -> deterministic route" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_status)/$(field "$r" jev_reason)" = fallback/low_confidence ]' "$r"
r=$(STUB_CONF=0.99 FABLE_JEV_MIN_CONFIDENCE=abc route active "$MIDDLE")
check "invalid min confidence rejects even 0.99" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_reason)" = low_confidence ]' "$r"
r=$(PATH="$BASE" route active "$MIDDLE")
check "Jev unavailable -> fallback executable_missing" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_reason)" = executable_missing ]' "$r"
r=$(STUB_JEV=malformed route active "$MIDDLE")
check "malformed response -> fallback malformed" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_reason)" = malformed ]' "$r"
r=$(STUB_JEV=noconf route active "$MIDDLE")
check "missing confidence -> fallback no_confidence" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_reason)" = no_confidence ]' "$r"
r=$(STUB_CHOICE=gpt_ultra route active "$MIDDLE")
check "unexpected choice -> fallback unknown_choice" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_reason)" = unknown_choice ]' "$r"
t0=$(date +%s); r=$(STUB_JEV=sleep FABLE_JEV_TIMEOUT=1 route active "$MIDDLE"); t1=$(date +%s)
check "timeout -> fallback timeout, bounded wait" '[ "$(field "$r" jev_reason)" = timeout ] && [ $((t1 - t0)) -lt 5 ] && [ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(STUB_JEV=exit:4 route active "$MIDDLE")
check "semdecide provider/network failure -> fallback provider_error" '[ "$(field "$r" jev_reason)" = provider_error ] && [ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(STUB_JEV=exit:3 FABLE_JEV_BACKEND=jev-cli route active "$MIDDLE")
check "jev-cli auth failure -> fallback auth" '[ "$(field "$r" jev_reason)" = auth ]' "$r"
r=$(STUB_JEV=exit:4 FABLE_JEV_BACKEND=jev-cli route active "$MIDDLE")
check "jev-cli network failure -> fallback network" '[ "$(field "$r" jev_reason)" = network ]' "$r"
r=$(FABLE_JEV_BACKEND=jev-cli route active "$MIDDLE")
check "jev-cli backend accepted when confident" '[ "$(field "$r" actual_route)" = luna_low ] && [ "$(field "$r" jev_backend)" = jev-cli ]' "$r"
reset_jev; export STUB_CHOICE=sol_high STUB_CONF=0.9
r=$(route active '{"objective":"Rework cache invalidation across three services","file_count":6,"multi_component":true,"verification_available":true}')
check "sol_high maps to gpt-6-sol at high" '[ "$(field "$r" model)/$(field "$r" effort)" = gpt-6-sol/high ]' "$r"

echo "Hard rules outrank Jev"
reset_jev; export STUB_CHOICE=luna_low STUB_CONF=0.99
RISKY='{"objective":"Rotate session tokens","file_count":3,"security_sensitive":true,"verification_available":true}'
r=$(route active "$RISKY")
check "security-sensitive: confident luna_low is refused" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_status)" = fallback ]' "$r"
check "luna_low was not even offered to Jev" '[ -f "$STUB_JEV_LOG" ] && ! grep -q "luna_low=" "$STUB_JEV_LOG"' "$(cat "$STUB_JEV_LOG" 2>/dev/null)"
r=$(route active '{"objective":"x","file_count":2,"verification_available":true,"prior_failures":1}')
check "one prior failure raises the floor above luna_low" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" floor)" = luna_high ]' "$r"
reset_jev
r=$(route active '{"file_count":1,"mechanical":true,"verification_available":true}')
check "obvious one-file mechanical case skips Jev" '[ "$(field "$r" actual_route)/$(field "$r" jev_status)" = luna_low/skipped ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
r=$(route active '{"file_count":3,"prior_failures":2,"verification_available":true}')
check "two failures -> claude_opus_high (implementer, opus, high), Jev skipped" '[ "$(field "$r" actual_route)/$(field "$r" lane)/$(field "$r" model)/$(field "$r" effort)" = claude_opus_high/implementer/opus/high ] && [ "$(field "$r" jev_status)" = skipped ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
r=$(route active '{"file_count":3,"context_bound":true}')
check "context-bound -> self" '[ "$(field "$r" actual_route)" = self ]' "$r"
r=$(route off "$RISKY" --route luna_low)
check "caller override below the risk floor is refused" '[ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" override_rejected)" = below_risk_floor ]' "$r"
r=$(route off "$MIDDLE" --route sol_high)
check "caller may choose sol_high explicitly" '[ "$(field "$r" actual_route)/$(field "$r" decided_by)" = sol_high/caller ]' "$r"
r=$(route off '{"file_count":2,"schema_change":true,"verification_available":true}')
check "schema change asks for a fable-advisor consult first" '[ "$(field "$r" consult_first)" = fable-advisor ]' "$r"
reset_jev; export STUB_CHOICE=luna_low STUB_CONF=0.91
r=$(route active '{"file_count":9,"interface_change":true,"multi_component":true,"verification_available":true}')
check "interface/multi-component work cannot be sent to luna_low by Jev" '[ "$(field "$r" actual_route)/$(field "$r" floor)" = luna_high/luna_high ]' "$r"
r=$(route active '{"objective":"unknown size","verification_available":true}')
check "unknown file_count keeps the floor at luna_high" '[ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(route off '{"file_count":3,"prior_failures":2,"verification_available":true}' --route luna_high)
check "after two failures an override below claude_opus_high is refused" '[ "$(field "$r" actual_route)" = claude_opus_high ] && [ "$(field "$r" override_rejected)" = below_risk_floor ]' "$r"
r=$(route off '{"file_count":3,"prior_failures":2,"verification_available":true}' --route self)
check "after two failures --route self is refused too" '[ "$(field "$r" actual_route)" = claude_opus_high ]' "$r"
r=$(route off "$MIDDLE" --route self)
check "--route self is honoured otherwise" '[ "$(field "$r" actual_route)" = self ]' "$r"
r=$(route shadow "$RISKY")
check "shadow keeps an off-list Jev answer visible in the ledger" '[ "$(field "$r" jev_route)/$(field "$r" jev_reason)" = luna_low/unknown_choice ] && [ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(FABLE_JEV_TIMEOUT=inf route active "$MIDDLE")
check "unbounded FABLE_JEV_TIMEOUT is clamped, routing continues" '[ -n "$(field "$r" actual_route)" ] && grep -q "FABLE_JEV_TIMEOUT" "$T/stderr"' "$r"

echo "Jev input is minimal"
reset_jev; export STUB_CHOICE=luna_high STUB_CONF=0.9
long=$(python3 -c 'print("x"*2000)')
route active "{\"objective\":\"$long\",\"file_count\":4,\"verification_available\":true,\"diff\":\"SECRET_DIFF\",\"context_bound\":false}" >/dev/null
sent=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stdin"])' "$STUB_JEV_LOG")
check "unknown keys (a pasted diff) never reach Jev" '! grep -q SECRET_DIFF <<<"$sent"' "$sent"
check "Claude-side flags are not sent" '! grep -q context_bound <<<"$sent"' "$sent"
check "objective truncated, state well under 2 KB" '[ ${#sent} -lt 600 ]' "${#sent} bytes"
same_input() {  # the row's jev_input is exactly the state the stub read on stdin — no key more, none less
  python3 -c 'import json,sys; row=json.loads(sys.argv[1]); sent=json.loads(json.load(open(sys.argv[2]))["stdin"])
sys.exit(0 if isinstance(row.get("jev_input"), dict) and row["jev_input"] == sent else 1)' "$1" "$STUB_JEV_LOG"
}
check "active: the decision row logs the state Jev received as jev_input" 'same_input "$(last_line)"' "$(last_line)"
check "the pasted diff and rule-only flags are not logged either" '! last_line | grep -qE "SECRET_DIFF|\"diff\"|context_bound"' "$(last_line)"
reset_jev; export STUB_CHOICE=sol_high STUB_CONF=0.9
r=$(route shadow '{"objective":"Split the parser","file_count":5,"multi_component":true,"verification_available":true,"below_spawn_floor":false,"notes":"PASTED"}')
check "shadow: jev_input matches what Jev received, and the route is unchanged" 'same_input "$(last_line)" && [ "$(field "$r" actual_route)|$(field "$r" jev_status)" = "luna_high|shadow" ]' "$(last_line)"
check "shadow: unknown and rule-only keys never reach jev_input" '! last_line | grep -qE "PASTED|\"notes\"|below_spawn_floor"' "$(last_line)"
reset_jev
route shadow '{"file_count":1,"mechanical":true,"verification_available":true}' >/dev/null
check "a rule-decided row (Jev skipped) has no jev_input" '[ "$(field "$(last_line)" jev_status)" = skipped ] && ! last_line | grep -q "\"jev_input\"" && [ ! -e "$STUB_JEV_MARK" ]' "$(last_line)"
route off '{"objective":"Split the parser","file_count":5,"multi_component":true,"verification_available":true}' >/dev/null
check "off mode: the same ambiguous task logs no jev_input" '! last_line | grep -q "\"jev_input\"" && [ ! -e "$STUB_JEV_MARK" ]' "$(last_line)"
rep=$(python3 "$S/routing-report.py" --json)
check "report breaks Jev's recommendations down by the input it saw" 'python3 -c "
import json,sys; b=json.loads(sys.argv[1])[\"current_policy\"][\"jev\"][\"recommendation_by_input\"]
assert b[\"multi_component\"][\"true\"].get(\"sol_high\",0)>=1, b
assert b[\"file_count\"][\"4+\"] and \"absent\" in b[\"prior_failures\"], b
assert set(b)=={\"prior_failures\",\"file_count\",\"multi_component\",\"interface_change\"}, b
" "$rep"' "$rep"

echo "5.4 routing policy: Luna Max, Opus, Fable"
NARROW='{"objective":"Fix rounding in the price formatter","file_count":2,"verification_available":true,"prior_failures":1}'
offered() { python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["argv"]; print(" ".join(x.split("=")[0] for x in a if "=" in x and not x.startswith("-")))' "$STUB_JEV_LOG"; }
reset_jev
r=$(route off "$NARROW")
check "first failure + narrow + verification: luna_max eligible, deterministic stays luna_high" '[ "$(field "$r" luna_max_eligible)|$(field "$r" legacy_route)|$(field "$r" actual_route)|$(field "$r" rule)" = "True|luna_high|luna_high|retry" ]' "$r"
check "off mode on a luna_max-eligible task: Jev never called, no jev fields" '[ ! -e "$STUB_JEV_MARK" ] && ! last_line | grep -qE "\"jev_(status|route|confidence|reason|backend|latency_ms|would_accept|input)\""' "$(last_line)"
reset_jev; export STUB_CHOICE=luna_max STUB_CONF=0.9
r=$(route shadow "$NARROW")
check "shadow: Jev's luna_max is logged, the route does not change" '[ "$(field "$r" jev_route)|$(field "$r" jev_status)|$(field "$r" jev_would_accept)|$(field "$r" actual_route)|$(field "$r" effort)" = "luna_max|shadow|True|luna_high|high" ]' "$r"
check "after one failure Jev is offered luna_high, luna_max, sol_high, claude_opus_high — never Fable" '[ "$(offered)" = "luna_high luna_max sol_high claude_opus_high" ]' "$(offered)"
r=$(route active "$NARROW")
check "active + confident + eligible: luna_max adopted (gpt-6-luna at max)" '[ "$(field "$r" actual_route)|$(field "$r" decided_by)|$(field "$r" model)|$(field "$r" effort)" = "luna_max|jev|gpt-6-luna|max" ]' "$r"
r=$(STUB_CONF=0.6 route active "$NARROW")
check "active + low confidence: luna_max not adopted" '[ "$(field "$r" actual_route)|$(field "$r" jev_reason)" = "luna_high|low_confidence" ]' "$r"
for broad in '"multi_component":true' '"interface_change":true' '"security_sensitive":true' '"file_count":6'; do
  st=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update(json.loads("{"+sys.argv[2]+"}")); print(json.dumps(d))' "$NARROW" "$broad")
  r=$(STUB_CONF=0.99 route active "$st")
  check "first failure + $broad: luna_max not eligible, not offered, not adopted at 0.99" '[ -z "$(field "$r" luna_max_eligible)" ] && [ "$(field "$r" actual_route)" = luna_high ] && [ "$(field "$r" jev_reason)" = unknown_choice ] && ! grep -qw luna_max <<<"$(offered)"' "$r"
done
r=$(route active '{"file_count":1,"verification_available":true,"prior_failures":1}' --route luna_max)
check "caller may pick luna_max for an eligible retry" '[ "$(field "$r" actual_route)|$(field "$r" decided_by)|$(field "$r" effort)" = "luna_max|caller|max" ]' "$r"
r=$(route off "$MIDDLE" --route luna_max)
check "first attempt: caller --route luna_max is refused (luna_max_ineligible)" '[ "$(field "$r" actual_route)|$(field "$r" override_rejected)" = "luna_high|luna_max_ineligible" ]' "$r"
r=$(route off '{"file_count":2,"verification_available":true,"prior_failures":1,"multi_component":true}' --route luna_max)
check "broad retry: caller --route luna_max is refused" '[ "$(field "$r" override_rejected)" = luna_max_ineligible ]' "$r"
reset_jev; export STUB_CHOICE=luna_max STUB_CONF=0.99
r=$(route active "$MIDDLE")
check "first attempt: Jev is offered luna_low/luna_high/sol_high only; luna_max refused at 0.99" '[ "$(offered)" = "luna_low luna_high sol_high" ] && [ "$(field "$r" actual_route)|$(field "$r" jev_reason)" = "luna_high|unknown_choice" ]' "$r $(offered)"
r=$(STUB_CHOICE=claude_opus_high route active "$MIDDLE")
check "first attempt: Jev cannot send work to Opus" '[ "$(field "$r" actual_route)|$(field "$r" jev_reason)" = "luna_high|unknown_choice" ]' "$r"
r=$(STUB_CHOICE=claude_opus_high route active '{"file_count":6,"multi_component":true,"verification_available":true,"prior_failures":1}')
check "after one failure a confident Jev may escalate to claude_opus_high" '[ "$(field "$r" actual_route)|$(field "$r" model)|$(field "$r" effort)" = "claude_opus_high|opus|high" ]' "$r"
r=$(STUB_CHOICE=luna_high route active '{"file_count":3,"prior_failures":2,"verification_available":true}')
check "two failures: a confident Jev cannot pull the hard-rule Opus route down" '[ "$(field "$r" actual_route)|$(field "$r" jev_status)" = "claude_opus_high|skipped" ]' "$r"
reset_jev
r=$(route active '{"file_count":3,"prior_failures":3,"verification_available":true}')
check "three failures -> consult_first fable-advisor, implementation stays claude_opus_high" '[ "$(field "$r" consult_first)|$(field "$r" consult_reason)|$(field "$r" actual_route)" = "fable-advisor|failed_three_times|claude_opus_high" ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
r=$(route active '{"file_count":3,"verification_available":true,"architectural_deadlock":true}')
check "architectural_deadlock -> consult_first fable-advisor, Jev skipped" '[ "$(field "$r" consult_first)|$(field "$r" consult_reason)|$(field "$r" jev_status)|$(field "$r" actual_route)" = "fable-advisor|architectural_deadlock|skipped|claude_opus_high" ]' "$r"
r=$(route active '{"file_count":3,"verification_available":true,"prior_failures":1,"opus_failed":true}')
check "opus_failed -> consult_first fable-advisor" '[ "$(field "$r" consult_first)|$(field "$r" consult_reason)" = "fable-advisor|opus_failed" ] && [ -z "$(field "$r" luna_max_eligible)" ]' "$r"
r=$(route active '{"file_count":3,"verification_available":true,"judgment_dominated":true}')
check "judgment_dominated -> claude_opus_high by rule, no Fable consult" '[ "$(field "$r" actual_route)|$(field "$r" rule)|$(field "$r" jev_status)" = "claude_opus_high|judgment_dominated|skipped" ] && [ -z "$(field "$r" consult_first)" ]' "$r"
r=$(route off '{"file_count":3,"prior_failures":2,"verification_available":true}')
check "two failures alone do not force a Fable consult" '[ -z "$(field "$r" consult_first)" ]' "$r"
check "Fable is not an implementation route: not in ROUTE_OPTIONS, not a --route choice" 'python3 -c "
import importlib.util,sys; sp=importlib.util.spec_from_file_location(\"fr\",\"$S/fable-route.py\"); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
assert not [k for k in list(m.ROUTE_OPTIONS)+list(m.ROUTES)+list(m.REVIEW_JEV_OPTIONS) if \"fable\" in k], m.ROUTE_OPTIONS
assert set(m.REVIEW_JEV_OPTIONS)=={\"self_review\",\"opus_review\"}
"'
printf '%s' "$MIDDLE" | python3 "$S/fable-route.py" route --route claude_fable >/dev/null 2>"$T/stderr"; rc=$?
check "--route claude_fable is refused with a pointer to its replacement" '[ $rc -eq 2 ] && grep -q claude_opus_high "$T/stderr"' "$(cat "$T/stderr")"
r=$(route off "$MIDDLE")
check "every new decision carries policy_version 5.5.0" '[ "$(field "$r" policy_version)" = 5.5.0 ] && [ "$(field "$(last_line)" policy_version)" = 5.5.0 ]' "$r"
reset_jev; export STUB_CHOICE=luna_high STUB_CONF=0.9
route active '{"file_count":2,"verification_available":true,"prior_failures":1,"opus_failed":false,"architectural_deadlock":false,"judgment_dominated":false}' >/dev/null
sent=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stdin"])' "$STUB_JEV_LOG")
check "rule-only consult flags are never sent to Jev" '! grep -qE "opus_failed|architectural_deadlock|judgment_dominated" <<<"$sent"' "$sent"

echo "Review gate"
reset_jev; export STUB_CHOICE=none STUB_CONF=0.99
review() { printf '%s' "$2" | FABLE_JEV_MODE=$1 python3 "$S/fable-route.py" review --id "${3:-}" 2>/dev/null; }
v=$(review active '{"file_count":3,"security_sensitive":true,"verification_passed":true}')
check "high-risk -> opus_review (opus-reviewer, opus, high); Jev never asked" '[ "$(field "$v" review)/$(field "$v" reviewer)/$(field "$v" reviewer_model)/$(field "$v" reviewer_effort)" = opus_review/opus-reviewer/opus/high ] && [ ! -e "$STUB_JEV_MARK" ]' "$v"
v=$(review active '{"file_count":1,"mechanical":true,"verification_passed":true}')
check "one-file mechanical + passing verification -> none" '[ "$(field "$v" review)" = none ]' "$v"
v=$(review off '{"file_count":3,"verification_passed":true}')
check "ordinary change -> self_review (off)" '[ "$(field "$v" review)" = self_review ]' "$v"
v=$(STUB_CHOICE=opus_review STUB_CONF=0.95 review active '{"file_count":3,"lines_changed":240,"verification_passed":true}')
check "ambiguous middle: confident Jev escalates to opus_review" '[ "$(field "$v" review)/$(field "$v" review_decided_by)/$(field "$v" reviewer)" = opus_review/jev/opus-reviewer ]' "$v"
v=$(STUB_CHOICE=opus_review STUB_CONF=0.5 review active '{"file_count":3,"verification_passed":true}')
check "ambiguous middle: unsure Jev -> self_review" '[ "$(field "$v" review)" = self_review ] && [ "$(field "$v" jev_reason)" = low_confidence ]' "$v"
v=$(review active '{"file_count":1,"mechanical":true,"verification_passed":false}')
check "failing verification never gets review none" '[ "$(field "$v" review)" = self_review ]' "$v"
STUB_CHOICE=none STUB_CONF=0.99 v=$(review active '{"file_count":60,"lines_changed":4000,"verification_passed":true}')
check "Jev can never skip review (none is not offered in the middle)" '[ "$(field "$v" review)" = self_review ] && [ "$(field "$v" jev_reason)" = unknown_choice ]' "$v"
v=$(review active '{"file_count":2,"verification_passed":true,"attempts":3}')
check "resisted two attempts -> opus_review by rule" '[ "$(field "$v" review)/$(field "$v" review_decided_by)" = opus_review/rule ]' "$v"
v=$(review off '{"file_count":1,"mechanical":true,"verification_passed":true,"silence_gap":2}')
check "a silence gap rules out review none" '[ "$(field "$v" review)" = self_review ]' "$v"
reset_jev
v=$(review active '{"file_count":3,"verification_passed":true,"lane_disagreement":true}')
check "lane/model disagreement -> fable_review (exceptional) by rule" '[ "$(field "$v" review)|$(field "$v" review_decided_by)|$(field "$v" reviewer)|$(field "$v" reviewer_model)" = "fable_review|rule|fable-advisor|fable" ] && [ ! -e "$STUB_JEV_MARK" ]' "$v"
v=$(review off '{"file_count":3,"schema_change":true,"verification_passed":true,"architectural_deadlock":true}')
check "architectural deadlock outranks high risk: fable_review" '[ "$(field "$v" review)" = fable_review ] && grep -q "exceptional:architectural_deadlock" <<<"$(field "$v" rule)"' "$v"
v=$(review off '{"file_count":3,"irreversible":true,"verification_passed":true,"opus_review_inconclusive":true}')
check "an inconclusive Opus review escalates to fable_review" '[ "$(field "$v" review)" = fable_review ]' "$v"
v=$(review off '{"file_count":3,"irreversible":true,"verification_passed":true}')
check "high risk alone is opus_review, not Fable" '[ "$(field "$v" review)" = opus_review ]' "$v"
reset_jev; export STUB_CHOICE=fable_review STUB_CONF=0.99
v=$(review active '{"file_count":5,"lines_changed":900,"verification_passed":true}')
check "Jev review options are self_review/opus_review only" '[ "$(offered)" = "self_review opus_review" ]' "$(offered)"
check "Jev cannot choose fable_review, even at 0.99" '[ "$(field "$v" review)|$(field "$v" jev_reason)" = "self_review|unknown_choice" ]' "$v"
v=$(STUB_CHOICE=opus_review review shadow '{"file_count":5,"lines_changed":900,"verification_passed":true}')
check "shadow review: Jev's opus_review is logged, review stays self_review" '[ "$(field "$v" review)|$(field "$v" jev_route)|$(field "$v" jev_status)|$(field "$v" policy_version)" = "self_review|opus_review|shadow|5.5.0" ]' "$v"

echo "Ledger and report"
reset_jev; export STUB_CHOICE=luna_low STUB_CONF=0.91
r=$(route shadow "$MIDDLE" --task "retry handling"); id=$(field "$r" id)
review off '{"file_count":4,"verification_passed":true}' "$id" >/dev/null
o=$(python3 "$S/fable-route.py" outcome --id "$id" --outcome success --attempts 1 --duration 180)
check "outcome row joins decision and review" '[ "$(field "$o" legacy_route)|$(field "$o" jev_route)|$(field "$o" review)|$(field "$o" duration_s)|$(field "$o" model)" = "luna_high|luna_low|self_review|180.0|gpt-6-luna" ]' "$o"
echo '{"ts":"2026-08-01T00:00:00Z","task":"old","class":"implement","lane":"codex-implementer","reason":"none","outcome":"success","attempts":1,"duration_s":60}' >> "$FABLE_LEDGER"
rep=$(python3 "$S/routing-report.py" 2>&1)
check "report runs and shows agreement, buckets, route stats" 'grep -q agreement_with_legacy <<<"$rep" && grep -q confidence_buckets <<<"$rep" && grep -q by_route <<<"$rep"' "$rep"
check "report reads pre-5.1 ledger lines" 'grep -q pre_5_1_records <<<"$rep"' "$rep"
j=$(python3 "$S/routing-report.py" --json)
check "report --json is valid JSON" 'python3 -c "import json,sys; json.loads(sys.argv[1])" "$j"'
{ echo '{"event":"decision","id":"x1","jev_route":"luna_low","jev_confidence":null,"legacy_route":"luna_high"}'
  echo '{"event":"decision","id":"x2","jev_route":"luna_low","jev_confidence":"high"}'
  echo '{"event":"outcome","id":["a"],"attempts":"2","outcome":"success"}'
  echo '{"event":"outcome","id":"x3","attempts":true,"jev_mode":["weird"]}'
  echo '[1,2,3]'; echo '"a string"'; printf '\xff\xfe broken utf8\n'; } >> "$FABLE_LEDGER"
python3 "$S/routing-report.py" >/dev/null 2>"$T/rep-err"; rc=$?
check "report survives malformed ledger rows" '[ $rc -eq 0 ]' "$(cat "$T/rep-err")"
o=$(python3 "$S/fable-route.py" outcome --id "$id" --outcome retry --attempts 2 2>&1); rc=$?
check "outcome still records against a malformed ledger" '[ $rc -eq 0 ] && [ "$(field "$o" legacy_route)" = luna_high ]' "$o"
check "an outcome inherits its decision's policy_version" '[ "$(field "$o" policy_version)" = 5.5.0 ]' "$o"
echo '{"event":"decision","id":"pre54","legacy_route":"claude_fable","actual_route":"claude_fable","lane":"implementer","model":"fable"}' >> "$FABLE_LEDGER"
o=$(python3 "$S/fable-route.py" outcome --id pre54 --outcome success 2>&1)
check "an outcome on a pre-5.4 decision stays unversioned (historical), route kept" '[ -z "$(field "$o" policy_version)" ] && [ "$(field "$o" actual_route)" = claude_fable ]' "$o"
rep=$(python3 "$S/routing-report.py" --json)
check "the live ledger report keeps the pre-5.4 claude_fable row out of current_policy" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1])
assert \"claude_fable\" not in d[\"current_policy\"][\"route_distribution\"] and d[\"by_policy_version\"][\"pre-5.4\"][\"route_distribution\"][\"claude_fable\"]>=1
" "$rep"' "$rep"

echo "Report: policy versions are never mixed"
MIX="$T/mixed.jsonl"
{ # v5.3-era rows: no policy_version, the retired claude_fable route and Fable reviews
  echo '{"event":"decision","id":"old1","legacy_route":"luna_high","actual_route":"luna_high","jev_mode":"shadow","jev_status":"shadow","jev_route":"sol_high","jev_confidence":0.9,"jev_would_accept":true,"lane":"codex-implementer","model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"attempt","id":"old1","lane_status":"ok","duration_s":100,"model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"attempt","id":"old1","policy_version":"5.4.0","lane_status":"ok","duration_s":50,"model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"outcome","id":"old1","actual_route":"luna_high","jev_status":"shadow","jev_route":"sol_high","outcome":"success","attempts":1}'
  echo '{"event":"decision","id":"old2","legacy_route":"claude_fable","actual_route":"claude_fable","jev_mode":"shadow","jev_status":"skipped","lane":"implementer","model":"fable"}'
  echo '{"event":"outcome","id":"old2","actual_route":"claude_fable","outcome":"success","attempts":1,"duration_s":900}'
  echo '{"event":"decision","id":"old3","legacy_route":"luna_high","actual_route":"luna_high","jev_mode":"shadow","jev_status":"shadow","jev_route":"luna_high","jev_confidence":0.95}'
  echo '{"event":"review","id":"old2","legacy_review":"fable_review","review":"fable_review","rule":"high_risk:schema_change"}'
  # v5.4 rows
  echo '{"event":"decision","id":"new1","policy_version":"5.4.0","legacy_route":"luna_high","actual_route":"luna_high","jev_mode":"shadow","jev_status":"shadow","jev_route":"luna_max","jev_confidence":0.85,"jev_would_accept":true,"luna_max_eligible":true,"lane":"codex-implementer","model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"attempt","id":"new1","policy_version":"5.4.0","lane_status":"error","duration_s":200,"model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"attempt","id":"new1","policy_version":"5.4.0","lane_status":"ok","duration_s":300,"model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"decision","id":"new2","policy_version":"5.4.0","legacy_route":"luna_high","actual_route":"luna_max","decided_by":"caller","jev_mode":"shadow","jev_status":"shadow","jev_route":"claude_opus_high","jev_confidence":0.7,"jev_would_accept":false,"lane":"codex-implementer","model":"gpt-6-luna","effort":"max"}'
  echo '{"event":"attempt","id":"new2","policy_version":"5.4.0","lane_status":"timeout","duration_s":570,"model":"gpt-6-luna","effort":"max"}'
  echo '{"event":"attempt","id":"new2","policy_version":"5.4.0","lane_status":"ok","duration_s":400,"model":"gpt-6-luna","effort":"max"}'
  echo '{"event":"outcome","id":"new2","policy_version":"5.4.0","actual_route":"luna_max","jev_status":"shadow","jev_route":"claude_opus_high","outcome":"success","attempts":2,"duration_s":970}'
  echo '{"event":"decision","id":"new3","policy_version":"5.4.0","legacy_route":"luna_high","actual_route":"sol_high","backfilled":true,"jev_mode":"shadow","jev_status":"shadow","jev_route":"sol_high","jev_confidence":0.9,"lane":"codex-implementer","model":"gpt-6-sol","effort":"high"}'
  echo '{"event":"attempt","id":"new3","policy_version":"5.4.0","unrouted":true,"lane_status":"ok","duration_s":120,"model":"gpt-6-sol","effort":"high"}'
  echo '{"event":"decision","id":"new4","policy_version":"5.4.0","legacy_route":"claude_opus_high","actual_route":"claude_opus_high","rule":"failed_twice","jev_mode":"shadow","jev_status":"skipped","lane":"implementer","model":"opus","effort":"high"}'
  echo '{"event":"outcome","id":"new4","policy_version":"5.4.0","actual_route":"claude_opus_high","outcome":"success","attempts":1,"duration_s":600}'
  echo '{"event":"review","id":"new4","policy_version":"5.4.0","legacy_review":"opus_review","review":"opus_review","rule":"resisted_two_attempts"}'
  echo '{"event":"attempt","id":"unrouted-1-2","policy_version":"5.4.0","unrouted":true,"lane_status":"ok","duration_s":30,"model":"gpt-6-luna","effort":"xhigh"}'
  # v5.5 rows: the current policy, which must not absorb any 5.4 evidence
  echo '{"event":"decision","id":"n55","policy_version":"5.5.0","legacy_route":"claude_opus_high","actual_route":"claude_opus_high","jev_mode":"shadow","jev_status":"skipped","lane":"implementer","model":"opus","effort":"medium"}'
  echo '{"event":"outcome","id":"n55","policy_version":"5.5.0","actual_route":"claude_opus_high","model":"opus","effort":"medium","outcome":"success","attempts":1,"duration_s":300,"reviewer":"opus-reviewer","reviewer_model":"opus","reviewer_effort":"medium","review_verdict":"fix_first","review_findings":2}'
  echo '{"event":"decision","id":"n56","policy_version":"5.5.0","legacy_route":"luna_high","actual_route":"luna_high","jev_mode":"shadow","jev_status":"shadow","jev_route":"luna_high","jev_confidence":0.9,"lane":"codex-implementer","model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"attempt","id":"n56","policy_version":"5.5.0","lane_status":"ok","verify":"fail","duration_s":90,"model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"attempt","id":"n56","policy_version":"5.5.0","lane_status":"ok","verify":"pass","duration_s":60,"model":"gpt-6-luna","effort":"high"}'
} > "$MIX"
rep=$(python3 "$S/routing-report.py" --ledger "$MIX" --json 2>&1); rc=$?
check "report reads a mixed v5.3/v5.4/v5.5 ledger (historical claude_fable rows included)" '[ $rc -eq 0 ]' "$rep"
check "policy_version_distribution separates pre-5.4, 5.4.0 and 5.5.0" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1]); p=d[\"policy_version_distribution\"]
assert p[\"decision\"]=={\"pre-5.4\":3,\"5.4.0\":4,\"5.5.0\":2}, p
assert p[\"attempt\"]=={\"pre-5.4\":2,\"5.4.0\":6,\"5.5.0\":2}, p   # a 5.3 decision keeps its late 5.4-stamped attempt
assert set(d[\"by_policy_version\"])=={\"pre-5.4\",\"5.4.0\",\"5.5.0\"} and d[\"current_policy_version\"]==\"5.5.0\"
" "$rep"' "$rep"
check "headline Jev stats are current-policy only; every policy keeps its own section" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1]); cur=d[\"current_policy\"]; c=d[\"by_policy_version\"][\"5.4.0\"]; old=d[\"by_policy_version\"][\"pre-5.4\"]
assert cur==d[\"by_policy_version\"][\"5.5.0\"] and cur[\"total_decisions\"]==2 and cur[\"jev\"][\"consulted\"]==1, cur[\"jev\"]
assert cur[\"jev\"][\"agreement_with_legacy\"]==1.0, cur[\"jev\"]
assert c[\"jev\"][\"consulted\"]==3 and old[\"jev\"][\"consulted\"]==2, (c[\"jev\"], old[\"jev\"])
assert c[\"jev\"][\"agreement_with_legacy\"]==0.0 and old[\"jev\"][\"agreement_with_legacy\"]==0.5, (c[\"jev\"], old[\"jev\"])
assert c[\"jev\"][\"jev_recommendation_distribution\"]=={\"luna_max\":1,\"claude_opus_high\":1,\"sol_high\":1}, c[\"jev\"]
assert \"claude_fable\" not in c[\"route_distribution\"] and old[\"route_distribution\"][\"claude_fable\"]==1
assert \"note\" in d[\"historical_all\"] and d[\"historical_all\"][\"total_decisions\"]==9
assert c[\"review\"][\"distribution\"]=={\"opus_review\":1} and old[\"review\"][\"distribution\"]=={\"fable_review\":1}
" "$rep"' "$rep"
check "5.5 report: acceptance pass rates, outcomes and review results per model/effort" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"current_policy\"]
l=c[\"lane_attempts\"][\"by_route\"][\"luna_high\"]
assert l[\"verify_first_pass\"]==0.0 and l[\"verify_eventually_pass\"]==1.0, l
assert c[\"by_model_effort\"][\"gpt-6-luna/high\"][\"verify_pass_rate\"]==0.5, c[\"by_model_effort\"]
o=c[\"outcomes_by_model_effort\"][\"claude_opus_high opus/medium\"]
assert o[\"n\"]==1 and o[\"success_rate\"]==1.0, c[\"outcomes_by_model_effort\"]
r=c[\"review\"][\"results_by_reviewer\"][\"opus-reviewer opus/medium\"]
assert r[\"avg_findings\"]==2 and r[\"verdicts\"]=={\"fix_first\":1}, r
" "$rep"' "$rep"
check "shadow counterfactuals distinguish the new routes" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"by_policy_version\"][\"5.4.0\"]; l=c[\"shadow_disagreement_lanes\"]
assert l[\"jev=luna_max ran=luna_high\"][\"first_try_ok\"]==0.0 and l[\"jev=luna_max ran=luna_high\"][\"retry_rate\"]==1.0, l
assert l[\"jev=luna_max ran=luna_high\"][\"would_accept_in_active\"]==1, l
assert l[\"jev=claude_opus_high ran=luna_max\"][\"timeout_rate\"]==1.0, l
assert \"jev=sol_high ran=sol_high\" not in l
assert c[\"shadow_disagreement_outcomes\"][\"jev=claude_opus_high ran=luna_max\"][\"success_rate\"]==1.0
" "$rep"' "$rep"
check "route stats carry p50/p90/timeout; by_model_effort keeps real pairs" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"by_policy_version\"][\"5.4.0\"]; r=c[\"lane_attempts\"][\"by_route\"]
assert r[\"luna_max\"][\"p90_lane_s\"]==970 and r[\"luna_max\"][\"timeout_rate\"]==1.0 and r[\"luna_high\"][\"p50_lane_s\"]==500, r
m=c[\"by_model_effort\"]
assert set(m)=={\"gpt-6-luna/high\",\"gpt-6-luna/max\",\"gpt-6-sol/high\",\"gpt-6-luna/xhigh\"}, m
assert m[\"gpt-6-luna/max\"][\"attempts\"]==2 and m[\"gpt-6-luna/max\"][\"p90_s\"]==570 and m[\"gpt-6-luna/max\"][\"timeout_rate\"]==0.5, m
assert c[\"by_route\"][\"claude_opus_high\"][\"p50_duration_s\"]==600
" "$rep"' "$rep"
txt=$(python3 "$S/routing-report.py" --ledger "$MIX" 2>&1); rc=$?
check "text report renders nested sections" '[ $rc -eq 0 ] && grep -q "^current_policy:" <<<"$txt" && grep -q "^by_policy_version:" <<<"$txt" && grep -q "^  pre-5.4:" <<<"$txt"' "$txt"

echo "Imajev shadow: configuration"
PATH="$JEVBIN:$BASE"; reset_jev
export STUB_IMAJEV_CTL="$T/imajev-ctl.json" STUB_IMAJEV_LOG="$T/imajev-call.json" STUB_IMAJEV_MARK="$T/imajev-called"
python3 "$ROOT/tests/stubs/imajevstub" "$T/imajev-port" & IMAJEV_PID=$!
i=0; while [ ! -s "$T/imajev-port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
IMAJEV_URL="http://127.0.0.1:$(cat "$T/imajev-port")/v1/systemone"
DEAD_URL="http://127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')/v1/systemone"
export FABLE_IMAJEV_URL="$IMAJEV_URL"
reset_imajev() { rm -f "$STUB_IMAJEV_MARK" "$STUB_IMAJEV_LOG"; printf '{}' > "$STUB_IMAJEV_CTL"; }
imajev_says() { printf '%s' "$1" > "$STUB_IMAJEV_CTL"; }
dual() {  # dual <jev mode> <imajev mode> <state> [route args...]
  local jm=$1 im=$2 state=$3; shift 3
  printf '%s' "$state" | FABLE_JEV_MODE=$jm FABLE_IMAJEV_MODE=$im python3 "$S/fable-route.py" route "$@" 2>"$T/stderr"
}
no_imajev_fields() { ! grep -q '"imajev_' <<<"$1"; }
reset_imajev
c=$(FABLE_IMAJEV_URL= python3 "$S/fable-route.py" config)
check "default FABLE_IMAJEV_MODE is off, URL is the local System One endpoint" '[ "$(field "$c" FABLE_IMAJEV_MODE)|$(field "$c" imajev_mode_effective)|$(field "$c" FABLE_IMAJEV_URL)" = "off|off|http://127.0.0.1:8765/v1/systemone" ]' "$c"
check "config never contacts Imajev" '[ ! -e "$STUB_IMAJEV_MARK" ]'
export STUB_CHOICE=luna_low STUB_CONF=0.91
r=$(route shadow "$MIDDLE")
check "unset FABLE_IMAJEV_MODE: Imajev never contacted, no imajev_* on the row, Jev shadow as before" '[ ! -e "$STUB_IMAJEV_MARK" ] && no_imajev_fields "$(last_line)" && [ "$(field "$r" jev_status)|$(field "$r" actual_route)" = "shadow|luna_high" ]' "$(last_line)"
for m in bogus active ACTIVE; do
  r=$(dual shadow "$m" "$MIDDLE")
  check "FABLE_IMAJEV_MODE=$m is treated as off (no active mode), with a warning" '[ ! -e "$STUB_IMAJEV_MARK" ] && no_imajev_fields "$(last_line)" && grep -q FABLE_IMAJEV_MODE "$T/stderr" && [ "$(field "$r" actual_route)" = luna_high ]' "$r"
done
reset_jev; reset_imajev
r=$(dual off off "$MIDDLE")
check "both off: deterministic route, neither model contacted" '[ "$(field "$r" actual_route)|$(field "$r" decided_by)" = "luna_high|legacy" ] && [ ! -e "$STUB_IMAJEV_MARK" ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
r=$(printf '%s' "$MIDDLE" | FABLE_JEV_MODE=off FABLE_IMAJEV_MODE=off python3 "$T/noadapter/fable-route.py" route)
check "off works with imajev_route.py absent" '[ "$(field "$r" actual_route)" = luna_high ]' "$r"
r=$(printf '%s' "$MIDDLE" | FABLE_JEV_MODE=off FABLE_IMAJEV_MODE=shadow python3 "$T/noadapter/fable-route.py" route 2>/dev/null)
check "adapter missing in shadow -> imajev fallback adapter_missing, route kept, no imajev_input" '[ "$(field "$r" imajev_status)|$(field "$r" imajev_reason)|$(field "$r" actual_route)" = "fallback|adapter_missing|luna_high" ] && [ -z "$(field "$r" imajev_input)" ]' "$r"

echo "Imajev shadow: answers are logged, never used"
reset_jev; reset_imajev
r=$(dual off shadow "$MIDDLE")
row=$(last_line)
check "Imajev's choice is logged; the actual route does not change" '[ "$(field "$row" imajev_route)|$(field "$row" imajev_status)|$(field "$row" actual_route)|$(field "$row" decided_by)" = "luna_low|shadow|luna_high|legacy" ]' "$row"
check "row keeps confidence, model, backend, latency, server time, unknown, abstained, would_accept" 'python3 -c "
import json,sys; r=json.loads(sys.argv[1])
assert r[\"imajev_confidence\"]==0.91 and r[\"imajev_model\"]==\"imajev-4b\" and r[\"imajev_backend\"]==\"imajev-local\", r
assert isinstance(r[\"imajev_latency_ms\"], int) and r[\"imajev_server_ms\"]==12.3, r
assert r[\"imajev_unknown_probability\"]==0.01 and r[\"imajev_abstained\"] is False and r[\"imajev_would_accept\"] is True, r
assert r[\"imajev_mode\"]==\"shadow\" and r[\"imajev_calibration_version\"]==\"stub-cal\" and \"imajev_reason\" not in r, r
" "$row"' "$row"
check "probabilities: one per offered option, off-list keys dropped" 'python3 -c "
import json,sys; r=json.loads(sys.argv[1]); p=r[\"imajev_probabilities\"]
assert set(p)=={\"luna_low\",\"luna_high\",\"sol_high\"} and p[\"luna_low\"]==0.9, p
" "$row"' "$row"
check "jev off: no jev_* fields are written beside imajev_*" '! grep -qE "\"jev_(status|route|input|reason)\"" <<<"$row"' "$row"
check "no experiment tag set: the field is omitted" '! grep -q imajev_experiment_tag <<<"$row"' "$row"
r=$(FABLE_IMAJEV_EXPERIMENT_TAG=mlx-4b-rot4-cal dual off shadow "$MIDDLE")
check "FABLE_IMAJEV_EXPERIMENT_TAG is logged and changes nothing else" '[ "$(field "$r" imajev_experiment_tag)|$(field "$r" actual_route)" = "mlx-4b-rot4-cal|luna_high" ]' "$r"
imajev_says '{"conf":0.5}'
r=$(dual off shadow "$MIDDLE")
check "low confidence: shadow, reason low_confidence, would_accept false" '[ "$(field "$r" imajev_status)|$(field "$r" imajev_reason)|$(field "$r" imajev_would_accept)|$(field "$r" actual_route)" = "shadow|low_confidence|False|luna_high" ]' "$r"
r=$(FABLE_IMAJEV_MIN_CONFIDENCE=0.4 dual off shadow "$MIDDLE")
check "FABLE_IMAJEV_MIN_CONFIDENCE only moves would_accept" '[ "$(field "$r" imajev_would_accept)|$(field "$r" actual_route)" = "True|luna_high" ]' "$r"
imajev_says '{"choice":"sol_high","conf":0.97,"abstained":true,"unknown":0.6}'
r=$(dual off shadow "$MIDDLE")
check "abstained: shadow, reason abstained, would_accept false, choice and unknown kept, route unchanged" '[ "$(field "$r" imajev_status)|$(field "$r" imajev_reason)|$(field "$r" imajev_would_accept)|$(field "$r" imajev_abstained)|$(field "$r" imajev_unknown_probability)|$(field "$r" imajev_route)|$(field "$r" actual_route)" = "shadow|abstained|False|True|0.6|sol_high|luna_high" ]' "$r"
reset_imajev
r=$(dual off shadow '{"file_count":1,"mechanical":true,"verification_available":true}')
check "obvious case: Imajev skipped too, never contacted" '[ "$(field "$r" imajev_status)|$(field "$r" actual_route)" = "skipped|luna_low" ] && [ ! -e "$STUB_IMAJEV_MARK" ] && ! grep -q imajev_input <<<"$r"' "$r"
r=$(dual shadow shadow '{"file_count":3,"prior_failures":2,"verification_available":true}')
check "hard rule (two failures): both skipped, neither contacted" '[ "$(field "$r" jev_status)|$(field "$r" imajev_status)|$(field "$r" actual_route)" = "skipped|skipped|claude_opus_high" ] && [ ! -e "$STUB_IMAJEV_MARK" ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
r=$(dual shadow shadow "$MIDDLE" --route sol_high)
check "caller override: neither model is asked, as before" '[ "$(field "$r" actual_route)|$(field "$r" decided_by)" = "sol_high|caller" ] && [ -z "$(field "$r" imajev_status)" ] && [ ! -e "$STUB_IMAJEV_MARK" ]' "$r"

echo "Imajev shadow: Jev and Imajev get the same decision"
reset_jev; reset_imajev; export STUB_CHOICE=luna_high STUB_CONF=0.9
long=$(python3 -c 'print("x"*2000)')
r=$(dual shadow shadow "{\"objective\":\"$long\",\"file_count\":4,\"verification_available\":true,\"interface_change\":true,\"diff\":\"SECRET_DIFF\",\"context_bound\":false,\"strict_scope\":true,\"opus_failed\":false}")
row=$(last_line)
check "both models called for the same ambiguous decision" '[ -e "$STUB_JEV_MARK" ] && [ -e "$STUB_IMAJEV_MARK" ]'
same_decision() {  # Jev's stdin/argv and Imajev's request body: identical state, question, options and descriptions
  python3 -c '
import json,sys
jev=json.load(open(sys.argv[1])); body=json.load(open(sys.argv[2]))
argv=jev["argv"]; jstate=json.loads(jev["stdin"])
jopts=dict(argv[i+1].split("=",1) for i,a in enumerate(argv) if a=="--option")
jq=argv[argv.index("--question")+1] if "--question" in argv else argv[1]
q=body["questions"]["answer"]
assert body["state"]==jstate, (body["state"], jstate)
assert q["criteria"]==jopts and list(q["criteria"])==list(jopts), (q["criteria"], jopts)
assert q["instructions"]==jq and q["type"]=="choice", (q, jq)
row=json.loads(sys.argv[3])
if "jev_input" in row or "imajev_input" in row:
    assert row["jev_input"]==row["imajev_input"]==jstate, row
' "$STUB_JEV_LOG" "$STUB_IMAJEV_LOG" "$1"
}
check "same state, question, options (keys, order, descriptions); jev_input == imajev_input" 'same_decision "$row"' "$row"
sent=$(cat "$STUB_IMAJEV_LOG")
check "unknown keys and rule-only flags never reach Imajev" '! grep -qE "SECRET_DIFF|context_bound|strict_scope|opus_failed|\"diff\"" <<<"$sent"' "$sent"
check "objective truncated to 280 for Imajev as for Jev" 'python3 -c "import json,sys; assert len(json.loads(sys.argv[1])[\"state\"][\"objective\"])==280" "$sent"' "$sent"
check "interface_change keeps luna_low off Imajev's options too (same floor)" 'python3 -c "import json,sys; assert list(json.loads(sys.argv[1])[\"questions\"][\"answer\"][\"criteria\"])==[\"luna_high\",\"sol_high\"]" "$sent"' "$sent"
check "the 2 KB state cap is the same for both adapters, and an oversized state never leaves the process" 'python3 -c "
import sys,os; sys.path.insert(0,\"$S\"); sys.dont_write_bytecode=True
import jev_route, imajev_route
assert imajev_route.STATE_MAX_BYTES==jev_route.STATE_MAX_BYTES==2048
r=imajev_route.classify(\"q\", {\"objective\": \"x\"*3000}, {\"a\":\"A\",\"b\":\"B\"}, 2)
assert r[\"ok\"] is False and r[\"reason\"]==\"state_too_large\", r
" && [ "$(grep -c . "$STUB_IMAJEV_MARK")" -eq 1 ]' "$(cat "$STUB_IMAJEV_MARK")"
reset_jev; reset_imajev; export STUB_CHOICE=luna_max STUB_CONF=0.9; imajev_says '{"choice":"claude_opus_high","conf":0.88}'
r=$(dual shadow shadow "$NARROW")
check "after one failure both are offered the same four routes (luna_max eligible)" 'same_decision "$(last_line)" && [ "$(offered)" = "luna_high luna_max sol_high claude_opus_high" ]' "$(offered)"
check "dual shadow: one decision id carries both answers; the route stays deterministic" '[ "$(field "$r" jev_route)|$(field "$r" imajev_route)|$(field "$r" actual_route)|$(field "$r" decided_by)|$(field "$r" policy_version)" = "luna_max|claude_opus_high|luna_high|legacy|5.5.0" ] && [ "$(grep -c "\"id\":\"$(field "$r" id)\"" "$FABLE_LEDGER")" -eq 1 ]' "$r"

echo "Imajev shadow: failures cost only Imajev's answer"
reset_jev; export STUB_CHOICE=sol_high STUB_CONF=0.9
fails() {  # fails <label> <expected reason> [env assignments...]: Imajev fails, Jev is recorded, route unchanged
  local label=$1 want=$2; shift 2
  local out; out=$(env "$@" FABLE_JEV_MODE=shadow FABLE_IMAJEV_MODE=shadow python3 "$S/fable-route.py" route <<<"$MIDDLE" 2>"$T/stderr")
  check "Imajev $label -> fallback $want; Jev recorded; route unchanged" '[ "$(field "$out" imajev_status)|$(field "$out" imajev_reason)|$(field "$out" jev_status)|$(field "$out" jev_route)|$(field "$out" actual_route)|$(field "$out" decided_by)" = "fallback|$want|shadow|sol_high|luna_high|legacy" ]' "$out"
  last_fail=$out
}
reset_imajev; fails "server unavailable" unavailable FABLE_IMAJEV_URL="$DEAD_URL"
check "unavailable: Imajev read nothing, so no imajev_input; Jev's input kept" '! grep -q imajev_input <<<"$(last_line)" && grep -q "\"jev_input\"" <<<"$(last_line)"' "$(last_line)"
imajev_says '{"delay":4}'
t0=$(python3 -c 'import time; print(time.time())')
fails "timeout" timeout FABLE_IMAJEV_TIMEOUT=1
t1=$(python3 -c 'import time; print(time.time())')
check "timeout: the wait is bounded by FABLE_IMAJEV_TIMEOUT" 'python3 -c "import sys; sys.exit(0 if float(sys.argv[2])-float(sys.argv[1]) < 3.5 else 1)" "$t0" "$t1"' "$t0 $t1"
imajev_says '{"mode":"malformed"}';        fails "malformed JSON" malformed
imajev_says '{"mode":"notjson_object"}';   fails "a non-object body" malformed
imajev_says '{"mode":"noanswer"}';         fails "missing answer" missing_answer
imajev_says '{"mode":"noconf"}';           fails "missing confidence" no_confidence
imajev_says '{"mode":"http500"}';          fails "HTTP 500" http_500
imajev_says '{"mode":"http422"}';          fails "HTTP 422 (request refused)" http_422
imajev_says '{"choice":"gpt_ultra","conf":0.99}'; fails "unknown choice" unknown_choice
check "unknown choice: the off-list answer stays visible" '[ "$(field "$last_fail" imajev_route)" = gpt_ultra ]' "$last_fail"
reset_imajev; fails "wrong path" http_404 FABLE_IMAJEV_URL="${IMAJEV_URL%/v1/systemone}/v1/other"
fails "invalid URL" invalid_url FABLE_IMAJEV_URL="ftp://127.0.0.1/x"
fails "adapter exception (unparsable URL)" adapter_error FABLE_IMAJEV_URL="http://[::1"
reset_jev; reset_imajev; imajev_says '{"choice":"sol_high","conf":0.9}'
r=$(STUB_JEV=malformed dual shadow shadow "$MIDDLE")
check "Jev fails, Imajev answers: Jev fallback, Imajev recorded, route unchanged" '[ "$(field "$r" jev_status)|$(field "$r" jev_reason)|$(field "$r" imajev_status)|$(field "$r" imajev_route)|$(field "$r" actual_route)" = "fallback|malformed|shadow|sol_high|luna_high" ]' "$r"
r=$(PATH="$BASE" FABLE_IMAJEV_URL="$DEAD_URL" dual shadow shadow "$MIDDLE")
check "both fail: deterministic route, as before" '[ "$(field "$r" jev_reason)|$(field "$r" imajev_reason)|$(field "$r" actual_route)|$(field "$r" decided_by)" = "executable_missing|unavailable|luna_high|legacy" ]' "$r"

echo "Imajev shadow: concurrent with Jev"
reset_jev; reset_imajev; export STUB_CHOICE=luna_high STUB_CONF=0.9; imajev_says '{"delay":1.5,"choice":"sol_high"}'
t0=$(python3 -c 'import time; print(time.time())')
r=$(STUB_JEV_DELAY=1.5 dual shadow shadow "$MIDDLE")
t1=$(python3 -c 'import time; print(time.time())')
check "Jev 1.5 s + Imajev 1.5 s cost about 1.5 s, not 3 s; both answers logged" 'python3 -c "import sys; sys.exit(0 if float(sys.argv[2])-float(sys.argv[1]) < 2.7 else 1)" "$t0" "$t1" && [ "$(field "$r" jev_route)|$(field "$r" imajev_route)" = "luna_high|sol_high" ]' "$t0 $t1 $r"

echo "Imajev shadow: Jev active behaves exactly as before"
reset_jev; reset_imajev; export STUB_CHOICE=luna_low STUB_CONF=0.91; imajev_says '{"choice":"sol_high","conf":0.99}'
a=$(route active "$MIDDLE"); b=$(dual active shadow "$MIDDLE")
jev_view() {  # everything Jev decides or logs, minus its latency
  python3 -c 'import json,sys; r=json.loads(sys.argv[1]); keep=("actual_route","decided_by","model","effort","legacy_route","floor","rule")
print(json.dumps({k: v for k, v in r.items() if (k.startswith("jev_") and k != "jev_latency_ms") or k in keep}, sort_keys=True))' "$1"
}
check "active Jev + Imajev shadow: same Jev fields, same adopted route as without Imajev" '[ "$(jev_view "$a")" = "$(jev_view "$b")" ] && [ "$(field "$b" actual_route)|$(field "$b" decided_by)|$(field "$b" imajev_route)" = "luna_low|jev|sol_high" ]' "$a // $b"
r=$(STUB_CONF=0.5 dual active shadow "$MIDDLE")
check "active Jev unsure + Imajev confident (0.99): deterministic route, Imajev never adopted" '[ "$(field "$r" actual_route)|$(field "$r" decided_by)|$(field "$r" jev_reason)|$(field "$r" imajev_would_accept)" = "luna_high|legacy|low_confidence|True" ]' "$r"
r=$(FABLE_IMAJEV_URL="$DEAD_URL" dual active shadow "$MIDDLE")
check "active Jev with Imajev down: Jev still adopted" '[ "$(field "$r" actual_route)|$(field "$r" decided_by)|$(field "$r" imajev_reason)" = "luna_low|jev|unavailable" ]' "$r"

echo "Imajev shadow: review gate"
reset_jev; reset_imajev; export STUB_CHOICE=self_review STUB_CONF=0.9; imajev_says '{"choice":"opus_review","conf":0.93}'
review2() { printf '%s' "$3" | FABLE_JEV_MODE=$1 FABLE_IMAJEV_MODE=$2 python3 "$S/fable-route.py" review --id "${4:-}" 2>/dev/null; }
v=$(review2 shadow shadow '{"file_count":5,"lines_changed":900,"verification_passed":true,"architectural_deadlock":false}')
check "ambiguous review: both asked the same question/state/options; Imajev's opus_review logged, review unchanged" 'same_decision "$(last_line)" && [ "$(field "$v" review)|$(field "$v" review_decided_by)|$(field "$v" jev_route)|$(field "$v" imajev_route)|$(field "$v" imajev_status)" = "self_review|legacy|self_review|opus_review|shadow" ] && ! grep -q architectural_deadlock "$STUB_IMAJEV_LOG"' "$v"
check "review options for Imajev are self_review/opus_review only" 'python3 -c "import json,sys; assert list(json.load(open(sys.argv[1]))[\"questions\"][\"answer\"][\"criteria\"])==[\"self_review\",\"opus_review\"]" "$STUB_IMAJEV_LOG"'
check "review rows log no state for either model (unchanged)" '! grep -qE "\"(jev|imajev)_input\"" <<<"$(last_line)"' "$(last_line)"
STUB_CHOICE=opus_review STUB_CONF=0.4 v=$(review2 active shadow '{"file_count":5,"lines_changed":900,"verification_passed":true}')
check "active Jev unsure on review, Imajev sure of opus_review: still self_review" '[ "$(field "$v" review)|$(field "$v" review_decided_by)|$(field "$v" imajev_route)" = "self_review|legacy|opus_review" ]' "$v"
imajev_says '{"choice":"fable_review","conf":0.99}'
v=$(review2 off shadow '{"file_count":5,"lines_changed":900,"verification_passed":true}')
check "Imajev cannot even propose fable_review: unknown_choice" '[ "$(field "$v" imajev_reason)|$(field "$v" review)" = "unknown_choice|self_review" ]' "$v"
reset_jev; reset_imajev
v=$(review2 shadow shadow '{"file_count":3,"security_sensitive":true,"verification_passed":true}')
check "obvious review: both skipped, neither contacted" '[ "$(field "$v" jev_status)|$(field "$v" imajev_status)|$(field "$v" review)" = "skipped|skipped|opus_review" ] && [ ! -e "$STUB_IMAJEV_MARK" ] && [ ! -e "$STUB_JEV_MARK" ]' "$v"
export STUB_CHOICE=luna_low STUB_CONF=0.91; imajev_says '{"choice":"sol_high"}'
r=$(dual shadow shadow "$MIDDLE"); id=$(field "$r" id)
imajev_says '{"choice":"opus_review"}'
review2 shadow shadow '{"file_count":4,"lines_changed":300,"verification_passed":true}' "$id" >/dev/null
o=$(python3 "$S/fable-route.py" outcome --id "$id" --outcome success)
check "outcome carries the decision's imajev_* and the review's as review_imajev_*" '[ "$(field "$o" imajev_route)|$(field "$o" jev_route)|$(field "$o" review_imajev_route)|$(field "$o" review_jev_route)" = "sol_high|luna_low|opus_review|luna_low" ]' "$o"

echo "Imajev shadow: backfill"
reset_jev; reset_imajev; export STUB_CHOICE=luna_high STUB_CONF=0.9; imajev_says '{"choice":"sol_high","conf":0.95}'
b=$(FABLE_JEV_MODE=shadow FABLE_IMAJEV_MODE=shadow python3 "$S/fable-route.py" backfill --model gpt-6-luna --effort max --file-count 4 --objective "Tidy helpers" --verification)
check "backfill: both answers logged beside the observed route; backfilled/decided_by unchanged" '[ "$(field "$b" backfilled)|$(field "$b" decided_by)|$(field "$b" actual_route)|$(field "$b" jev_route)|$(field "$b" imajev_route)" = "True|lane|luna_max|luna_high|sol_high" ] && same_decision "$b"' "$b"
b=$(FABLE_JEV_MODE=active FABLE_IMAJEV_MODE=shadow python3 "$S/fable-route.py" backfill --model gpt-6-luna --effort high --file-count 4)
check "backfill under active Jev: both log-only, the lane's route stands" '[ "$(field "$b" jev_status)|$(field "$b" imajev_status)|$(field "$b" actual_route)" = "shadow|shadow|luna_high" ]' "$b"
b=$(FABLE_JEV_MODE=off FABLE_IMAJEV_MODE=shadow python3 "$S/fable-route.py" backfill --model gpt-6-luna --effort low --file-count 1 --verification)
check "backfill with Jev off: Imajev alone is logged, no jev_* answer" '[ "$(field "$b" imajev_status)|$(field "$b" actual_route)|$(field "$b" jev_mode)" = "shadow|luna_low|off" ] && ! grep -qE "\"jev_(status|route|input)\"" <<<"$b"' "$b"

echo "Imajev shadow: report"
H2H="$T/h2h.jsonl"
{ D='"event":"decision","policy_version":"5.5.0","jev_mode":"shadow","imajev_mode":"shadow","legacy_route":"luna_high","actual_route":"luna_high"'
  echo "{$D,\"id\":\"h1\",\"jev_status\":\"shadow\",\"jev_route\":\"luna_high\",\"jev_confidence\":0.9,\"jev_latency_ms\":400,\"jev_would_accept\":true,\"jev_input\":{\"file_count\":4,\"multi_component\":true},\"imajev_status\":\"shadow\",\"imajev_route\":\"sol_high\",\"imajev_confidence\":0.85,\"imajev_latency_ms\":100,\"imajev_would_accept\":true,\"imajev_abstained\":false,\"imajev_unknown_probability\":0.02,\"imajev_probabilities\":{\"luna_high\":0.1,\"sol_high\":0.88,\"luna_low\":0.02},\"imajev_input\":{\"file_count\":4,\"multi_component\":true},\"imajev_experiment_tag\":\"mlx-4b-rot4-cal\",\"imajev_model\":\"imajev-4b\"}"
  echo '{"event":"attempt","id":"h1","policy_version":"5.5.0","lane_status":"ok","duration_s":100,"model":"gpt-6-luna","effort":"high"}'
  echo '{"event":"outcome","id":"h1","policy_version":"5.5.0","actual_route":"luna_high","jev_status":"shadow","jev_route":"luna_high","imajev_status":"shadow","imajev_route":"sol_high","outcome":"success","attempts":1}'
  echo "{$D,\"id\":\"h2\",\"jev_status\":\"shadow\",\"jev_route\":\"luna_high\",\"jev_confidence\":0.95,\"jev_latency_ms\":300,\"jev_input\":{\"file_count\":2},\"imajev_status\":\"shadow\",\"imajev_route\":\"luna_high\",\"imajev_confidence\":0.95,\"imajev_latency_ms\":200,\"imajev_would_accept\":true,\"imajev_abstained\":false,\"imajev_unknown_probability\":0.01,\"imajev_input\":{\"file_count\":2},\"imajev_experiment_tag\":\"mlx-4b-rot4-cal\"}"
  echo "{$D,\"id\":\"h3\",\"jev_status\":\"shadow\",\"jev_route\":\"sol_high\",\"jev_confidence\":0.8,\"jev_latency_ms\":600,\"jev_input\":{\"file_count\":2},\"imajev_status\":\"shadow\",\"imajev_reason\":\"abstained\",\"imajev_route\":\"luna_high\",\"imajev_confidence\":0.3,\"imajev_latency_ms\":150,\"imajev_would_accept\":false,\"imajev_abstained\":true,\"imajev_unknown_probability\":0.7,\"imajev_input\":{\"file_count\":2},\"imajev_experiment_tag\":\"mlx-4b-rot1-cal\"}"
  echo "{$D,\"id\":\"h4\",\"backfilled\":true,\"jev_status\":\"fallback\",\"jev_reason\":\"timeout\",\"imajev_status\":\"shadow\",\"imajev_route\":\"luna_low\",\"imajev_confidence\":0.9,\"imajev_latency_ms\":90,\"imajev_would_accept\":true,\"imajev_abstained\":false}"
  echo "{$D,\"id\":\"h5\",\"jev_status\":\"shadow\",\"jev_route\":\"luna_high\",\"jev_confidence\":0.9,\"jev_latency_ms\":350,\"imajev_status\":\"fallback\",\"imajev_reason\":\"unavailable\",\"imajev_latency_ms\":2}"
  echo "{$D,\"id\":\"h6\",\"jev_status\":\"skipped\",\"imajev_status\":\"skipped\"}"
  echo '{"event":"review","id":"h1","policy_version":"5.5.0","legacy_review":"self_review","review":"self_review","jev_status":"shadow","jev_route":"self_review","imajev_status":"shadow","imajev_route":"opus_review","imajev_confidence":0.9}'
  echo '{"event":"decision","id":"o1","policy_version":"5.4.0","legacy_route":"luna_high","actual_route":"luna_high","jev_status":"shadow","jev_route":"luna_high","imajev_status":"shadow","imajev_route":"sol_high","imajev_confidence":0.9}'
} > "$H2H"
rep=$(python3 "$S/routing-report.py" --ledger "$H2H" --json 2>&1); rc=$?
check "report reads Imajev rows" '[ $rc -eq 0 ]' "$rep"
check "the jev block keeps exactly its pre-Imajev keys and numbers" 'python3 -c "
import json,sys; j=json.loads(sys.argv[1])[\"current_policy\"][\"jev\"]
assert set(j)=={\"consulted\",\"consulted_on_backfill\",\"skipped_obvious\",\"status\",\"fallback_reasons\",\"jev_recommendation_distribution\",\"agreement_with_legacy\",\"disagreements\",\"would_accept_in_active\",\"avg_latency_ms\",\"recommendation_by_input\"}, set(j)
assert j[\"consulted\"]==5 and j[\"skipped_obvious\"]==1 and j[\"fallback_reasons\"]=={\"timeout\":1}, j
" "$rep"' "$rep"
check "imajev block: consulted, responses, fallbacks, distribution, agreement, confidence, latency, abstain, unknown, buckets" 'python3 -c "
import json,sys; i=json.loads(sys.argv[1])[\"current_policy\"][\"imajev\"]
assert i[\"consulted\"]==5 and i[\"successful_responses\"]==4 and i[\"skipped_obvious\"]==1 and i[\"consulted_on_backfill\"]==1, i
assert i[\"fallback_reasons\"]=={\"unavailable\":1} and i[\"shadow_reasons\"]=={\"abstained\":1}, i
assert i[\"imajev_recommendation_distribution\"]=={\"sol_high\":1,\"luna_high\":2,\"luna_low\":1}, i
assert i[\"agreement_with_legacy\"]==0.5 and i[\"would_accept_in_active\"]==0.75 and i[\"abstain_rate\"]==0.25, i
assert i[\"avg_latency_ms\"]==135.0 and i[\"avg_confidence\"]==0.75 and i[\"avg_unknown_probability\"]==0.24, i
assert i[\"avg_top2_margin\"]==0.78 and sum(b[\"n\"] for b in i[\"confidence_buckets\"])==4, i
assert i[\"recommendation_by_input\"][\"multi_component\"][\"true\"]=={\"sol_high\":1}, i
assert set(i[\"by_experiment_tag\"])=={\"mlx-4b-rot4-cal\",\"mlx-4b-rot1-cal\",\"(untagged)\"} and i[\"by_experiment_tag\"][\"mlx-4b-rot4-cal\"][\"agreement_with_jev\"]==0.5, i
assert i[\"shadow_disagreement_lanes\"][\"imajev=sol_high ran=luna_high\"][\"first_try_ok\"]==1.0, i
assert i[\"shadow_disagreement_outcomes\"][\"imajev=sol_high ran=luna_high\"][\"success_rate\"]==1.0, i
" "$rep"' "$rep"
check "head-to-head: both consulted/answered, agreement, pairs, latency, confidence, abstain, one-sided answers" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"current_policy\"][\"decision_model_comparison\"]
assert c[\"both_consulted\"]==5 and c[\"both_answered\"]==3 and c[\"same_recommendation\"]==1 and c[\"different_recommendation\"]==2, c
assert c[\"agreement_rate\"]==0.333 and c[\"route_pairs\"]=={\"jev=luna_high imajev=sol_high\":1,\"jev=luna_high imajev=luna_high\":1,\"jev=sol_high imajev=luna_high\":1}, c
assert c[\"avg_latency_ms\"]=={\"jev\":433.33,\"imajev\":150.0} and c[\"avg_confidence\"]=={\"jev\":0.88,\"imajev\":0.7}, c
assert c[\"imajev_abstain_rate\"]==0.333 and c[\"only_jev_answered\"]==1 and c[\"only_imajev_answered\"]==1, c
assert c[\"agreement_by_input\"][\"file_count\"][\"2-3\"]=={\"n\":2,\"agreement_rate\":0.5}, c
assert c[\"disagreement_evidence\"][\"jev=luna_high imajev=sol_high ran=luna_high\"]=={\"n\":1,\"lane_first_try_ok\":1.0,\"outcome_success_rate\":1.0}, c
assert \"ran=\" in c[\"note\"]
" "$rep"' "$rep"
check "no accuracy is claimed for either model anywhere in the report" '! grep -qi accuracy <<<"$rep"'
check "Imajev data is segmented by policy version like everything else" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1])
assert d[\"by_policy_version\"][\"5.4.0\"][\"imajev\"][\"consulted\"]==1 and d[\"current_policy\"][\"imajev\"][\"consulted\"]==5
assert d[\"by_policy_version\"][\"5.4.0\"][\"decision_model_comparison\"][\"both_answered\"]==1
" "$rep"' "$rep"
check "review: Imajev recommendations and Jev-vs-Imajev on review decisions" 'python3 -c "
import json,sys; v=json.loads(sys.argv[1])[\"current_policy\"][\"review\"]
assert v[\"imajev_recommendation_distribution\"]=={\"opus_review\":1} and v[\"imajev_disagreements\"]=={\"self_review->opus_review\":1}, v
assert v[\"model_comparison\"][\"both_answered\"]==1 and v[\"model_comparison\"][\"agreement_rate\"]==0.0, v
assert v[\"jev_recommendation_distribution\"]=={\"self_review\":1}, v
" "$rep"' "$rep"
rep=$(python3 "$S/routing-report.py" --ledger "$MIX" --json)
check "a ledger with no Imajev rows reports an empty imajev block" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"current_policy\"]
assert c[\"imajev\"][\"consulted\"]==0 and c[\"decision_model_comparison\"][\"both_consulted\"]==0, c[\"imajev\"]
" "$rep"' "$rep"
txt=$(python3 "$S/routing-report.py" --ledger "$H2H"); rc=$?
check "text report renders imajev and decision_model_comparison" '[ $rc -eq 0 ] && grep -q "^  imajev:" <<<"$txt" && grep -q "^  decision_model_comparison:" <<<"$txt"' "$txt"
rep=$(python3 "$S/routing-report.py" --json)
check "the live ledger's report (this suite's rows) joins Imajev answers" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"current_policy\"]
assert c[\"imajev\"][\"successful_responses\"]>=5 and c[\"decision_model_comparison\"][\"both_answered\"]>=3, c[\"imajev\"]
" "$rep"' "$rep"
unset FABLE_IMAJEV_URL; reset_jev; reset_imajev

echo "Codex lane"
PATH="$CODEXBIN:$BASE"
export STUB_ARGV_DIR="$T/argv"; mkdir -p "$STUB_ARGV_DIR"
mkrepo() {
  local d=$1; mkdir -p "$d/src" "$d/docs"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t
    echo "def add(a,b): return 0" > src/calc.py; echo "def mul(a,b): return 0" > src/mul.py
    echo "docs" > docs/README.md; git add -A && git commit -q -m init
    echo "OTHER LANE UNCOMMITTED WORK" >> docs/README.md )
}
spec() { printf 'Objective: fix it.\nFiles: %s\n' "$1" > "$2"; }
argv_has() { grep -rqxF -- "$1" "$STUB_ARGV_DIR"; }
# A lane whose output equals the tree is an empty diff and removes itself.
discard() { local w; w=$(awk '/worktree:/{print $2; exit}' <<<"$1"); [ -n "$w" ] && [ -d "$w" ] && git -C "$REPO" worktree remove --force "$w"; rm -f "$w.codex-stderr.log"; }
REPO="$T/repo"; mkrepo "$REPO"; spec src/calc.py "$T/spec1"; spec src/net.py "$T/spec-net"
snap() { ( cd "$REPO" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cat | cksum ); }
before=$(snap)
out=$("$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null); rc=$?
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
check "lane succeeds (rc 0)" '[ $rc -eq 0 ]' "$out"
check "default: --model gpt-6-luna, effort high" 'argv_has gpt-6-luna && argv_has model_reasoning_effort=high'
check "LANE REPORT names model and effort" 'grep -q "model:    gpt-6-luna" <<<"$out" && grep -q "effort:   high" <<<"$out"'
check "codex ran in the worktree, not the repo" 'argv_has "$wt" && ! argv_has "$REPO"'
check "main tree untouched until apply (incl. uncommitted work)" '[ "$(snap)" = "$before" ]'
check "transcript goes to a log; only a tail is replayed" 'grep -q "log: " <<<"$out" && [ -f "$wt.codex-stderr.log" ]'
"$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --files src/calc.py --remove >/dev/null
check "apply lands the lane's file" 'grep -q "return a + b" "$REPO/src/calc.py"'
check "apply --remove also removes the transcript log" '[ ! -e "$wt" ] && [ ! -e "$wt.codex-stderr.log" ]'
check "co-resident uncommitted work survives" 'grep -q "OTHER LANE UNCOMMITTED WORK" "$REPO/docs/README.md"'

rm -f "${STUB_ARGV_DIR:?}"/*
rmx=$(route off '{"file_count":1,"verification_available":true,"prior_failures":1}' --route luna_max)
spec src/maxed.py "$T/spec-max"
out=$("$S/codex-lane.sh" --spec "$T/spec-max" --files src/maxed.py --repo "$REPO" --model "$(field "$rmx" model)" --effort "$(field "$rmx" effort)" --route-id "$(field "$rmx" id)" 2>/dev/null); rc=$?
a=$(grep "\"id\":\"$(field "$rmx" id)\"" "$FABLE_LEDGER" | grep '"event":"attempt"' | tail -n 1)
check "luna_max lane: codex gets --model gpt-6-luna and effort max, attempt row says so" '[ $rc -eq 0 ] && argv_has gpt-6-luna && argv_has model_reasoning_effort=max && [ "$(field "$a" model)/$(field "$a" effort)" = gpt-6-luna/max ]' "$out $a"
discard "$out"
rm -f "$STUB_ARGV_DIR"/*
out=$("$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --model gpt-6-sol --effort xhigh 2>/dev/null)
check "caller --model/--effort override reaches codex" 'argv_has gpt-6-sol && argv_has model_reasoning_effort=xhigh && ! argv_has gpt-6-luna'
discard "$out"
rm -f "$STUB_ARGV_DIR"/*
out=$(FABLE_CODEX_DEFAULT_MODEL=gpt-7-luna FABLE_CODEX_DEFAULT_EFFORT=medium "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null)
check "config env changes the default without editing the script" 'argv_has gpt-7-luna && argv_has model_reasoning_effort=medium'
discard "$out"

n0=$(git -C "$REPO" worktree list | wc -l)
"$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --effort ultra >/dev/null 2>&1; rc=$?
check "effort 'ultra' (auto-delegation) is refused before any worktree" '[ $rc -eq 5 ] && [ "$(git -C "$REPO" worktree list | wc -l)" -eq "$n0" ]'
"$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --model 'gpt 6; rm' >/dev/null 2>&1; rc=$?
check "malformed model slug is refused" '[ $rc -eq 5 ]'
out=$(PATH="$BASE" "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null); rc=$?
check "codex missing -> exit 3 (unavailable)" '[ $rc -eq 3 ] && grep -q unavailable <<<"$out"' "$out"
out=$(STUB_CODEX=quota "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null); rc=$?
check "quota exhaustion -> exit 3 with the reset message, worktree removed" '[ $rc -eq 3 ] && grep -q "Try again at" <<<"$out" && [ "$(git -C "$REPO" worktree list | wc -l)" -eq "$n0" ]' "$out"
out=$(STUB_CODEX=badmodel "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --model gpt-9 2>/dev/null); rc=$?
check "model not available to the account -> exit 3" '[ $rc -eq 3 ]' "$out"
printf 'Objective: add authentication retry and rate limit handling; respect quota.\nFiles: src/calc.py\n' > "$T/spec-auth"
out=$(STUB_CODEX=crash "$S/codex-lane.sh" --spec "$T/spec-auth" --files src/calc.py --repo "$REPO" 2>/dev/null); rc=$?
check "a spec about auth/rate limits is not misread as codex unavailable" '[ $rc -eq 1 ]' "$out"
out=$(STUB_CODEX=quota "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null)
check "exit 3 keeps the log as evidence" '[ -f "$(awk "/log:/{print \$2; exit}" <<<"$out")" ]' "$out"
out=$(STUB_CODEX=nothing "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null); rc=$?
check "empty diff -> exit 1, worktree removed" '[ $rc -eq 1 ] && [ "$(git -C "$REPO" worktree list | wc -l)" -eq "$n0" ]' "$out"
out=$(STUB_CODEX=sleep "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --timeout 1 2>/dev/null); rc=$?
check "timeout -> exit 4, worktree kept for resume" '[ $rc -eq 4 ] && [ -d "$(awk "/worktree:/{print \$2; exit}" <<<"$out")" ]' "$out"
discard "$out"
rid2=$(field "$(route off "$MIDDLE" --task "net down")" id)
out=$(STUB_CODEX=netdown "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --timeout 2 --route-id "$rid2" 2>/dev/null); rc=$?
check "no network to the API -> exit 3 (unavailable), not a timeout to resume" '[ $rc -eq 3 ] && grep -q "unavailable — network" <<<"$out" && grep -q "Proxy connection failed" <<<"$out"' "$out"
check "network failure keeps the log, removes the empty worktree" '[ -f "$(awk "/log:/{print \$2; exit}" <<<"$out")" ] && [ "$(git -C "$REPO" worktree list | wc -l)" -eq "$n0" ]' "$out"
a=$(grep "\"id\":\"$rid2\"" "$FABLE_LEDGER" | grep '"event":"attempt"' | tail -n 1)
check "network failure is recorded as unavailable with its cause" '[ "$(field "$a" lane_status)" = unavailable ] && grep -q "network" <<<"$(field "$a" reason)"' "$a"
out=$(STUB_CODEX=netdown_after_write "$S/codex-lane.sh" --spec "$T/spec-net" --files src/net.py --repo "$REPO" --timeout 2 2>/dev/null); rc=$?
check "network lost after work landed -> still a timeout, worktree kept to resume" '[ $rc -eq 4 ] && [ -d "$(awk "/worktree:/{print \$2; exit}" <<<"$out")" ]' "$out"
discard "$out"

echo "Lane attempts are recorded automatically"
rid=$(field "$(STUB_CHOICE=luna_low STUB_CONF=0.91 PATH="$JEVBIN:$PATH" route shadow "$MIDDLE" --task "attempt test")" id)
att() { grep "\"event\":\"attempt\"" "$FABLE_LEDGER" | grep "\"id\":\"$rid\"" | sed -n "${1}p"; }
spec src/mul.py "$T/spec-mul"
out=$(STUB_CODEX=quota "$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" --route-id "$rid" 2>/dev/null)
a=$(att 1)
check "an unavailable run is recorded with its reason" '[ "$(field "$a" lane_status)/$(field "$a" attempt)" = unavailable/1 ] && grep -q "usage limit" <<<"$(field "$a" reason)"' "$a"
out=$("$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" --route-id "$rid" 2>/dev/null)
a=$(att 2)
check "a successful run is recorded: status, attempt no., model, effort, touched" '[ "$(field "$a" lane_status)|$(field "$a" attempt)|$(field "$a" model)|$(field "$a" effort)|$(field "$a" touched)|$(field "$a" scope_violations)" = "ok|2|gpt-6-luna|high|1|0" ] && [ -n "$(field "$a" duration_s)" ]' "$a"
check "recording does not change the lane report or exit" 'grep -q "LANE REPORT" <<<"$out" && ! grep -q "\"event\"" <<<"$out"' "$out"
discard "$out"
"$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" --route-id "$rid" --effort ultra >/dev/null 2>&1
a=$(att 3)
check "a refused run (bad effort) is recorded as blocked" '[ "$(field "$a" lane_status)/$(field "$a" rc)" = blocked/5 ]' "$a"
out=$(STUB_CODEX=violation "$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" --route-id "$rid" 2>/dev/null)
a=$(att 4)
check "scope violations are counted in the attempt row" '[ "$(field "$a" scope_violations)" = 1 ]' "$a"
discard "$out"
n=$(wc -l < "$FABLE_LEDGER")
"$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" --route-id 'bad id;rm' >/dev/null 2>&1; rc=$?
check "a malformed --route-id is refused and writes nothing" '[ $rc -eq 5 ] && [ "$(wc -l < "$FABLE_LEDGER")" -eq "$n" ]'
out=$(FABLE_LEDGER=off "$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" --route-id "$rid" 2>/dev/null); rc=$?
check "ledger off: the lane still runs and writes no row" '[ $rc -eq 0 ] && [ "$(wc -l < "$FABLE_LEDGER")" -eq "$n" ]' "$out"
discard "$out"
out=$(PATH="$BASE" "$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" 2>/dev/null); rc=$?
u=$(tail -n 1 "$FABLE_LEDGER")
check "without --route-id the run is still recorded, as unrouted" '[ $rc -eq 3 ] && [ "$(field "$u" unrouted)" = True ] && [ "$(field "$u" event)" = attempt ]' "$u"
d=$(grep "\"id\":\"$(field "$u" id)\"" "$FABLE_LEDGER" | grep '"event":"decision"' | tail -n 1)
check "an unrouted run gets a backfilled decision under the same id" '[ "$(field "$d" backfilled)" = True ] && [ "$(field "$d" jev_reason)" = executable_missing ]' "$d"
o=$(python3 "$S/fable-route.py" outcome --id "$rid" --outcome success)
check "outcome fills attempts and duration from lane rows" '[ "$(field "$o" attempts)" = 4 ] && [ -n "$(field "$o" duration_s)" ]' "$o"
rep=$(python3 "$S/routing-report.py" --json)
check "report shows lane attempts per route and shadow disagreements from lanes" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1])[\"current_policy\"]; l=d[\"lane_attempts\"][\"by_route\"][\"luna_high\"]
assert l[\"n\"]>=1 and l[\"avg_attempts\"]>=1, l
assert any(k.startswith(\"jev=luna_low ran=luna_high\") for k in d[\"shadow_disagreement_lanes\"]), d[\"shadow_disagreement_lanes\"]
" "$rep"' "$rep"
check "report shows compliance: routed rate, unrouted runs, outcome rates, open decisions" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"current_policy\"][\"compliance\"]
assert c[\"unrouted_lane_runs\"]>=1 and 0<c[\"routed_lane_run_rate\"]<1, c
assert c[\"outcome_rate\"] is not None and c[\"outcome_rate_codex_routes\"] is not None, c
assert c[\"codex_decisions_without_lane_run\"]>=1 and c[\"open_decisions_recent\"], c
" "$rep"' "$rep"

echo "Unrouted lanes are backfilled"
PATH="$JEVBIN:$CODEXBIN:$BASE"; reset_jev; rm -f "$STUB_ARGV_DIR"/*
printf '## Objective\nAdd rounding to the price formatter\n\nFiles: src/mul.py\n\n## Verification\npytest -q\n' > "$T/spec-bf"
dec() { grep '"event":"decision"' "$FABLE_LEDGER" | grep "\"id\":\"$1\"" | tail -n 1; }
last_attempt() { grep '"event":"attempt"' "$FABLE_LEDGER" | tail -n 1; }
out=$(STUB_CHOICE=sol_high STUB_CONF=0.95 "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null); rc=$?
a=$(last_attempt); bid=$(field "$a" id); d=$(dec "$bid")
check "lane without --route-id still succeeds" '[ $rc -eq 0 ]' "$out"
check "attempt joins a backfilled decision and stays unrouted" '[ "$(field "$a" unrouted)" = True ] && [ "$(field "$d" backfilled)" = True ] && ! grep -q "^unrouted-" <<<"$bid"' "$a / $d"
check "shadow Jev answer is logged beside the route that ran" '[ "$(field "$d" jev_status)|$(field "$d" jev_route)|$(field "$d" actual_route)|$(field "$d" decided_by)|$(field "$d" model)" = "shadow|sol_high|luna_high|lane|gpt-6-luna" ]' "$d"
check "objective and verification are read off the spec" '[ "$(field "$d" task)" = "Add rounding to the price formatter" ] && [ "$(field "$d" floor)" = luna_low ]' "$d"
check "Jev sees the objective and file count, not the spec body" 'grep -q "Add rounding" "$STUB_JEV_LOG" && ! grep -q "pytest" "$STUB_JEV_LOG"' "$(cat "$STUB_JEV_LOG" 2>/dev/null)"
check "the backfilled decision logs that same state as jev_input" 'same_input "$d" && ! grep -q pytest <<<"$d"' "$d"
check "LANE REPORT names the backfilled route id" 'grep -q "route id: $bid" <<<"$out"' "$out"
discard "$out"
rm -f "$STUB_ARGV_DIR"/*
out=$(STUB_CHOICE=sol_high STUB_CONF=0.99 FABLE_JEV_MODE=active "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "active mode: a confident Jev still cannot change a running lane" 'argv_has gpt-6-luna && ! argv_has gpt-6-sol && [ "$(field "$d" jev_status)/$(field "$d" actual_route)" = shadow/luna_high ]' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --model gpt-6-sol --effort xhigh 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "strong model at xhigh is not passed off as sol_high: unmapped, real model/effort kept" '[ "$(field "$d" actual_route)|$(field "$d" model)|$(field "$d" effort)" = "unmapped|gpt-6-sol|xhigh" ]' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --model gpt-6-sol --effort high 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "sol high backfill -> sol_high" '[ "$(field "$d" actual_route)|$(field "$d" model)|$(field "$d" effort)" = "sol_high|gpt-6-sol|high" ]' "$d"
discard "$out"
rm -f "$STUB_ARGV_DIR"/*
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --effort max 2>/dev/null)
a=$(last_attempt); d=$(dec "$(field "$a" id)")
check "luna max backfill -> luna_max, not luna_high" '[ "$(field "$d" actual_route)|$(field "$d" effort)|$(field "$a" effort)" = "luna_max|max|max" ] && argv_has model_reasoning_effort=max' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --effort xhigh 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "luna xhigh backfill is unmapped, never folded into luna_high" '[ "$(field "$d" actual_route)|$(field "$d" effort)" = "unmapped|xhigh" ]' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --effort high 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "luna high backfill -> luna_high, policy_version on decision and attempt" '[ "$(field "$d" actual_route)|$(field "$d" policy_version)|$(field "$(last_attempt)" policy_version)" = "luna_high|5.5.0|5.5.0" ]' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --effort low 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "default model at low effort is recorded as luna_low" '[ "$(field "$d" actual_route)" = luna_low ]' "$d"
discard "$out"
reset_jev
out=$(FABLE_JEV_MODE=off "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "Jev off: decision backfilled, Jev never called" '[ "$(field "$d" backfilled)/$(field "$d" jev_mode)" = True/off ] && [ ! -e "$STUB_JEV_MARK" ] && ! grep -q "\"jev_input\"" <<<"$d"' "$d"
discard "$out"
n=$(wc -l < "$FABLE_LEDGER")
out=$(FABLE_LEDGER=off "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null); rc=$?
check "ledger off: no backfill, no Jev call, lane still runs" '[ $rc -eq 0 ] && [ ! -e "$STUB_JEV_MARK" ] && [ "$(wc -l < "$FABLE_LEDGER")" -eq "$n" ]' "$out"
discard "$out"
printf 'Objective: tidy the helpers.\nFiles: src/calc.py, src/mul.py\n' > "$T/spec-bf2"
out=$(STUB_JEV=sleep FABLE_JEV_TIMEOUT=1 "$S/codex-lane.sh" --spec "$T/spec-bf2" --files "src/calc.py, src/mul.py" --repo "$REPO" 2>/dev/null); rc=$?
d=$(dec "$(field "$(last_attempt)" id)")
check "a failing Jev only costs its answer: fallback logged, lane runs" '[ $rc -eq 0 ] && [ "$(field "$d" jev_status)" = fallback ] && [ "$(field "$d" task)" = "tidy the helpers." ]' "$d"
check "no verification line: floor stays luna_high" '[ "$(field "$d" floor)" = luna_high ]' "$d"
discard "$out"
reset_jev; reset_imajev; imajev_says '{"choice":"sol_high","conf":0.93}'; rm -f "$STUB_ARGV_DIR"/*
out=$(STUB_CHOICE=luna_high STUB_CONF=0.9 FABLE_IMAJEV_MODE=shadow FABLE_IMAJEV_URL="$IMAJEV_URL" FABLE_IMAJEV_EXPERIMENT_TAG=lane-test \
      "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null); rc=$?
d=$(dec "$(field "$(last_attempt)" id)")
check "unrouted lane + Imajev shadow: both answers on the backfilled decision, same input, the lane's model unchanged" '[ $rc -eq 0 ] && [ "$(field "$d" backfilled)|$(field "$d" decided_by)|$(field "$d" actual_route)|$(field "$d" jev_route)|$(field "$d" imajev_route)|$(field "$d" imajev_experiment_tag)" = "True|lane|luna_high|luna_high|sol_high|lane-test" ] && same_decision "$d" && argv_has gpt-6-luna && ! argv_has gpt-6-sol' "$d"
discard "$out"
rep=$(python3 "$S/routing-report.py" --json)
check "report: backfills counted, unrouted runs not counted as routed, shadow evidence joins" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1])[\"current_policy\"]; c=d[\"compliance\"]
assert c[\"backfilled_decisions\"]>=5 and c[\"routed_lane_run_rate\"]<0.5, c
assert d[\"jev\"][\"consulted_on_backfill\"]>=1, d[\"jev\"]
assert \"jev=sol_high ran=luna_high\" in d[\"shadow_disagreement_lanes\"], d[\"shadow_disagreement_lanes\"]
" "$rep"' "$rep"
PATH="$CODEXBIN:$BASE"; reset_jev

echo "Scope: expected by default, strict on request"
REPO="$T/repo2"; mkrepo "$REPO"; rm -f "$STUB_ARGV_DIR"/*
out=$(STUB_CODEX=violation "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null)
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
check "codex gets the harness preamble and the expected-scope rule before the spec" 'p=$(cat "$STUB_ARGV_DIR"/prompt.*) && grep -q "Harness notes" <<<"$p" && grep -q "expected scope" <<<"$p" && grep -q NEED_TOOL <<<"$p" && [ "$(grep -n "^Files: src/calc.py" <<<"$p" | cut -d: -f1)" -gt "$(grep -n "Harness notes" <<<"$p" | cut -d: -f1)" ]' "$(cat "$STUB_ARGV_DIR"/prompt.* 2>/dev/null)"
check "an out-of-scope path codex did not name is reported as not applied" 'grep -A1 "OUTSIDE EXPECTED SCOPE" <<<"$out" | grep -q "docs/README.md.*not named: not applied"' "$out"
"$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --remove >/dev/null
check "apply without --files lands the scope, not the unnamed path; uncommitted work intact" 'grep -q "a + b" "$REPO/src/calc.py" && grep -q "OTHER LANE UNCOMMITTED WORK" "$REPO/docs/README.md" && ! grep -q stray "$REPO/docs/README.md" && [ ! -e "$wt" ] && [ ! -e "$wt.lane" ]'

REPO="$T/repo4"; mkrepo "$REPO"
rid=$(field "$(route off '{"objective":"x","file_count":1,"verification_available":true}')" id)
out=$(STUB_CODEX=extra "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --route-id "$rid" 2>/dev/null)
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
check "an adjacent file codex names is reported as applied" 'grep -q "src/helper.py.*named by codex: applied" <<<"$out"' "$out"
a=$(grep "\"id\":\"$rid\"" "$FABLE_LEDGER" | grep '"event":"attempt"' | tail -n 1)
check "attempt row counts the out-of-scope path (same field as 5.4)" '[ "$(field "$a" scope_violations)" = 1 ] && [ -z "$(field "$a" strict_scope)" ]' "$a"
"$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --remove >/dev/null; rc=$?
check "default scope: the named adjacent file lands with the lane" '[ $rc -eq 0 ] && [ -f "$REPO/src/helper.py" ] && grep -q "a + b" "$REPO/src/calc.py"'

REPO="$T/repo5"; mkrepo "$REPO"; rm -f "$STUB_ARGV_DIR"/*
out=$(STUB_CODEX=extra "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --strict-scope --route-id "$rid" 2>/dev/null)
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
check "strict scope: codex is told the strict rule" 'grep -q "Strict scope" "$STUB_ARGV_DIR"/prompt.*'
check "strict scope: even a named extra path is a violation" 'grep -A1 "SCOPE VIOLATIONS" <<<"$out" | grep -q src/helper.py' "$out"
a=$(grep "\"id\":\"$rid\"" "$FABLE_LEDGER" | grep '"event":"attempt"' | tail -n 1)
check "strict scope is recorded on the attempt" '[ "$(field "$a" strict_scope)" = True ]' "$a"
res=$("$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --files src/calc.py,src/helper.py --remove 2>&1); rc=$?
check "strict scope: apply refuses the extra path even when named in --files, keeps the worktree" '[ $rc -eq 7 ] && grep -q "refused (strict scope): src/helper.py" <<<"$res" && [ ! -e "$REPO/src/helper.py" ] && grep -q "a + b" "$REPO/src/calc.py" && [ -d "$wt" ]' "$res"
discard "$out"; rm -f "$wt.lane" "$wt.prompt"

echo "Acceptance verification runs once, in the harness"
REPO="$T/repo6"; mkrepo "$REPO"
rid=$(field "$(route off '{"objective":"x","file_count":1,"verification_available":true}')" id)
out=$("$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --route-id "$rid" --verify "grep -q 'a + b' src/calc.py" 2>/dev/null); rc=$?
a=$(grep "\"id\":\"$rid\"" "$FABLE_LEDGER" | grep '"event":"attempt"' | tail -n 1)
check "passing acceptance: exit 0, report and attempt row say pass" '[ $rc -eq 0 ] && grep -q "verify:   pass" <<<"$out" && [ "$(field "$a" verify)|$(field "$a" lane_status)" = "pass|ok" ] && [ -n "$(field "$a" verify_s)" ]' "$out $a"
v=$(printf '{}' | FABLE_JEV_MODE=off python3 "$S/fable-route.py" review --id "$rid")
check "review gate takes verification from the lane's acceptance run" '[ "$(field "$v" verification_source)" = lane ] && [ "$(field "$v" review)" = self_review ] && [ "$(field "$v" rule)" = ordinary ]' "$v"
discard "$out"; rm -f "$(awk '/worktree:/{print $2; exit}' <<<"$out").lane"
out=$("$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --route-id "$rid" --verify "echo acceptance-output; exit 3" 2>/dev/null); rc=$?
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
a=$(grep "\"id\":\"$rid\"" "$FABLE_LEDGER" | grep '"event":"attempt"' | tail -n 1)
check "failing acceptance: exit 6, output tail shown, worktree kept, lane_status still codex's own" '[ $rc -eq 6 ] && grep -q "verify:   FAIL" <<<"$out" && grep -q acceptance-output <<<"$out" && [ -d "$wt" ] && [ "$(field "$a" verify)|$(field "$a" lane_status)" = "fail|ok" ]' "$out $a"
v=$(printf '{"file_count":1,"mechanical":true}' | FABLE_JEV_MODE=off python3 "$S/fable-route.py" review --id "$rid")
check "a failed lane acceptance never gets review none" '[ "$(field "$v" review)|$(field "$v" rule)|$(field "$v" verification_source)" = "self_review|verification_not_passed|lane" ]' "$v"
v=$(printf '{"file_count":1,"mechanical":true,"verification_passed":true}' | FABLE_JEV_MODE=off python3 "$S/fable-route.py" review --id "$rid")
check "a stated verification_passed wins over the ledger" '[ "$(field "$v" verification_source)" = caller ]' "$v"
before=$(cat "$REPO/src/calc.py")
res=$("$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --remove 2>&1); rc=$?
check "apply refuses a lane whose acceptance failed; nothing written" '[ $rc -eq 6 ] && [ "$(cat "$REPO/src/calc.py")" = "$before" ] && [ -d "$wt" ]' "$res"
res=$("$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --remove --force 2>&1); rc=$?
check "apply --force lands it anyway" '[ $rc -eq 0 ] && grep -q "a + b" "$REPO/src/calc.py"' "$res"
o=$(python3 "$S/fable-route.py" outcome --id "$rid" --outcome success --verdict fix_first --findings 2)
check "outcome records the last acceptance result and the review verdict/findings" '[ "$(field "$o" verify)|$(field "$o" review_verdict)|$(field "$o" review_findings)" = "fail|fix_first|2" ]' "$o"

echo "Apply never overwrites newer main-tree work"
REPO="$T/repo7"; mkrepo "$REPO"
out=$("$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null)
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
echo "# edited in the main tree after the lane started" >> "$REPO/src/calc.py"
res=$("$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --remove 2>&1); rc=$?
check "a path changed in the main tree since seeding is a conflict: skipped, worktree kept" '[ $rc -eq 7 ] && grep -q "CONFLICT.*src/calc.py" <<<"$res" && grep -q "edited in the main tree" "$REPO/src/calc.py" && [ -d "$wt" ]' "$res"
discard "$out"; rm -f "$wt.lane" "$wt.prompt"
out=$(STUB_CODEX=commit "$S/codex-lane.sh" --spec "$T/spec-mul" --files src/mul.py --repo "$REPO" 2>/dev/null); rc=$?
check "a codex that commits in its worktree is not misread as an empty diff" '[ $rc -eq 0 ] && grep -A1 "touched:" <<<"$out" | grep -q src/mul.py' "$out"
discard "$out"
out=$(STUB_CODEX=sleep "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" --timeout 1 2>/dev/null); rc=$?
check "timeout: the lane prints codex's handoff file itself" '[ $rc -eq 4 ] && grep -A2 "handoff:" <<<"$out" | grep -q "NEXT: write src/calc.py"' "$out"
discard "$out"

echo "Routing 5.5: strict scope, lane args, model roles"
PATH="$BASE"
r=$(route off '{"objective":"Rotate session tokens","file_count":3,"security_sensitive":true,"verification_available":true}')
check "security-sensitive work runs under strict scope, and lane_args carry it" '[ "$(field "$r" strict_scope)|$(field "$r" strict_scope_reason)" = "True|security_sensitive" ] && grep -q -- "--strict-scope" <<<"$(field "$r" lane_args)" && grep -q -- "--route-id $(field "$r" id)" <<<"$(field "$r" lane_args)"' "$r"
r=$(route off "$MIDDLE")
check "ordinary work: expected scope, no strict flag" '[ -z "$(field "$r" strict_scope)" ] && ! grep -q strict <<<"$(field "$r" lane_args)" && [ "$(field "$r" role)" = default_worker ]' "$r"
r=$(route off '{"file_count":2,"verification_available":true,"strict_scope":true}')
check "strict_scope can be requested explicitly, without changing the route" '[ "$(field "$r" strict_scope_reason)|$(field "$r" actual_route)" = "requested|luna_high" ]' "$r"
PATH="$JEVBIN:$BASE"; reset_jev; export STUB_CHOICE=luna_high STUB_CONF=0.9
route active '{"file_count":4,"verification_available":true,"strict_scope":true}' >/dev/null
check "strict_scope is never sent to Jev" '! grep -q strict_scope "$STUB_JEV_LOG"' "$(cat "$STUB_JEV_LOG")"
reset_jev; PATH="$BASE"
r=$(FABLE_SENIOR_MODEL=sonnet route off '{"file_count":3,"prior_failures":2}')
check "the senior worker's model is configuration, not code" '[ "$(field "$r" model)|$(field "$r" role)" = "sonnet|senior_worker" ]' "$r"
PLUG="$T/plugin"; mkdir -p "$PLUG"; cp -R "$ROOT/scripts" "$ROOT/agents" "$PLUG/"
sed -i.bak 's/^effort: high$/effort: medium/' "$PLUG/agents/implementer.md" "$PLUG/agents/opus-reviewer.md"
r=$(printf '%s' '{"file_count":3,"prior_failures":2}' | FABLE_JEV_MODE=off python3 "$PLUG/scripts/fable-route.py" route)
v=$(printf '%s' '{"file_count":3,"irreversible":true,"verification_passed":true}' | FABLE_JEV_MODE=off python3 "$PLUG/scripts/fable-route.py" review)
check "Opus effort is read from the agent pin: medium there is medium in the ledger" '[ "$(field "$r" effort)|$(field "$v" reviewer_effort)" = "medium|medium" ]' "$r $v"
check "the shipped pins are high (5.4-comparable default)" '[ "$(field "$(route off '"'"'{"file_count":3,"prior_failures":2}'"'"')" effort)" = high ]'
PATH="$CODEXBIN:$BASE"

echo "Prompt surfaces"
pb=$(python3 "$S/prompt-budget.py" --json); rc=$?
check "prompt-budget runs; the normal codex path stays under 4k Claude-side tokens" '[ $rc -eq 0 ] && python3 -c "
import json,sys; n=json.loads(sys.argv[1])[\"now\"]
assert n[\"normal_task_claude_tokens\"] < 4000, n[\"normal_task_claude_tokens\"]
assert n[\"paths\"][\"implement_codex\"][\"codex\"] > 0   # the lane preamble is measured, not hidden
" "$pb"' "$pb"
check "prompt-budget compares against a git revision" 'python3 "$S/prompt-budget.py" --ref HEAD >/dev/null'
check "no model versions in prompts: a model update is a config change" '! grep -nE "GPT-6|gpt-6|Opus 5|Fable 5|Luna|Sol\b" "$ROOT/skills/orchestration/SKILL.md" "$ROOT"/agents/*.md' "$(grep -nE "GPT-6|gpt-6|Opus 5|Fable 5|Luna|Sol\b" "$ROOT/skills/orchestration/SKILL.md" "$ROOT"/agents/*.md)"

echo "Concurrent lanes"
REPO="$T/repo3"; mkrepo "$REPO"; spec src/mul.py "$T/spec2"
STUB_DELAY=1 "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" >"$T/laneA" 2>/dev/null &
pa=$!
STUB_DELAY=1 "$S/codex-lane.sh" --spec "$T/spec2" --files src/mul.py --repo "$REPO" >"$T/laneB" 2>/dev/null &
pb=$!
wait $pa; ra=$?; wait $pb; rb=$?
wa=$(awk '/worktree:/{print $2; exit}' "$T/laneA"); wb=$(awk '/worktree:/{print $2; exit}' "$T/laneB")
check "two lanes run concurrently in separate worktrees" '[ $ra -eq 0 ] && [ $rb -eq 0 ] && [ -n "$wa" ] && [ "$wa" != "$wb" ]'
check "neither lane saw the other's edit" '! git -C "$wa" diff --name-only HEAD | grep -q mul.py && ! git -C "$wb" diff --name-only HEAD | grep -q calc.py'
out=$("$S/codex-lane.sh" --spec "$T/spec2" --files src/mul.py --repo "$REPO" 2>/dev/null)
check "a third lane run leaves lane A's uncommitted output intact" 'git -C "$wa" diff --name-only HEAD | grep -qx src/calc.py'
discard "$out"
"$S/codex-lane-apply.sh" --worktree "$wa" --repo "$REPO" --files src/calc.py --remove >/dev/null
"$S/codex-lane-apply.sh" --worktree "$wb" --repo "$REPO" --files src/mul.py --remove >/dev/null
check "both lanes applied; co-resident work survived" 'grep -q "a + b" "$REPO/src/calc.py" && grep -q "a + b" "$REPO/src/mul.py" && grep -q "OTHER LANE UNCOMMITTED WORK" "$REPO/docs/README.md"'

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
