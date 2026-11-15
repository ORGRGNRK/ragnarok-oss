# TouchGate

TouchGate is a free, open-source hook that stops an AI coding agent from running a destructive command until a human approves it with Touch ID.

## 15-second demo

```text
agent    rm -rf ./data
mac      Touch ID: "TouchGate: approve destructive command: rm -rf ./data"
human    does not approve
agent    TouchGate blocked this destructive command. Nothing was run.
         Do not retry or work around it.
```

`./data` is still there.

## Install

```bash
git clone [REPO_URL] touchgate
cd touchgate && ./install.sh
```

`install.sh` builds the macOS helper into `~/.touchgate/bin/touchgate-auth` and prints a Claude Code snippet. Paste that snippet into your settings yourself. The installer does not edit `~/.claude/settings.json`.

The snippet is a `PreToolUse` hook with matcher `Bash|mcp__.*`. The hook timeout is 120 seconds so the Touch ID sheet is not killed early.

Cursor and Codex are not supported yet. They do not run this hook.

## What it catches

Bash text, including commands reached through `sudo`, `xargs`, `env`, `sh -c` / `bash -lc`, and `ssh`:

- `rm`, `rmdir`, `unlink`, `shred`, `srm`, `trash`
- `find -delete` and `find -exec rm` / `-execdir` / `-ok`
- `git rm` (a `--cached` remove is left alone), `git clean -f`, `git push --force` / `-f` / `--force-with-lease`, a `+refspec` push, `git reset --hard`
- `rsync --delete` (and the `--delete-*` forms) and `--remove-source-files`
- `DROP`, `TRUNCATE`, and `DELETE FROM` without `WHERE`, inside `psql`, `mysql` / `mariadb`, or `sqlite3` via `-c` / `-e` / `--execute` or a heredoc
- `terraform destroy` and `terraform apply -destroy`
- `kubectl delete`
- `docker volume rm` and `docker system prune`
- `aws s3 rm` and `aws s3 rb`
- `gcloud ... delete`
- `railway`, `fly` / `flyctl`, and `heroku` destroy-style commands (`railway down`, `apps:destroy`, `pg:reset`, and the same family)

MCP tools whose names contain `delete`, `drop`, `destroy`, or `trash`.

Paths under `node_modules`, `dist`, `build`, `.next`, `__pycache__`, and `/tmp` (including macOS `/private/tmp`) are allowlisted by default, so cleaning build output does not pop a sheet. `rm -rf ./node_modules ./src` is still gated, because not every target is safe. `~/.touchgate.json` replaces `allow_paths` when that key is set, and `extra_patterns` adds regular expressions that are always gated:

```json
{
  "allow_paths": ["node_modules", "dist", "build", ".next", "__pycache__", "/tmp"],
  "extra_patterns": ["\\bmkfs\\b"]
}
```

Every gated decision is appended to `~/.touchgate/log.jsonl`. Check a command without prompting:

```bash
python3 touchgate.py --check 'rm -rf ./data'
python3 touchgate.py --check 'ls'
```

## If it cannot ask, it blocks

Approved Touch ID exits 0. Claude Code's own permission rules still apply after that. A denial, a timeout, a missing helper, a request the hook cannot read, or a machine that is not macOS exits 2. The message tells the agent that nothing ran and not to retry or work around the block.

The helper is `swift/touchgate-auth.swift`. It uses LocalAuthentication with no password fallback, puts the command in the sheet's reason text, and signs the approval with a Secure Enclave key the first time you approve. Later approvals have to verify against that key.

Linux support is planned. Until it exists, TouchGate fails closed on Linux.

## Limits

TouchGate reads the command text the agent submitted. It does not trace a script file, and a `python -c` (or a variable it cannot see) can hide a delete. The test suite includes `python3 -c "import os; os.remove(...)"` as a command that is not gated, on purpose.

It is not a sandbox. It does not wrap the process or filter syscalls. A command that does not match the list above is not stopped. `docker rm` of a container, `aws s3api delete-object`, and `git checkout -- file` are examples of things you can add with `extra_patterns` if you want them.

`DELETE FROM ... WHERE ...` is treated as scoped because the text contains `WHERE`. That is not a SQL parser. `WHERE 1=1` will pass the text check.

The default allowlist is by path component and by the `/tmp` prefix. If a real project keeps source in a directory named `build` or `dist`, take that name out of `allow_paths`.

The helper and the config live in your home directory. This is an approval gate for an agent that is otherwise allowed to use your shell. It is not a boundary against a person who can replace the helper or delete the hook.

## Why this exists

In April 2026 a Cursor agent deleted PocketOS's production database and backups in 9 seconds, despite prompt rules forbidding it.

- https://www.giskard.ai/knowledge/a-cursor-ai-agent-wiped-a-production-database-in-9-seconds-excessive-agency-ai-failure
- https://dev.to/tomtokita/an-ai-agent-deleted-a-production-database-in-9-seconds-here-is-the-architecture-that-would-have-1apg
- https://adversa.ai/blog/ai-coding-agent-incidents/

The prompt was not the control. Approval has to be enforced by the tool that is about to run the command.

## Proof, when a hook is not enough

Need AI agents working on real systems with proof of every action? -> [PROVED_URL]

## Develop

```bash
python3 -m unittest discover tests
```

Author: [AUTHOR]. MIT license, see [LICENSE](LICENSE).
