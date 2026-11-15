# Launch drafts

Nothing in this file has been posted. These are drafts only.

TODO for the owner: check each community's rules before posting. That check is not done.

- Hacker News (Show HN): title rules, no voting rings, no launch-day begging
- r/ClaudeAI: flair, self-promotion, and repost rules
- X: current length, link, and automation rules

Replace `[REPO_URL]` with the public repository. Do not invent usage numbers.

## Show HN

Title:

Show HN: TouchGate – Touch ID before an AI agent runs a destructive command

Text:

TouchGate is a free, open-source Claude Code hook. It reads a PreToolUse payload and, for a destructive command, asks for Touch ID before the command runs. No approval, no helper, or not a Mac: the hook exits 2 and tells the agent not to retry or work around the block.

I built it after the April 2026 PocketOS incident. A Cursor agent deleted the production database and backups in 9 seconds. Prompt rules already forbade that. Writeups:

https://www.giskard.ai/knowledge/a-cursor-ai-agent-wiped-a-production-database-in-9-seconds-excessive-agency-ai-failure

https://dev.to/tomtokita/an-ai-agent-deleted-a-production-database-in-9-seconds-here-is-the-architecture-that-would-have-1apg

https://adversa.ai/blog/ai-coding-agent-incidents/

What it catches, as text: rm and the usual deleters, find -delete, git rm (not --cached), git clean -f, git push --force, git reset --hard, rsync --delete, SQL DROP / TRUNCATE / DELETE FROM without WHERE, terraform destroy, kubectl delete, docker volume rm, docker system prune, aws s3 rm/rb, gcloud delete, and railway / fly / heroku destroy-style commands. MCP tools named delete, drop, destroy, or trash are included. Build folders, node_modules, and /tmp are allowlisted so ordinary cleanup does not train you to tap through.

Limits, so this is not sold as a sandbox: it reads the command string. A script file or python -c can hide a delete. It does not filter syscalls. Cursor and Codex do not run Claude Code hooks yet. Linux is planned, and until then it fails closed. The installer prints a settings snippet and does not edit your Claude settings.

Source (MIT): [REPO_URL]

Install is clone, then ./install.sh.

## r/ClaudeAI

Title: Hook: Touch ID before Claude Code runs rm, force-push, or DROP TABLE

I made a small PreToolUse hook called TouchGate. Matcher is `Bash|mcp__.*`. If the command looks destructive, a macOS helper shows the command in a Touch ID sheet. Deny, timeout, or no helper: exit 2, and the model is told not to retry or work around it.

This is the gap from the PocketOS writeups in April 2026: the agent deleted a production database and backups in 9 seconds even though the prompt said not to. A prompt is not the thing that runs the shell.

It is not a sandbox. It only sees the command text, so python -c and scripts can evade it. Cursor and Codex are not wired up. Linux is planned and currently fails closed. Default allowlist is node_modules, dist, build, .next, __pycache__, and /tmp.

The installer does not touch your settings. It prints the snippet for you to paste.

Repo: [REPO_URL]

## X

Post 1:
April 2026: a Cursor agent deleted PocketOS's production database and backups in 9 seconds. The prompt forbade it. Prompts are not a control. The approval has to sit on the command itself.

Post 2:
TouchGate is a free Claude Code hook. rm, git push --force, DROP TABLE, terraform destroy, kubectl delete, and the same class of command wait for Touch ID. The command is the text on the sheet.

Post 3:
No touch, no helper, not a Mac, or a timeout: the command does not run. The agent is told not to retry or work around it. The decision is appended to ~/.touchgate/log.jsonl.

Post 4:
Limits, plainly. It reads the command text. A script or python -c can hide a delete. It is not a sandbox. Cursor and Codex are not supported yet. Linux is planned, and until then it fails closed.

Post 5:
Install is two commands, then you paste the hook yourself. It does not edit your settings. MIT. [REPO_URL]
