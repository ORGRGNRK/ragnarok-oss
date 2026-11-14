# Codex approval flag fix: steps and replication record

Date: 2026-11-03

## Issue

The Codex runner in `bin/ragnarok-agent` built this command:

```text
codex exec --json --approve-for-me --sandbox workspace-write --cd <cwd> <prompt>
```

The CLI rejected the combination with:

```text
error: the argument '--approve-for-me' cannot be used with '--sandbox <SANDBOX_MODE>'
```

## Diagnosis

From the repository root, the runner was located with:

```sh
rg -n --hidden --glob '!**/.git/**' -- '--approve-for-me|sandbox <SANDBOX_MODE>|heimdall' .
```

The matching source was `ragnarok/app/heimdall/bin/ragnarok-agent`, in `launch_cmd()` under `who == "codex"`. The local CLI help was checked with:

```sh
codex exec --help | rg -n -C 2 'approve-for-me|full-auto|sandbox'
```

It described `--approve-for-me` as routing approval requests through automatic review using the workspace-write sandbox. Therefore the explicit `--sandbox workspace-write` was redundant and incompatible.

## Source change

The Codex command now uses:

```text
codex exec --json --approve-for-me --cd <cwd> <prompt>
```

The redundant sandbox argument was removed. The corresponding Heimdall note in `AGENTS.md` was updated to say that `--approve-for-me` applies automatic review with the workspace-write sandbox.

## Replication through Heimdall

The first attempt, from `ragnarok/app/heimdall`, was:

```sh
bin/heimdall-edit manual
```

It stopped before building because the restricted execution environment denied writing `~/.ragnarok/heimdall-edits.jsonl` and creating Heimdall's edit lock under `~/Library/Application Support/Heimdall`.

The same command was retried with the required home-directory filesystem access:

```sh
bin/heimdall-edit manual
```

Heimdall's manual edit path copied the pending tracked changes into a staging worktree, built the app, ran its bundled self-test, committed the result, and installed it. The observed output included:

```text
▸ stage: ai
▸ stage: build
Build complete! (84.40 sec)
built build/Heimdall.app
▸ stage: test
▸ stage: install
heimdall-edit: installed b0c4d92. Click Restart in Heimdall when ready.
```

The repository's latest commit was then observed as:

```text
b0c4d92 heimdall-edit (manual): manual edit
```

## Result and scope

The workflow completed the build, self-test, commit, and install stages. Heimdall instructed the user to click **Restart** to load the installed update; this record does not claim that the app was restarted. The self-test output was captured by the edit workflow and logged, but its individual lines were not printed in the terminal output examined for this writeup.
