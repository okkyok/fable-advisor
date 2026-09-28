#!/usr/bin/env bash
# Run a codex lane inside a disposable git worktree.
#
# Why: `codex exec` runs outside Claude Code's PreToolUse hooks, so no hook can
# police what it writes. Scoping it with `--cd <repo toplevel>` makes the whole
# repository writable, which is how a lane ends up editing files its spec never
# listed. The cleanup for that — `git checkout -- <path>` on the main tree —
# is what destroys a co-resident lane's uncommitted work.
#
# This script removes that failure chain structurally: the lane gets its own
# worktree, so it cannot reach the main tree or another lane's tree, and undoing
# it is `git worktree remove`, never a checkout. Scope violations are contained
# and reported instead of silently landing.
#
# usage: codex-lane.sh --spec <file> --files <f1,f2,...>
#                      [--model gpt-6-luna] [--effort high] [--repo <path>] [--timeout 570]
#                      [--route-id <id from fable-route.py route>]
#                      [--verify '<acceptance command>'] [--strict-scope]
#
# --files is the lane's expected scope. By default codex may also change a file
# outside it when the objective needs it, provided its final message names the
# file; such paths are applied, unnamed ones are not. --strict-scope (the
# router's `strict_scope: true`) refuses every path outside --files, here and in
# codex-lane-apply.sh.
#
# --verify runs the acceptance command in the worktree after codex exits and
# records pass/fail. codex-lane-apply.sh refuses to land a lane whose
# verification failed unless --force. This is the final acceptance run; the
# supervising agent does not repeat it.
#
# Every spec is sent to codex behind scripts/lane-preamble.md (no delegation,
# the handoff file, NEED_TOOL, acceptance), so no caller has to paste it.
#
# --model / --effort default to FABLE_CODEX_DEFAULT_MODEL / FABLE_CODEX_DEFAULT_EFFORT
# (scripts/fable-config.sh). Changing the default model is a config change, never
# an edit here. Pass what fable-route.py returned: luna_max is `--effort max`,
# which spends far more of the same --timeout than high does.
#
# stdout: codex's last message, then a LANE REPORT block.
# exit:   0 ok · 1 empty diff · 3 codex unavailable (missing, auth, quota, model
#         access, or no network to the API) · 4 timeout · 5 bad usage/blocked
#         · 6 acceptance verification failed (worktree kept)
#
# Every run — whichever exit it takes — appends an "attempt" row to the routing
# ledger (status, rc, duration, model, effort, touched, scope violations), so
# outcome data accumulates without anyone remembering. With --route-id the row
# joins its routing decision; without one it is recorded as "unrouted", which is
# how routing-report.py measures how often the router was skipped, and a
# decision is backfilled for it (`fable-route.py backfill`) so Jev's shadow
# answer is logged even when the router was skipped.
set -euo pipefail
SECONDS=0

here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fable-config.sh
. "$here/fable-config.sh"

SPEC="" FILES="" MODEL="$FABLE_CODEX_DEFAULT_MODEL" EFFORT="$FABLE_CODEX_DEFAULT_EFFORT" REPO="" TMO=570 ROUTE_ID=""
VERIFY="" STRICT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)    SPEC="$2"; shift 2 ;;
    --files)   FILES="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --effort)  EFFORT="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --timeout) TMO="$2"; shift 2 ;;
    --route-id) ROUTE_ID="$2"; shift 2 ;;
    --verify)  VERIFY="$2"; shift 2 ;;
    --strict-scope) STRICT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done
case "$ROUTE_ID" in
  *[!A-Za-z0-9_-]*) echo "--route-id must be the id fable-route.py printed (got '$ROUTE_ID')" >&2; exit 5 ;;
esac

# --- attempt record: one ledger row per run, on every exit path ------------------
# LANE_STATUS is set just before each deliberate exit; anything else is derived
# from the exit code. Recording never changes the lane's own exit status, and a
# missing python3 or an unwritable ledger only costs the row.
LANE_STATUS="" N_TOUCHED="" N_VIOL="" WHY="" UNROUTED="" VERIFY_RESULT="" VERIFY_S=""
if [ -z "$ROUTE_ID" ]; then
  ROUTE_ID="unrouted-$(date +%s)-$$" UNROUTED=1
