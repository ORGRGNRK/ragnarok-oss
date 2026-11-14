# AGENTS.md — PhoneGrader

## Current state / Next step
- 2026-11-12: replaced manual Airtable sender with an opt-in HTTPS PostgreSQL grade-log gateway; NocoDB remains the intended frontend. SQL and deployment guide are in Support/.
- Validation: 205 Swift tests, one existing historical-ladder skip, zero failures; six GradeLog tests; four MCP tests; eight Python gateway tests. macOS Release app and iOS simulator build succeeded.
- Alexus deployment is blocked by a Tailscale SSH authentication check. No live database schema, gateway deployment, or row in the intended NocoDB base has been verified. Authenticate, follow Support/grade-log-setup.md, then send a synthetic grade from the app and verify it in the existing base.
- Review report: ~/Desktop/phone-grader-review-2026-11-12.md. Other workspace changes were left outside this commit.

**Handoff rule:** before handing off or ending a session, commit, push if a remote exists, and update the block above.

## Which AI does what
- **Claude:** planning, architecture, the critic step, client deliverables.
- **Codex or Gemini:** bulk coding and second opinions.
- **Local Qwen 7B** (Ollama on Alexus's GTX 1080, http://alexus:11434): boilerplate, tests, docs, log reading.
- **Grok Bot:** errands, research, email, audits.

## Project
- README.md is the full guide (pricing, `pgctl` CLI, comps, iPhone/iPad app).
- Build and test: `swift build`, `swift test`. iOS: `iOS/PhoneGraderiOS.xcodeproj`.
- Session handoff notes go in `.handoff/`.

## Rules
- Atlas prices, Airtable IDs and customer details are private. Never copy them into the portfolio repo or anything public.
