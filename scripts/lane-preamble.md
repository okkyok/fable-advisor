Harness notes for this run. The task spec follows them.

- You are in a disposable git worktree made for this task. Implement it
  yourself; do not hand any part to another agent or another codex run — a
  sub-run shares your wall clock and dies with it.
- About ten minutes of wall clock, then you are killed without warning. Keep
  `.codex-handoff.md` in the working root current at each checkpoint, one line
  each: DONE, TOUCHED, REMAINING, NEXT, VERIFY. It is what survives a kill;
  delete it when you finish.
- After you exit, the harness runs the spec's verification command and
  records the result. Test as much as helps you while working, and end with
  what you ran and what it printed.
- If something you need is unreachable from here (a service, a credential, a
  browser, a database, a path outside this workspace), do not stub or guess
  around it. Stop, and end your final message with a line
  `NEED_TOOL: <what you need, what you tried, what remains>`.
