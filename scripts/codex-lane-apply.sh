#!/usr/bin/env bash
# Apply a lane's output from its worktree back into the main tree.
#
# Additive by construction: it copies files and touches nothing else. It never
# runs checkout, restore, reset, clean or stash on the main tree, so a
# co-resident lane's uncommitted work cannot be collateral damage.
#
# For a worktree made by codex-lane.sh (it leaves <worktree>.lane beside it):
#   - without --files it applies what the lane may land: the expected-scope
#     paths it touched, plus paths outside that scope codex's report named;
#   - a strict-scope lane never lands a path outside its --files, even if named;
#   - a lane whose acceptance verification failed is refused unless --force;
#   - a path the main tree changed after the lane was seeded is a conflict and
#     is skipped unless --force, so newer work there is never overwritten.
# Every path is checked before any is copied. The lane's acceptance result is
# then re-judged against what would land:
#   pass     the verified files are unchanged and exactly these land
#   stale    a verified file changed in the worktree after the run
#   partial  what would land is not the verified set (a conflict, a --files
#            subset or superset, a deletion apply cannot land)
#   fail · not_run · infra_error · none   as the lane recorded them
# A lane run with --require-verify lands only on `pass` — otherwise nothing is
# applied. Without it, anything but pass still lands, with a warning.
# --force overrides every refusal and needs --reason; both go to the ledger
# (an `apply` row under the lane's route id), as does every non-dry run.
# Anything refused stays in the worktree, which is then kept even with --remove.
#
# These checks keep an honest workflow honest; they are not a security
# boundary against a hostile caller, who can copy files by hand. Mandatory
# gates belong in the repository's CI and branch protection.
#
# usage: codex-lane-apply.sh --worktree <path> --repo <path> [--files <f1,f2,...>]
#                            [--dry-run] [--remove] [--force --reason '<why>']
# exit:  0 applied · 5 bad usage · 6 verification failed or required and not a
#        current pass (nothing applied) · 7 some paths refused (strict scope or
#        conflict; nothing applied when verification is required)
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

WT="" REPO="" FILES="" DRY=0 RM=0 FORCE=0 REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --files)    FILES="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --remove)   RM=1; shift ;;
    --force)    FORCE=1; shift ;;
    --reason)   REASON="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done
[ -d "$WT" ]   || { echo "--worktree must exist" >&2; exit 5; }
[ -d "$REPO" ] || { echo "--repo must exist" >&2; exit 5; }
if [ "$FORCE" = 1 ] && [ -z "$REASON" ]; then
  echo "--force needs --reason '<why>': it overrides the acceptance and conflict guards" >&2
  echo "and is recorded in the ledger. Use it only on the user's say-so." >&2
  exit 5
fi

meta() { [ -f "$WT.lane" ] && sed -n "s/^$1=//p" "$WT.lane" | head -n 1 || true; }
BASELINE=$(meta baseline) STRICT=$(meta strict_scope) VERIFY=$(meta verify)
EXPECTED=$(meta expected) REQUIRED=$(meta verify_required) VFP=$(meta verified_fp)
RID=$(meta route_id) APPLICABLE=$(meta applicable)
[ -n "$VERIFY" ] || VERIFY=none
if [ -z "$FILES" ]; then
  [ -f "$WT.lane" ] || { echo "--files is required (no lane metadata beside $WT)" >&2; exit 5; }
  FILES=$APPLICABLE
fi

# Same function as in codex-lane.sh; keep the two identical.
lane_fp() {
  printf '%s\n' "$2" | tr ',' '\n' | sed '/^$/d' | sort -u | while IFS= read -r p; do
    if [ -f "$1/$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$1/$p")"; else printf '%s absent\n' "$p"; fi
  done | cksum | awk '{print $1 "-" $2}'
}
norm() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d' | sort -u; }
in_expected() { printf '%s\n' "$EXPECTED" | tr ',' '\n' | grep -qxF -- "$1"; }
# The main tree changed this path after the lane was seeded from it.
conflict() {
  local rel=$1
  [ -n "$BASELINE" ] && [ "$FORCE" = 0 ] || return 1
  if git -C "$WT" cat-file -e "$BASELINE:$rel" 2>/dev/null; then
    [ -e "$REPO/$rel" ] || return 0
    ! git -C "$WT" show "$BASELINE:$rel" | cmp -s - "$REPO/$rel"
  else
    [ -e "$REPO/$rel" ] && ! cmp -s "$WT/$rel" "$REPO/$rel"
  fi
}
record() {  # record <applied> <refused>: one `apply` row, joined to the lane's route id
  [ -n "$RID" ] && [ "$DRY" = 0 ] || return 0
  local extra=()
  [ "$REQUIRED" = 1 ] && extra+=(--verify-required)
  [ "$FORCE" = 1 ] && extra+=(--forced --reason "$REASON")
  python3 "$here/fable-route.py" apply --id "$RID" --verify-state "$state" --applied "$1" --refused "$2" \
    ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 || true
}

