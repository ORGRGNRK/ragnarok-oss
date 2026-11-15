# Ragnarok

**A home-built system for working with AI agents without having to trust them.** Every AI action leaves a
receipt, nothing an AI makes counts as done until a check passes and a person says yes, and it all runs on
your own Mac and home server.

One person built it in 2026 while learning to code with AI, to run a small phone-reselling business and
rebuild a life. Why it exists, in the author's words: [STORY.md](STORY.md).

## What's inside, and what you can use on its own

| Piece | What it does | Start here |
|---|---|---|
| **Heimdall** | Mac app that shows, live, what every AI on your machines is doing (Claude Code, Codex, Grok, local models), next to your own commands. Opens with a security key or Touch ID. It can edit itself: an AI changes a copy, the copy must build and pass a self-test, then it is installed. | [`app/heimdall/`](app/heimdall/README.md) |
| **Phone grader** | Mac app for buying and reselling used iPhones: reads the phone, grades it, works out the most you can pay from a buyer's price list, and writes the listing. Ships with made-up sample prices. | [`agents/phone-grader/`](agents/phone-grader/README.md) |
| **Conveyor** | An AI to-do list that only marks a task done when its checklist is proven, and a second AI fails to prove the work wrong. | [`runner/conveyor/`](runner/conveyor/README.md) |
| **Runner** | Runs a task with a local AI inside a sealed container, checks it, then waits for a person to approve. | [`runner/`](runner/README.md) |
| **Connector** | The one door an AI uses to reach the database (an MCP server). Every tool call, good or refused, leaves a receipt. | [`connector/`](connector/README.md) |
| **Client kit** | A small self-hosted database an AI can safely use, one per client: describe the tables in one file, start it, connect Claude. | [`clients/kit/`](clients/kit/README.md) |
| **Brain** | Suggests, never acts: tries fixes for failing tests in a sealed box and remembers what worked. | [`brain/`](brain/README.md) |
| **Hooks** | Claude Code hooks that make the AI check its own claims: evidence rules, premise checks, receipts. | [`ops/mac-scripts/`](ops/mac-scripts/README.md) |
| **Doc pipe** | Photo of a receipt or bill on your phone, read by a local vision model, saved to your own database. | [`agents/doc-pipe/`](agents/doc-pipe/README.md) |

Most pieces assume a Mac, and some a Linux home server reachable over ssh. Each folder's README says what it
needs and how to test it.

## How it fits together

| Folder | Job | Think of it as |
|---|---|---|
| `app/` | What the owner sees and clicks (Swift Mac app) | The front desk |
| `connector/` | The one doorway to the data (an MCP server) | The front door, with a sign-in book |
| `data/` | The one Postgres database plus receipts | The filing cabinet and the logbook |
| `brain/` | Decides what should happen, learns from fixes | The advisor. It suggests, never acts alone |
| `runner/` | Carries out approved tasks inside a sealed container | The worker in a sealed room |
| `agents/` | The AI agents that sit on top: phone grader, iPhone agent, alexus-core harness, doc pipe, upwork alert | The staff who use the building |
| `clients/` | The client kit: ONE kit (`clients/kit/`); each client is a small settings folder (`clients/<name>/`: tables + private .env + a `./kit` wrapper). `clients/intake/` is the inbox for text, files and photos | The client files |
| `ops/` | Server setup (`ops/alexus/`), the `state` snapshot, script catalog, `tools/` (secret scan of git history, Claude export unpacker, box-check) | The building maintenance kit |
| `docs/` | Plans and notes | The binder |

## Foundation rules

1. **AI outputs are proposals.** Nothing the AI suggests happens until it's approved.
2. **The owner holds agency.** They make the final call. The AI can make routine calls on its own, but it always leaves a receipt for them to review.
3. **Cold storage is never auto-pulled.** Archived data stays put unless the owner asks for it.
4. **One Postgres and one MCP per project.** No side databases, no second doorways.
5. **A shared core:** receipts, error model, redaction, and search are built once in `data/` and used everywhere.
6. **Receipts for every write.** Any change to data leaves a dated, hash-chained receipt.

See `ARCHITECTURE.md` for the diagram. Each folder's README says what it does and how to test it.

## Status

Working, not finished. One person built it by directing AI coding agents, and runs it every day on one Mac
and one Linux home server. Expect rough edges and pieces that assume a setup like that one. Each folder's
README says what is tested and how to run the tests.

Machine-specific values (server address, login names, your name) are never in the code. Each machine reads
them from `~/.ragnarok/local.conf` (`KEY=value`, not in git); everything works with generic defaults without it.

## Contributing, conduct, security

- [CONTRIBUTING.md](CONTRIBUTING.md): how to send a change.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): Contributor Covenant 3.0.
- [SECURITY.md](SECURITY.md): how to report a vulnerability privately.
- [RELEASING.md](RELEASING.md): how a public release is made.

## License

Two licenses, split by folder:

| Path | License |
|---|---|
| Everything except `runner/conveyor/` and `clients/kit/` | GNU AGPL-3.0-only (`LICENSE`) |
| `runner/conveyor/` | PolyForm Noncommercial 1.0.0 (`runner/conveyor/LICENSE`): free for personal and noncommercial use; commercial use needs a paid license |
| `clients/kit/` | PolyForm Noncommercial 1.0.0 (`clients/kit/LICENSE`), from the first release after 2026-11-15: free for personal and noncommercial use; setting it up for a business or a paying client needs a paid license. The 2026-11-14 public release stays AGPL. |

PolyForm Noncommercial is not an OSI-approved open-source license, so `runner/conveyor/` and `clients/kit/` are
source-available, not open source. The rest of the repo uses Conveyor as a separate program: the Belt app
(`app/belt-ui/`, `app/heimdall/Sources/Belt/`) starts its scripts and reads its task files. If you take code from
either folder, its license comes with it. Questions: origin@rgnrk.co.
