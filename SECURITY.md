# Security

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

- Preferred: use GitHub's private report on this repository (Security tab, "Report a vulnerability").
- Or email **origin@rgnrk.co** with what you found and how to reproduce it.

You should hear back within a week. This is a one-person project, so there is no bounty and no SLA, but
real reports get fixed and credited if you want credit.

## What is in scope

The code in this repository. Out of scope: anyone's own server or deployment of it, and third-party
services it talks to.

## Things to know

- The code never contains keys or tokens. Secrets live in `.env` files and `~/.ragnarok/local.conf`, which are git-ignored.
- Release copies are checked with gitleaks before they are published (see RELEASING.md).