# --- plan: decide every path before copying any ---------------------------------
land="" skipped=0 refused=0
while IFS= read -r f; do
  f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"   # trim
  [ -n "$f" ] || continue
  case "$f" in /*) rel="${f#"$REPO"/}" ;; ./*) rel="${f#./}" ;; *) rel="$f" ;; esac
  if [ "$STRICT" = 1 ] && ! in_expected "$rel"; then
    echo "  refused (strict scope): $rel"; refused=$((refused+1)); continue
  fi
  if [ -e "$WT.excluded/$rel" ]; then   # its baseline was restored in the worktree
    echo "  skip (outside scope and unnamed; moved aside before acceptance): $rel"
    skipped=$((skipped+1)); continue
  fi
  if [ ! -e "$WT/$rel" ]; then
    if [ -n "$BASELINE" ] && git -C "$WT" cat-file -e "$BASELINE:$rel" 2>/dev/null; then
      echo "  skip (the lane deleted it; apply never deletes — remove it by hand): $rel"
    else
      echo "  skip (lane did not produce it): $rel"
    fi
    skipped=$((skipped+1)); continue
  fi
  if conflict "$rel"; then
    echo "  CONFLICT (changed in the main tree since the lane started; not overwritten): $rel"
    refused=$((refused+1)); continue
  fi
  land="$land$rel"$'\n'
done < <(printf '%s\n' "$FILES" | tr ',' '\n')   # '%s\n': without it, read drops the last path

# --- judge the acceptance result against what would land ------------------------
state=$VERIFY
if [ "$state" = pass ]; then
  if [ -z "$VFP" ] || [ "$(lane_fp "$WT" "$APPLICABLE")" != "$VFP" ]; then
    state=stale
  elif [ "$(norm "$land")" != "$(norm "$APPLICABLE")" ]; then
    state=partial
  else
    # The verified run saw the main tree as it was at the lane's base. Another
    # lane's apply or a hand edit since then, outside what lands here, means the
    # landed combination was never tested. (Worktrees share the object store.)
    moved=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '%s\n' "$land" | grep -qxF -- "$p" && continue
      if git -C "$WT" cat-file -e "$BASELINE:$p" 2>/dev/null; then
        [ -e "$REPO/$p" ] && git -C "$WT" show "$BASELINE:$p" | cmp -s - "$REPO/$p" && continue
      else
        [ -e "$REPO/$p" ] || continue
      fi
      [ "$moved" -lt 3 ] && echo "  main tree changed since the lane's base: $p"
      moved=$((moved+1))
    done < <({ git -C "$REPO" -c core.quotePath=false diff --name-only "$BASELINE" 2>/dev/null || true
               git -C "$REPO" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null || true; } | sort -u)
    [ "$moved" -eq 0 ] || state=stale
  fi
fi

if [ "$FORCE" = 0 ]; then
  why=""
  [ "$VERIFY" = fail ] && why="this lane's acceptance verification failed"
  [ -z "$why" ] && [ "$REQUIRED" = 1 ] && [ "$state" != pass ] \
    && why="this lane's route requires a current pass for exactly what lands, and verify is '$state'"
  if [ -n "$why" ]; then
    echo "REFUSED: $why; nothing applied."
    echo "  Re-run the lane (it reseeds from the current tree) or resume it."
    echo "  --force --reason '<why>' lands it anyway, on the user's say-so only."
    [ "$DRY" = 1 ] || record 0 "$refused"
    echo "worktree kept: $WT"
    [ "$refused" -eq 0 ] || [ "$VERIFY" = fail ] && exit 6 || exit 7
  fi
fi

# --- copy -------------------------------------------------------------------------
applied=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$WT/$rel"
  if [ "$DRY" = 1 ]; then
    if [ -e "$REPO/$rel" ] && cmp -s "$src" "$REPO/$rel"; then
      echo "  unchanged: $rel"
    else
      echo "  would apply: $rel"
      diff -u "$REPO/$rel" "$src" 2>/dev/null | head -40 || true
    fi
  else
    mkdir -p "$REPO/$(dirname -- "$rel")"
    cp -p "$src" "$REPO/$rel"
    echo "  applied: $rel"
  fi
  applied=$((applied+1))
done <<<"$land"

echo
[ "$DRY" = 1 ] && echo "DRY RUN — nothing was written." || echo "applied=$applied skipped=$skipped refused=$refused"
case "$state" in
  pass) echo "verify: pass — covers exactly what landed" ;;
  none) echo "verify: none — no acceptance command ran for this lane" ;;
  *)    echo "verify: $state — NOT a pass for what landed$([ "$FORCE" = 1 ] && echo " (forced: $REASON)"); run the acceptance command in the main tree before calling it verified" ;;
esac
record "$applied" "$refused"

if [ "$RM" = 1 ] && [ "$DRY" = 0 ] && [ "$refused" -eq 0 ]; then
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 \
    && echo "worktree removed: $WT" \
    || echo "worktree NOT removed (remove manually): $WT"
  rm -f "$WT.codex-stderr.log" "$WT.lane" "$WT.prompt"; rm -rf "$WT.excluded"   # codex-lane.sh's side files
else
  echo "worktree kept: $WT"
  echo "  inspect leftovers:  git -C '$WT' status --short"
  echo "  discard when done:  git -C '$REPO' worktree remove --force '$WT'; rm -f '$WT.codex-stderr.log' '$WT.lane' '$WT.prompt'; rm -rf '$WT.excluded'"
fi
[ "$refused" -eq 0 ] || exit 7
