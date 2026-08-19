# Copy-paste workflows

DarwinRelay is most useful when ChatGPT owns the reasoning and uses the Mac as its execution environment. These prompts are starting points, not permission boundaries. Review the tool calls ChatGPT proposes and keep the bridge disabled when you are not using it.

## Continue a Codex session

```text
Use DarwinRelay only for local-machine operations.

Find the Codex session I was working on most recently for this project. Read the persisted thread without resuming it or starting another Codex model turn. If the history is large, page through every turn oldest-first.

Summarize the objective, repo, branch, decisions, changed files, current errors, and exact unfinished step. Then inspect the live repo and continue from there.

Ask before production deployments, force pushes, credential changes, destructive database operations, or deleting user data.
```

## Fix CI and ship the branch

```text
Use DarwinRelay to inspect this repo and its current branch. Find why CI is failing, reproduce it locally, fix the underlying issue, run the relevant test suite, and commit the fix.

If the branch already has a remote and the push is non-destructive, push it. Do not force-push. Give me the commit hash and a concise explanation of what was actually wrong.
```

## Take over an unfinished local task

```text
Use DarwinRelay to inspect the current project state, recent Git history, uncommitted changes, running local jobs, and any relevant persisted Codex history.

Work out what I was trying to finish and continue it yourself. Prefer evidence from the live repo and process state over assumptions. Keep going through build/test failures until the task is actually complete or you hit a blocker that requires a credential, irreversible action, or product decision from me.
```

## Debug something that only fails on your Mac

```text
Use DarwinRelay to investigate this as a real machine problem, not a hypothetical one. Inspect the exact binary versions, environment, logs, processes, ports, permissions, and project state involved. Reproduce the failure, isolate the cause, and apply the smallest safe fix.

Do not weaken system security controls or delete user data to make the symptom disappear.
```

## Use an interactive terminal program

```text
Use a real PTY through DarwinRelay for this task. Start the interactive program, read its terminal output, send the required keystrokes, and keep the session contained. Close the PTY when the task is done and verify the session process group is gone.
```

## Share what worked

If one of these turns into a useful workflow, post the prompt and what it accomplished in the repository's Discussions. Concrete examples are more useful than generic testimonials, and they help other developers discover what the bridge can actually do.
