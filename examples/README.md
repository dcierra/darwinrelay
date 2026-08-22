# Copy-paste workflows

DarwinRelay is most useful when the MCP client owns the reasoning and uses the Mac as its execution environment. For ChatGPT, start with the local project itself; Chrome, native UI, and Codex continuity can be added only when a task needs them.

These prompts are starting points, not permission boundaries. DarwinRelay is not a sandbox. Review the tool calls your client proposes, keep the bridge disabled when you are not using it, and do not connect untrusted clients.

## Inspect, fix, and verify a local project

```text
Use DarwinRelay and work on ~/Projects/myapp.

First inspect the repository and current git status. Run the relevant tests and
reproduce the failure I am seeing. Find the underlying cause, make the smallest
correct fix, rerun the affected tests, and verify the result locally.

Do not deploy, force-push, change credentials, or delete user data.
```

This is the primary DarwinRelay workflow: the same ChatGPT conversation can inspect, modify, execute, and verify against the real project on the Mac. It does not require Codex history, Chrome automation, or native desktop permissions.

## Debug a native app end to end

```text
Use DarwinRelay to debug this macOS app as a real UI problem.

Launch the app, reproduce the issue through the native interface, inspect the
relevant logs and source, make the smallest safe fix, rebuild/restart the app,
repeat the same UI flow, and verify the behavior is corrected.

Prefer semantic Accessibility operations and explicit verification over blind
mouse coordinates. Do not weaken macOS security settings to make the test pass.
```

This workflow requires the relevant native desktop permissions.

## Fix CI and ship the branch

```text
Use DarwinRelay to inspect this repo and its current branch. Find why CI is
failing, reproduce it locally, fix the underlying issue, and run the relevant
test suite.

If the branch already has a remote and the push is non-destructive, push it.
Do not force-push. Give me the commit hash and a concise explanation of what was
actually wrong.
```

## Use an interactive terminal program

```text
Use a real PTY through DarwinRelay for this task. Start the interactive program,
read its terminal output, send the required keystrokes, and keep the session
contained. Close the PTY when the task is done and verify the session process
group is gone.
```

## Work in the background browser

```text
Use DarwinRelay's managed background Chrome workspace for this task.

Check chrome_workspace_status first. Keep the work inside the dedicated
DarwinRelay browser profile/tab pool. Navigate to the target site, inspect the
page semantically, complete the requested workflow, and verify the resulting
page state before reporting success.

Do not fall back to my everyday Chrome profile unless I explicitly approve it.
```

## Investigate something that only fails on this Mac

```text
Use DarwinRelay to investigate this as a real machine problem, not a hypothetical
one. Inspect the exact binary versions, environment, logs, processes, ports,
permissions, and project state involved. Reproduce the failure, isolate the
cause, and apply the smallest safe fix.

Do not weaken system security controls or delete user data to make the symptom
disappear.
```

## Take over an unfinished local task

```text
Use DarwinRelay to inspect the current project state, recent Git history,
uncommitted changes, and running local jobs.

Work out what I was trying to finish and continue it yourself. Prefer evidence
from the live repo and process state over assumptions. Keep going through
build/test failures until the task is actually complete or you hit a blocker
that requires a credential, irreversible action, or product decision from me.
```

## Already using Codex? Continue from persisted history

```text
Use DarwinRelay only for local-machine operations.

Find the Codex session I was working on most recently for this project. Read the
persisted thread without resuming it or starting another Codex model turn. If the
history is large, page through every turn oldest-first.

Summarize the objective, repo, branch, decisions, changed files, current errors,
and exact unfinished step. Then inspect the live repo and continue from there.

Ask before production deployments, force pushes, credential changes, destructive
database operations, or deleting user data.
```

## Share what worked

If one of these turns into a useful workflow, post the prompt and what it accomplished in the repository's Discussions. Concrete examples are more useful than generic testimonials and help other developers understand what the runtime can actually do.