fi
record_attempt() {
  local rc=$1 status=$LANE_STATUS
  if [ -z "$status" ]; then
    case "$rc" in 0) status=ok ;; 1) status=empty_diff ;; 3) status=unavailable ;;
                  4) status=timeout ;; 5) status=blocked ;; *) status=error ;; esac
  fi
  python3 "$here/fable-route.py" attempt --id "$ROUTE_ID" --lane-status "$status" \
    --rc "$rc" --duration "$SECONDS" --model "$MODEL" --effort "$EFFORT" \
    ${N_TOUCHED:+--touched "$N_TOUCHED"} ${N_VIOL:+--violations "$N_VIOL"} \
    ${WHY:+--reason "$WHY"} ${UNROUTED:+--unrouted} ${STRICT:+--strict-scope} \
    ${VERIFY_RESULT:+--verify "$VERIFY_RESULT"} ${VERIFY_S:+--verify-s "$VERIFY_S"} >/dev/null 2>&1 || true
}
trap 'record_attempt $?' EXIT
[ -f "$SPEC" ] || { echo "--spec must be a readable file" >&2; exit 5; }
[ -n "$FILES" ] || { echo "--files is required: the lane's expected scope" >&2; exit 5; }

# Effort values are the ones codex 0.157 lists for gpt-6-luna/gpt-6-sol. `ultra`
# exists for Sol but means "automatic task delegation", which a lane must never
# do (the spec forbids re-delegation), so it is rejected here rather than trusted
# to the spec text.
case "$EFFORT" in
  low|medium|high|xhigh|max) ;;
  *) echo "--effort must be one of low|medium|high|xhigh|max (got '$EFFORT')" >&2; exit 5 ;;
esac
case "$MODEL" in
  ""|*[!A-Za-z0-9._-]*) echo "--model must be a plain model slug (got '$MODEL')" >&2; exit 5 ;;
esac

