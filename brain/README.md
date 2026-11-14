# brain/ — the advisor

The brain **suggests**. It never changes your data on its own. It has three small parts:

| Part | What it does in one sentence | Where |
|---|---|---|
| **fix-memory** | When code tests fail, it tries fixes in a sealed box, and remembers what worked so the same failure is fixed from memory next time. | `fix-memory/` |
| **cartridges** | JSON files of "rules of thumb" for a topic (phone grading, car engines, sockets, ...). **All UNVERIFIED.** | `cartridges/` |
| **router** | Picks the cartridge that fits a question and asks the local AI model, using that cartridge's rules. | `router.py` (+ `lookup/`) |

Everything runs on your own machines: Ollama on this Mac or the alexus box on your network
(other addresses are refused), Docker/OrbStack, and the data layer's ONE Postgres. No cloud AI.

## fix-memory (from `~/Developer/fix-memory`)

**What it is.** A loop for code that is still being built: run the tests in a throwaway container
with no network; if they fail, look for a past fix to the same failure (0.97 similarity or more),
try it; otherwise ask the local coding model (`qwen2.5-coder:7b` on the alexus box) for a few candidate fixes
and test each one. When tests pass, it saves the failure and the fix so next time it can reuse it.

**Where its data lives.** In the data layer's Postgres, in a `brain` section (`data/db/brain.sql`):
learned fixes, "fix reused" events, and the search vectors. There is no second database.

**Receipts.** Every learned fix and every reuse gets a receipt in the data layer's hash-chained
`write_log`, written by the database itself (who, which run, why, the full fix). The old separate
fix-memory `receipts` table is gone, so there is ONE receipt chain to check: `./kit verify` (or
`uv run fixloop verify`, which runs the same check). The AI's login can add fixes but can never
change or delete one.

**How to run it.**
```zsh
cd ~/Developer/ragnarok/data && ./kit up                # the one Postgres (now with pgvector)
cd ../brain/fix-memory && ./scripts/setup.sh            # one time: test box image + Python env
./scripts/demo.sh                                       # the demo: heal a broken example, then reuse the fix
```
Details, commands and settings: `fix-memory/README.md`.

**Honest limits.** The local model is the weak part. With the old default `qwen2.5-coder:3b`, the
model working without a stored fix healed the broken demo in only **3 of 13** throwaway runs (the
rest gave up after 5 or 8 tries, mostly returning the file unchanged). On 2026-10-30 the bigger
`qwen2.5-coder:7b` was put on the alexus box and made the default: it healed the same demo in
**5 of 5** throwaway runs, each on the 2nd try. That is ONE demo bug run five times, not a
benchmark; expect harder bugs to fail more often. The 7B writes more slowly (about 6 tokens, i.e. word pieces, a second vs 14 for the 3B; the
alexus box runs it on its processor), but a whole throwaway test still took about a minute. Every time a fix *was* stored, a fresh copy of the same bug was fixed straight
from memory (similarity 0.980, replayed, no model call): **10 of 10** so far (5 with each model).
If a run gives up, re-run; the test script retries it (`DEMO_ATTEMPTS`). And the loop is only as strict as your tests: the learned demo fix passes the
tests but also sorts the caller's list in place, which the tests don't check.

**History.** `fix-memory/` was brought in with its git history (a "subtree merge" of fix-memory
`main` at `fe47a7e`; no remote was added; the original folder is untouched).

## Cartridges (from `~/Developer/alexus-core`)

Nine JSON files were copied: async sockets, CAN bus, FIDO2/CTAP crypto, Lexus IS F Sport 2GR,
local OCR, phone grading, the Ragnarok ledger, Honda S2000 F22C, and Xero finance.

> **All cartridges are UNVERIFIED.** Their rules were written in alexus-core and were never checked
> against a real source. Each file now says so (`"status"` and `"warning"`).
>
> **The phone-grading rules are INVENTED.** The grade definitions, the 80% battery cut-off and the
> named "standards" (like "Atlas Mobile Wholesale Scale") were made up; every rule in
> `cartridges/phone_grading_matrix.json` starts with "UNVERIFIED (invented)". Do not use them to
> grade, price or describe a phone to anyone until you replace them with rules you have confirmed.
>
> **The Ragnarok ledger cartridge is wrong for this repo** (wrong login names, wrong hash formula,
> a port scheme that doesn't exist here, a table that doesn't exist). The file lists what is wrong.
>
> **The OCR cartridge has a captcha-bypass rule.** It is flagged in the file; delete it if you don't
> want it.

What changed in the files: added `status`, `warning` and `copied_from`; removed
`verification_command`. In alexus-core that command ran a fixed test script that only checked its
own hard-coded logic, never the AI's answer, so a "PASSED" proved nothing. Nothing here checks
answers yet.

## Router and lookup

```zsh
export BRAIN_OLLAMA_HOST=http://alexus.local:11434      # or leave unset for Ollama on this Mac
python3 brain/lookup/lookup.py "grade an iPhone with cracked glass"   # which cartridge, and why
python3 brain/router.py "grade an iPhone with cracked glass"          # ask the model with those rules
python3 brain/router.py --dry-run "..."                               # show the prompt, don't ask
```

How it picks: it turns the question and each cartridge's topic into vectors with the local
`nomic-embed-text` model and compares them. A cartridge is used only if it scores 0.52 or more and
the question doesn't contain one of its "not this" words; otherwise no cartridge is used and the
model is asked plainly. (Those numbers came from alexus-core and were hand-picked, not measured.)
A high score only means the question *sounds like* the topic; it says nothing about whether the
rules are right.

What it is not: it does not check the answer, does not write anything, and keeps no receipt. The
answer is printed as a **PROPOSAL** from a small local model (`llama3.2:3b` by default,
`BRAIN_CHAT_MODEL` to change). It re-embeds the cartridges every run, so it takes a few seconds
plus however long the model takes to answer (about 25 s for one answer in testing), not "50 ms".

## What was left behind on purpose

From alexus-core: `mail_bridge.py` and the iMessage bridge (their sender checks can be fooled, so
anyone could send it commands), the Touch ID / YubiKey gate and other `bin/` scripts, the `tests/`
"verification" scripts, `receipts.jsonl`, and the README's claims: "~50 ms" lookups (it re-embeds
every cartridge each time), "LoRA cartridges" (there are no LoRA weights, just JSON prompt rules)
and "verified" answers (see above).

From fix-memory: its own Postgres container and `docker-compose.yml`, its `schema.sql` (now
`data/db/brain.sql`), its separate `receipts` table, and `scripts/tamper_test.py` (data/'s tests
already prove a tampered log is caught).

## Checking it all

```zsh
cd ~/Developer/ragnarok
python3 -m unittest discover -s brain/tests             # cartridges, lookup, router (no AI needed)
FIXLOOP_OLLAMA_HOST=http://alexus.local:11434 brain/scripts/test-throwaway.sh
```
The second command builds a throwaway copy of the data stack, runs the fix-memory demo, checks the
receipts and the connector's brain_* tools, then deletes everything it made. About 10 minutes.

## Open choices for the owner

- (Done 2026-10-30) `fixloop-mcp`'s 4 tools (`brain_*`) moved into `connector/`, so Ragnarok has one
  MCP server; the Python server is a stub pointing there.
- The cartridges need real, checked rules (phone grading first) or should be deleted.
- A bigger local coding model (e.g. `qwen2.5-coder:7b`) would likely heal more often.
