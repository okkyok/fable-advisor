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
# Anything refused stays in the worktree, which is then kept even with --remove.
#
# usage: codex-lane-apply.sh --worktree <path> --repo <path> [--files <f1,f2,...>]
#                            [--dry-run] [--remove] [--force]
# exit:  0 applied · 5 bad usage · 6 verification failed (nothing applied)
#        · 7 some paths refused (strict scope or conflict)
set -euo pipefail

WT="" REPO="" FILES="" DRY=0 RM=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --files)    FILES="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --remove)   RM=1; shift ;;
    --force)    FORCE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done
[ -d "$WT" ]   || { echo "--worktree must exist" >&2; exit 5; }
[ -d "$REPO" ] || { echo "--repo must exist" >&2; exit 5; }

meta() { [ -f "$WT.lane" ] && sed -n "s/^$1=//p" "$WT.lane" | head -n 1 || true; }
BASELINE=$(meta baseline) STRICT=$(meta strict_scope) VERIFY=$(meta verify)
EXPECTED=$(meta expected)
if [ -z "$FILES" ]; then
  [ -f "$WT.lane" ] || { echo "--files is required (no lane metadata beside $WT)" >&2; exit 5; }
  FILES=$(meta applicable)
fi
if [ "$VERIFY" = fail ] && [ "$FORCE" = 0 ]; then
  echo "REFUSED: this lane's acceptance verification failed; nothing applied."
  echo "  Re-run or resume the lane, or pass --force to land it anyway."
  exit 6
fi

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

applied=0 skipped=0 refused=0
while IFS= read -r f; do
  f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"   # trim
  [ -n "$f" ] || continue
  case "$f" in /*) rel="${f#"$REPO"/}" ;; ./*) rel="${f#./}" ;; *) rel="$f" ;; esac
  src="$WT/$rel"
  if [ "$STRICT" = 1 ] && ! in_expected "$rel"; then
    echo "  refused (strict scope): $rel"; refused=$((refused+1)); continue
  fi
  if [ ! -e "$src" ]; then
    echo "  skip (lane did not produce it): $rel"; skipped=$((skipped+1)); continue
  fi
  if conflict "$rel"; then
    echo "  CONFLICT (changed in the main tree since the lane started; not overwritten): $rel"
    refused=$((refused+1)); continue
  fi
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
done < <(printf '%s\n' "$FILES" | tr ',' '\n')   # '%s\n': without it, read drops the last path

echo
[ "$DRY" = 1 ] && echo "DRY RUN — nothing was written." || echo "applied=$applied skipped=$skipped refused=$refused"

if [ "$RM" = 1 ] && [ "$DRY" = 0 ] && [ "$refused" -eq 0 ]; then
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 \
    && echo "worktree removed: $WT" \
    || echo "worktree NOT removed (remove manually): $WT"
  rm -f "$WT.codex-stderr.log" "$WT.lane" "$WT.prompt"   # codex-lane.sh's side files
else
  echo "worktree kept: $WT"
  echo "  inspect leftovers:  git -C '$WT' status --short"
  echo "  discard when done:  git -C '$REPO' worktree remove --force '$WT'; rm -f '$WT.codex-stderr.log' '$WT.lane' '$WT.prompt'"
fi
[ "$refused" -eq 0 ] || exit 7
