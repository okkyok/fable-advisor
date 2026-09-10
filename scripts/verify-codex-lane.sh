#!/usr/bin/env bash
# Confirms the codex lane works end to end against the real `codex exec`.
# The worktree mechanism was verified against a stub codex on 2026-09-10; stage 3
# is the same mechanism driven by the real CLI.
set -uo pipefail
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
ng(){ printf '  \033[31m✗\033[0m %s\n' "$1"; }

# syspolicyd's exec-policy errors are informational, never a gate. They are a
# symptom of clients exec'ing and exiting, not of a wedged daemon: on 2026-09-10
# this stage read 174 errors in 60s while stage 3 passed every assertion, and the
# count was back to 0 a minute later.
echo "1. syspolicyd (informational)"
read -r pid etime <<<"$(ps -Ao pid,etime,command | awk '/[s]yspolicyd/{print $1, $2; exit}')"
echo "    pid=$pid, up $etime"
n=$(log show --last 60s --style compact --predicate 'process == "syspolicyd"' 2>/dev/null \
    | grep -c "qtn_proc\|dispatch_mig_server")
echo "    $n exec-policy errors in the last 60s"

echo "2. codex CLI"
# Probe with `codex exec`, not `--version`: some builds hang on the latter, so a
# hang there proves nothing about whether the lane can run.
if gtimeout 90 codex exec --model gpt-5.6-luna 'reply with READY' </dev/null >/dev/null 2>&1; then
  ok "codex exec responds ($(gtimeout 30 codex --version </dev/null 2>&1 | head -1))"
else
  ng "codex exec failed. Check auth and the install: npm i -g @openai/codex@latest"
  exit 1
fi

echo "3. codex lane, end to end, in an isolated worktree"
T=$(mktemp -d)/repo; mkdir -p "$T/src" "$T/docs"
( cd "$T" && git init -q . && git config user.email t@t && git config user.name t
  echo "def add(a,b): return 0" > src/calc.py
  echo "docs" > docs/README.md
  git add -A && git commit -q -m init
  # a co-resident lane's uncommitted work, which must survive
  echo "OTHER LANE UNCOMMITTED WORK" >> docs/README.md )

cat > "$T/../spec.txt" <<'SPEC'
Objective: make src/calc.py's add(a,b) return the sum of a and b.
Files: src/calc.py
Verification: python3 -c "import sys;sys.path.insert(0,'src');import calc;assert calc.add(2,3)==5;print('PASS')"
Constraints: touch nothing but src/calc.py.
SPEC

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=$("$here/codex-lane.sh" --spec "$T/../spec.txt" --files "src/calc.py" --repo "$T" --effort low --timeout 300 2>&1)
echo "$out" | sed -n '/LANE REPORT/,$p' | sed 's/^/    /'
wt=$(echo "$out" | awk '/worktree:/{print $2; exit}')

if [ -n "$wt" ] && [ -d "$wt" ]; then
  ok "lane ran in its own worktree"
  grep -q "SCOPE VIOLATIONS" <<<"$out" && ng "lane wrote outside its Files (reported, not applied)" || ok "lane stayed inside its Files"
  "$here/codex-lane-apply.sh" --worktree "$wt" --repo "$T" --files "src/calc.py" --remove >/dev/null 2>&1
  ( cd "$T" && python3 -c "import sys;sys.path.insert(0,'src');import calc;assert calc.add(2,3)==5" 2>/dev/null ) \
    && ok "applied code is correct" || ng "applied code failed verification"
  grep -q "OTHER LANE UNCOMMITTED WORK" "$T/docs/README.md" \
    && ok "co-resident lane's uncommitted work survived  <-- the property this exists for" \
    || ng "co-resident work was destroyed — STOP and investigate"
else
  ng "no worktree produced; see output above"
fi
rm -rf "$(dirname "$T")"
