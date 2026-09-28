#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2209  # variables are read inside check's eval strings
# Offline test suite: routing policy, Jev modes and fallbacks, review gate,
# ledger/report, and the codex lane's model/effort parameters and isolation.
# Uses stub `codex`, `semdecide` and `jev` binaries; needs no network, no
# credentials, and no real Codex or Jev install. Run: tests/run.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
S="$ROOT/scripts"
T=$(mktemp -d "${TMPDIR:-/tmp}/fable-tests.XXXXXX")
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT   # KEEP=1 keeps the scratch ledger for inspection
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
check "ledger row carries no jev_* fields" '! last_line | grep -qE "\"jev_(status|route|confidence|reason|backend|latency_ms|would_accept)\""' "$(last_line)"
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
check "two failures -> claude_fable, Jev skipped" '[ "$(field "$r" actual_route)/$(field "$r" lane)/$(field "$r" model)" = claude_fable/implementer/fable ] && [ ! -e "$STUB_JEV_MARK" ]' "$r"
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
check "after two failures an override below claude_fable is refused" '[ "$(field "$r" actual_route)" = claude_fable ] && [ "$(field "$r" override_rejected)" = below_risk_floor ]' "$r"
r=$(route off '{"file_count":3,"prior_failures":2,"verification_available":true}' --route self)
check "after two failures --route self is refused too" '[ "$(field "$r" actual_route)" = claude_fable ]' "$r"
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

echo "Review gate"
reset_jev; export STUB_CHOICE=none STUB_CONF=0.99
review() { printf '%s' "$2" | FABLE_JEV_MODE=$1 python3 "$S/fable-route.py" review --id "${3:-}" 2>/dev/null; }
v=$(review active '{"file_count":3,"security_sensitive":true,"verification_passed":true}')
check "high-risk -> fable_review; Jev never asked" '[ "$(field "$v" review)" = fable_review ] && [ ! -e "$STUB_JEV_MARK" ]' "$v"
v=$(review active '{"file_count":1,"mechanical":true,"verification_passed":true}')
check "one-file mechanical + passing verification -> none" '[ "$(field "$v" review)" = none ]' "$v"
v=$(review off '{"file_count":3,"verification_passed":true}')
check "ordinary change -> self_review (off)" '[ "$(field "$v" review)" = self_review ]' "$v"
v=$(STUB_CHOICE=fable_review STUB_CONF=0.95 review active '{"file_count":3,"lines_changed":240,"verification_passed":true}')
check "ambiguous middle: confident Jev escalates to fable_review" '[ "$(field "$v" review)/$(field "$v" review_decided_by)" = fable_review/jev ]' "$v"
v=$(STUB_CHOICE=fable_review STUB_CONF=0.5 review active '{"file_count":3,"verification_passed":true}')
check "ambiguous middle: unsure Jev -> self_review" '[ "$(field "$v" review)" = self_review ] && [ "$(field "$v" jev_reason)" = low_confidence ]' "$v"
v=$(review active '{"file_count":1,"mechanical":true,"verification_passed":false}')
check "failing verification never gets review none" '[ "$(field "$v" review)" = self_review ]' "$v"
STUB_CHOICE=none STUB_CONF=0.99 v=$(review active '{"file_count":60,"lines_changed":4000,"verification_passed":true}')
check "Jev can never skip review (none is not offered in the middle)" '[ "$(field "$v" review)" = self_review ] && [ "$(field "$v" jev_reason)" = unknown_choice ]' "$v"
v=$(review active '{"file_count":2,"verification_passed":true,"attempts":3}')
check "resisted two attempts -> fable_review by rule" '[ "$(field "$v" review)/$(field "$v" review_decided_by)" = fable_review/rule ]' "$v"
v=$(review off '{"file_count":1,"mechanical":true,"verification_passed":true,"silence_gap":2}')
check "a silence gap rules out review none" '[ "$(field "$v" review)" = self_review ]' "$v"

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
import json,sys; d=json.loads(sys.argv[1]); l=d[\"lane_attempts\"][\"by_route\"][\"luna_high\"]
assert l[\"n\"]>=1 and l[\"avg_attempts\"]>=1, l
assert any(k.startswith(\"jev=luna_low ran=luna_high\") for k in d[\"shadow_disagreement_lanes\"]), d[\"shadow_disagreement_lanes\"]
" "$rep"' "$rep"
check "report shows compliance: routed rate, unrouted runs, outcome rates, open decisions" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"compliance\"]
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
check "LANE REPORT names the backfilled route id" 'grep -q "route id: $bid" <<<"$out"' "$out"
discard "$out"
rm -f "$STUB_ARGV_DIR"/*
out=$(STUB_CHOICE=sol_high STUB_CONF=0.99 FABLE_JEV_MODE=active "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "active mode: a confident Jev still cannot change a running lane" 'argv_has gpt-6-luna && ! argv_has gpt-6-sol && [ "$(field "$d" jev_status)/$(field "$d" actual_route)" = shadow/luna_high ]' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --model gpt-6-sol --effort xhigh 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "strong model is recorded as sol_high" '[ "$(field "$d" actual_route)/$(field "$d" effort)" = sol_high/xhigh ]' "$d"
discard "$out"
out=$("$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" --effort low 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "default model at low effort is recorded as luna_low" '[ "$(field "$d" actual_route)" = luna_low ]' "$d"
discard "$out"
reset_jev
out=$(FABLE_JEV_MODE=off "$S/codex-lane.sh" --spec "$T/spec-bf" --files src/mul.py --repo "$REPO" 2>/dev/null)
d=$(dec "$(field "$(last_attempt)" id)")
check "Jev off: decision backfilled, Jev never called" '[ "$(field "$d" backfilled)/$(field "$d" jev_mode)" = True/off ] && [ ! -e "$STUB_JEV_MARK" ]' "$d"
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
rep=$(python3 "$S/routing-report.py" --json)
check "report: backfills counted, unrouted runs not counted as routed, shadow evidence joins" 'python3 -c "
import json,sys; d=json.loads(sys.argv[1]); c=d[\"compliance\"]
assert c[\"backfilled_decisions\"]>=5 and c[\"routed_lane_run_rate\"]<0.5, c
assert d[\"jev\"][\"consulted_on_backfill\"]>=1, d[\"jev\"]
assert \"jev=sol_high ran=luna_high\" in d[\"shadow_disagreement_lanes\"], d[\"shadow_disagreement_lanes\"]
" "$rep"' "$rep"
PATH="$CODEXBIN:$BASE"; reset_jev

echo "Isolation"
REPO="$T/repo2"; mkrepo "$REPO"
out=$(STUB_CODEX=violation "$S/codex-lane.sh" --spec "$T/spec1" --files src/calc.py --repo "$REPO" 2>/dev/null)
wt=$(awk '/worktree:/{print $2; exit}' <<<"$out")
check "scope violation is reported" 'grep -A1 "SCOPE VIOLATIONS" <<<"$out" | grep -q docs/README.md' "$out"
"$S/codex-lane-apply.sh" --worktree "$wt" --repo "$REPO" --files src/calc.py --remove >/dev/null
check "violating path is not applied; uncommitted work intact" 'grep -q "OTHER LANE UNCOMMITTED WORK" "$REPO/docs/README.md" && ! grep -q stray "$REPO/docs/README.md"'

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