# --- backfill: a run that skipped the router still gets a routing decision ------
# Jev is only ever asked inside `fable-route.py`, so a lane called without
# --route-id used to leave shadow mode with nothing to measure. The decision
# written here takes what can be read off the spec (objective, file count,
# whether a verification command is named), records this run's model/effort as
# the actual route, and logs Jev beside it; it can never change the model or
# effort. The attempt row keeps `unrouted`, so compliance still counts the
# skipped router. Any failure here only costs the decision row.
BACKFILLED=""
ledger_off=$(printf '%s' "$FABLE_LEDGER" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [ -n "$UNROUTED" ] && [ "$ledger_off" != off ]; then
  objective=$(awk '
    found && NF { sub(/^[#* \t]+/, ""); print; exit }
    !found && (tolower($0) ~ /^[#* \t]*objective[* \t]*:/ || tolower($0) ~ /^#+[ \t]*objective[ \t]*$/) {
      line = $0; sub(/^[#* \t]*[A-Za-z]+[* \t]*:?[* \t]*/, "", line)
      if (line != "") { print line; exit }
      found = 1
    }' "$SPEC" 2>/dev/null || true)
  [ -n "$objective" ] || objective=$(awk 'NF { sub(/^[#* \t]+/, ""); print; exit }' "$SPEC" 2>/dev/null || true)
  verify=""
  if grep -qiE '^[#*[:blank:]]*verification[a-z ]*[*[:blank:]]*:[*[:blank:]]*[^[:space:]]|^#+[[:blank:]]*verification' "$SPEC" 2>/dev/null; then
    verify=1
  fi
  nfiles=$(printf '%s\n' "$FILES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sort -u | wc -l | tr -d ' ')
  bf=$(python3 "$here/fable-route.py" backfill --model "$MODEL" --effort "$EFFORT" --file-count "$nfiles" \
         ${objective:+--objective "$objective"} ${verify:+--verification} 2>/dev/null || true)
  bid=$(printf '%s\n' "$bf" | sed -n 's/^{"event":"decision","id":"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)
  if [ -n "$bid" ]; then ROUTE_ID=$bid BACKFILLED=1; fi
fi

# Unavailable is a routing fact for the caller, reported before any worktree exists.
command -v codex >/dev/null 2>&1 || {
  WHY="codex not found on PATH"
  echo; echo "LANE REPORT"; echo "  status:   unavailable — codex not found on PATH"
  echo "  model:    $MODEL"; echo "  effort:   $EFFORT"
  exit 3; }

# --- locate the repo from the first spec'd file, unless told -------------------
if [ -z "$REPO" ]; then
  first="${FILES%%,*}"
  d=$(dirname -- "$first"); [ -d "$d" ] || d=$(pwd)
  REPO=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)
fi
[ -n "$REPO" ] && [ -d "$REPO/.git" ] || {
  echo "BLOCKED: --files do not resolve inside a git repository." >&2
  echo "A codex lane needs a repo to isolate into. Narrow the spec or pass --repo." >&2
  exit 5; }
[ "$REPO" != "$HOME" ] || { echo "BLOCKED: repo root is \$HOME. Narrow the spec's Files." >&2; exit 5; }

# --- build the worktree from the CURRENT state, without touching the main tree -
# `git stash create` writes a commit object and returns its sha. It does NOT
# modify the working tree and does NOT push onto the stash list — unlike bare
# `git stash`, which the destructive-git guard rejects for good reason.
BASE=$(git -C "$REPO" stash create 2>/dev/null || true)
[ -n "$BASE" ] || BASE=$(git -C "$REPO" rev-parse HEAD)

# Reap worktrees leaked by lanes that died before printing their discard command.
# 24h is far beyond any lane's life (the wall clock caps at ~570s), so this can
# never remove a running lane's tree.
# `|| true` on the pipeline is load-bearing: grep exits 1 when nothing matches,
# and under `set -o pipefail` that would abort every lane run on a clean repo.
git -C "$REPO" worktree prune >/dev/null 2>&1 || true
stale=$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' \
        | grep '/codex-lane-' || true)
[ -n "$stale" ] && printf '%s\n' "$stale" | while IFS= read -r old; do
  [ -d "$old" ] || continue
  if [ -z "$(find "$old" -maxdepth 0 -mtime -1 2>/dev/null)" ]; then
    git -C "$REPO" worktree remove --force "$old" >/dev/null 2>&1 || true
    rm -f "$old.codex-stderr.log" "$old.lane" "$old.prompt"
  fi
done
:
# Transcript logs whose worktree is already gone (removed by hand) are reaped on
# the same 24h horizon.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'codex-lane-*.codex-stderr.log' -mtime +0 -exec rm -f {} + 2>/dev/null || true

WT="${TMPDIR:-/tmp}/codex-lane-$$-$(date +%s)"
git -C "$REPO" worktree add --detach --quiet "$WT" "$BASE"
cleanup() { git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -f "$WT.lane" "$WT.prompt"; }
ERRLOG="$WT.codex-stderr.log"   # beside the worktree, never inside it
META="$WT.lane"                 # scope and verification, read by codex-lane-apply.sh
# Deliberately NOT trapped on EXIT: the caller needs the worktree to read the
# diff. cleanup() is called explicitly on the paths that should discard it.

# Untracked-but-not-ignored files are absent from a stash-create commit; copy
# them so the lane sees the same tree the architect does.
( cd "$REPO" && git ls-files --others --exclude-standard -z ) | while IFS= read -r -d '' f; do
  mkdir -p "$WT/$(dirname -- "$f")"; cp -p "$REPO/$f" "$WT/$f" 2>/dev/null || true
done

# Freeze that seeded state as the lane's baseline. HEAD here is detached and the
# worktree is disposable, so this commit is invisible to the main repo's branches
# — and it makes "what did the lane change" an exact `git diff HEAD`, rather than
# a guess that misreads pre-existing untracked files as lane output.
git -C "$WT" add -A >/dev/null 2>&1 || true
git -C "$WT" -c user.email=lane@local -c user.name=lane \
    commit -q --allow-empty -m "codex-lane baseline" >/dev/null 2>&1 || true
# Diff against this sha, not HEAD: a codex that commits in its worktree would
# otherwise make its own work invisible and read as an empty diff.
BASELINE=$(git -C "$WT" rev-parse HEAD)
# What this lane wrote: tracked changes since the baseline plus new files, minus
# the harness's own scratch files.
lane_touched() {
  ( cd "$WT" && { git diff --name-only "$BASELINE"; git ls-files --others --exclude-standard; } \
    | grep -vxE '\.codex-final-message|\.codex-handoff\.md' | sed '/^$/d' | sort -u || true )
}

# The prompt codex reads: the harness preamble, the scope rule, then the spec.
PROMPT="$WT.prompt"
{ cat "$here/lane-preamble.md"
  echo
  if [ -n "$STRICT" ]; then
    echo "- Strict scope: change only the files the spec lists. If the objective cannot"
    echo "  be met without another file, stop and say which file and why."
  else
    echo "- The spec's files are the expected scope. You may change another file when"
    echo "  the objective directly requires it; name each such file, and why, in your"
    echo "  final message. An unnamed file outside the scope is not applied."
  fi
  echo; echo "--- task spec ---"; echo
  cat "$SPEC"
} > "$PROMPT"

# --- run codex, scoped to the worktree ----------------------------------------
FINAL="$WT/.codex-final-message"
T=$(command -v gtimeout || command -v timeout || true)
[ -n "$T" ] || echo "WARN: no timeout binary; codex runs uncapped (brew install coreutils)" >&2

# Codex's own ~/.codex/AGENTS.md doctrine writes gate state under this directory.
# It is outside the worktree, so workspace-write denies it unless added; grant it
# only when it exists. (`${ADD[@]+...}`: bash 3.2 treats an empty array as unset.)
ADD=()
[ -d "$HOME/.codex/sol-advisor" ] && ADD=(--add-dir "$HOME/.codex/sol-advisor")

CMD=(env -u OPENAI_API_KEY codex exec
  --model "$MODEL"
  -c model_reasoning_effort="$EFFORT"
  -c approval_policy="never"
  -c sandbox_mode="workspace-write"
  --ignore-user-config --sandbox workspace-write
  ${ADD[@]+"${ADD[@]}"}
  --skip-git-repo-check --cd "$WT"
  --output-last-message "$FINAL" -)

# codex streams its whole session transcript to stderr and echoes the final
# message to stdout. The caller needs the final message (printed once, from
# $FINAL) and the report, not the transcript — every line of it is context the
# supervising agent pays for. So both streams go to a log beside the worktree and
# only the tail is replayed.
set +e
if [ -n "$T" ]; then
  "$T" -k 10 "$TMO" "${CMD[@]}" < "$PROMPT" >"$ERRLOG" 2>&1
else
  "${CMD[@]}" < "$PROMPT" >"$ERRLOG" 2>&1
fi
rc=$?
set -e
tail -n 20 "$ERRLOG" >&2 2>/dev/null || true

[ -f "$FINAL" ] && cat "$FINAL"

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  # codex does not exit when it cannot reach the API: it logs "Reconnecting...
  # waiting for network" until the wall clock kills it. A timeout that wrote
  # nothing and ends in that state is codex being unreachable — the network,
  # not the task — so it is reported as unavailable (exit 3), not as a timeout
  # to resume (seen with real codex 0.157.1 behind a proxy that refused the API).
  wrote=$(lane_touched)
  [ -e "$WT/.codex-handoff.md" ] && wrote="${wrote}.codex-handoff.md"   # it ran: resumable, not unreachable
  recent=$(tail -n 200 "$ERRLOG" 2>/dev/null || true)
  if [ -z "$wrote" ] && grep -qiE 'waiting for network|reconnecting' <<<"$recent"; then
    cause=$(grep -m1 -iE 'proxy connection failed|could not resolve|dns error|connection refused|network is unreachable|failed to connect|timed out' <<<"$recent" \
            || grep -m1 -iE 'waiting for network|reconnecting' <<<"$recent" || true)
    cause=$(printf '%s' "$cause" | sed 's/^[0-9T:.Z-]* *//' | cut -c1-160)
    WHY="network: codex could not reach the API — $cause"
    LANE_STATUS=unavailable
    echo; echo "LANE REPORT"; echo "  status:   unavailable — $WHY"
    echo "  model:    $MODEL"; echo "  effort:   $EFFORT"; echo "  rc:       $rc (killed after ${TMO}s)"
    echo "  log:      $ERRLOG   (kept as evidence)"
    cleanup
    exit 3
  fi
  echo; echo "LANE REPORT"; echo "  status:   timeout after ${TMO}s"
  echo "  model:    $MODEL"; echo "  effort:   $EFFORT"
  echo "  worktree: $WT   (kept — resume this lane against it)"
  echo "  log:      $ERRLOG"
  echo "  handoff:"
  if [ -s "$WT/.codex-handoff.md" ]; then sed 's/^/    /' "$WT/.codex-handoff.md"; else echo "    (no handoff file)"; fi
  [ -z "$BACKFILLED" ] || echo "  route id: $ROUTE_ID   (backfilled; pass --route-id $ROUTE_ID when resuming)"
  exit 4
fi

# --- what actually changed, and what broke scope ------------------------------
# Diff against the baseline commit: exact lane output, new files included.
# (lane_touched's `|| true` is load-bearing: grep -v exits 1 on an empty diff.)
touched=$(lane_touched)

# printf '%s\n', not '%s': without the trailing newline `read` drops the last
# element, which silently empties $allowed and marks every path a violation.
allowed=$(printf '%s\n' "$FILES" | tr ',' '\n' | while IFS= read -r f; do
  f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"   # trim
  [ -n "$f" ] || continue
  case "$f" in /*) printf '%s\n' "${f#"$REPO"/}" ;; ./*) printf '%s\n' "${f#./}" ;; *) printf '%s\n' "$f" ;; esac
done | sed '/^$/d' | sort -u)

if [ -n "$touched" ]; then
  violations=$(printf '%s\n' "$touched" | grep -Fxv -f <(printf '%s\n' "$allowed") || true)
else
  violations=""
fi

# A failed run that wrote nothing and names auth, quota or model access is the
# lane being unavailable — a routing fact, not a task failure. Exit 3 so the
# caller stops and reports instead of retrying or failing over.
# Only codex's own error lines near the end count: the transcript also echoes the
# prompt, and a spec about "authentication" or "rate limits" is not an outage.
if [ "$rc" -ne 0 ] && [ -z "$touched" ]; then
  why=$(tail -n 40 "$ERRLOG" 2>/dev/null \
        | grep -iE '^[[:space:]]*(\[[^]]*\][[:space:]]*)?([a-z_-]+[[:space:]])?(error|fatal):' \
        | grep -i -m1 -E 'usage limit|rate.?limit|quota|try again (at|in)|(status|http|error)[^0-9]{0,6}(401|403|429)|not logged in|log ?in required|please (log|sign) ?in|unauthori[sz]ed|authenticat|model.{0,60}(not (found|supported|available)|does not exist|unavailable|no access)|(unknown|invalid|unsupported) model' || true)
  if [ -n "$why" ]; then
    WHY=$why
    echo; echo "LANE REPORT"; echo "  status:   unavailable — $why"
    echo "  model:    $MODEL"; echo "  effort:   $EFFORT"; echo "  rc:       $rc"
    echo "  log:      $ERRLOG   (kept as evidence)"
    cleanup
    exit 3
  fi
fi

# --- acceptance: the spec's verification, run once, by the harness ----------------
# Budget: the supervising Bash call is capped at 600 s; leave ~10 s to report.
# A result that cannot fit is "not_run" and the caller runs the command itself.
if [ -n "$VERIFY" ] && [ -n "$touched" ]; then
  left=$((590 - SECONDS)); v0=$SECONDS
  if [ "$left" -lt 20 ]; then
    VERIFY_RESULT=not_run
  else
    { echo; echo "=== acceptance: $VERIFY"; } >>"$ERRLOG"
    set +e
    if [ -n "$T" ]; then
      ( cd "$WT" && "$T" -k 5 "$left" bash -c "$VERIFY" ) >>"$ERRLOG" 2>&1 </dev/null
    else
      ( cd "$WT" && bash -c "$VERIFY" ) >>"$ERRLOG" 2>&1 </dev/null
    fi
    vrc=$?
    set -e
    [ "$vrc" -eq 0 ] && VERIFY_RESULT=pass || VERIFY_RESULT=fail
    VERIFY_S=$((SECONDS - v0))
  fi
fi

# --- scope: expected by default, strict when asked --------------------------------
# By default a path outside --files is applied only when codex's final message
# names it — the reporting rule, checked mechanically. Under --strict-scope no
# such path is ever applied.
explained="" unexplained=""
while IFS= read -r v; do
  [ -n "$v" ] || continue
  if [ -z "$STRICT" ] && [ -f "$FINAL" ] && grep -qF -- "$v" "$FINAL"; then
    explained="$explained$v"$'\n'
  else
    unexplained="$unexplained$v"$'\n'
  fi
done <<<"$violations"
applicable=$(printf '%s\n%s' "$(printf '%s\n' "$touched" | grep -Fx -f <(printf '%s\n' "$allowed") || true)" \
             "$explained" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
{ echo "baseline=$BASELINE"; echo "strict_scope=${STRICT:-0}"; echo "verify=${VERIFY_RESULT:-none}"
  echo "expected=$(printf '%s\n' "$allowed" | tr '\n' ',' | sed 's/,$//')"; echo "applicable=$applicable"; } > "$META"

echo
echo "LANE REPORT"
echo "  repo:     $REPO"
echo "  model:    $MODEL"
echo "  effort:   $EFFORT"
echo "  worktree: $WT"
echo "  rc:       $rc"
echo "  log:      $ERRLOG"
[ -z "$BACKFILLED" ] || echo "  route id: $ROUTE_ID   (backfilled; record the outcome against it)"
echo "  scope:    $([ -n "$STRICT" ] && echo strict || echo expected)"
echo "  touched:"; printf '%s\n' "$touched" | sed '/^$/d; s/^/    /'
N_TOUCHED=$(printf '%s\n' "$touched" | sed '/^$/d' | wc -l | tr -d ' ')
N_VIOL=$(printf '%s\n' "$violations" | sed '/^$/d' | wc -l | tr -d ' ')
if [ -n "$STRICT" ] && [ -n "$violations" ]; then
  echo "  SCOPE VIOLATIONS (strict scope — refused, never applied):"
  printf '%s\n' "$violations" | sed '/^$/d; s/^/    /'
elif [ -n "$violations" ]; then
  echo "  OUTSIDE EXPECTED SCOPE:"
  printf '%s' "$explained" | sed '/^$/d; s/^/    /; s/$/   (named by codex: applied)/'
  printf '%s' "$unexplained" | sed '/^$/d; s/^/    /; s/$/   (not named: not applied)/'
fi
if [ -z "$touched" ]; then
  echo "  status:   empty diff — the lane produced nothing. Treat as failure."
  cleanup; rm -f "$ERRLOG"
  exit 1
fi
case "${VERIFY_RESULT:-}" in
  pass)    echo "  verify:   pass ($VERIFY)" ;;
  fail)    echo "  verify:   FAIL ($VERIFY) — apply refuses this lane without --force"
           sed -n '/^=== acceptance: /,$p' "$ERRLOG" | tail -n 15 | sed 's/^/    /' ;;
  not_run) echo "  verify:   not run (wall clock spent) — run it yourself: $VERIFY" ;;
  *)       echo "  verify:   none given" ;;
esac
echo
echo "  Apply:    $here/codex-lane-apply.sh --worktree '$WT' --repo '$REPO' --remove"
echo "  Discard:  git -C '$REPO' worktree remove --force '$WT'; rm -f '$ERRLOG' '$META' '$PROMPT'"
[ "$rc" -eq 0 ] && LANE_STATUS=ok || LANE_STATUS=error   # wrote files, but codex failed
[ "$rc" -eq 0 ] && [ "${VERIFY_RESULT:-}" = fail ] && exit 6
exit "$rc"
