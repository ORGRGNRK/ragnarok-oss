# Switch/resume retention experiment

Implemented on 3 November 2026 using the owner's account on the Mac and Alexus. HQ writes identify the test actor as Codex. These are synthetic fixtures; existing project packets were not used as test data.

The handoff now preserves original requirements independently of the generated summary, attaches file hashes and observable runner results, and atomically archives context, supersedes the old packet, and installs its replacement. Concurrent stale writers are refused. Database triggers prevent editing/deleting/truncating history and changing an existing packet's original requirements; a partial unique index permits one active packet per project. These protections do not prevent a database administrator from changing the schema or disabling triggers.

## Measured results

`results-final.json` records three successive prose handoffs using Alexus's local `qwen2.5-coder:7b`, temperature 0, 16,384-token context, with 24 exact facts. Eight were explicitly designated original requirements; sixteen were other source details. The baseline is the packet writer from Git revision `404b715`, using the same local model backend as the updated writer. Source file hashes identify the tested implementation.

| Context given to a fresh recall probe | Correct facts |
| --- | ---: |
| Previous summary-only packet | 0/24 |
| Updated packet including frozen requirements | 7/24 |
| Updated packet plus all raw archive entries | 8/24 |
| Original user message retrieved from verified archive | 24/24 |

Literal fact checks after each of the three rounds also found 0/24 in baseline packets and 8/24 in updated packets. Every original fact remained present in the archived source. Thus the updated working packet omitted 16 of 24 facts in this fixture, while targeted retrieval recovered them. The final recall probe reproduced seven of the eight facts present in the updated packet exactly. Merely including the entire archive did not make the model use the missing facts successfully. Retrieval of the original message was explicitly directed by the test; this does not establish that an unattended agent will always choose the right entry.

Claude Haiku could not run because the subscription's weekly quota was exhausted. A fallback-only attempt was excluded; the harness now rejects fallback summaries as model-test results. No paid API was provisioned. This small local-model experiment is not a loss estimate for Claude, Codex, arbitrary coding work, or other conversation lengths. Earlier exploratory results are retained in `results.json`; use `results-final.json` for the final implementation.

The local summarizer also asserted completion of fictional handbook sections despite the fixture explicitly recording no execution. Generated summaries are labeled unverified; DONE lines remain self-reports. File hashes establish file bytes, and a runner exit code establishes only that recorded runner result. Neither establishes arbitrary semantic correctness.

## Archive and retrieval

Alexus's running Ragnarok HQ PostgreSQL now has `packet_chat_history`, exposed in the HQ NocoDB base under the same name. Its logical MCP table name is `Packet_Chat_History`. Each entry contains project/packet/history IDs, actor, source type, scrubbed source text, and its SHA-256. Packet `History_ID` points to the corresponding entry. New handoffs retain the preceding packet, supplied round instruction and full observable output, the Claude exposed JSON stream when available, and the summarizer prompt/reply. This captures context the runner exposes, not hidden reasoning, unexposed CLI messages, or every historical chat on the computer.

```sh
app/heimdall/bin/ragnarok-packet history HISTORY_ID
```

Retrieval verifies the stored source text against its SHA-256. Redaction occurs before hashing/storage for configured `~/.ragnarok/scrub-values`, common bearer/API keys, and PostgreSQL URL passwords. This is pattern-based scrubbing, not a guarantee that every possible secret format is detected. Source is archived without the previous output-line cutoff; inputs over database limits fail instead of silently truncating.

For a project's first packet, supply `original_requirements` in the save JSON or create `.ragnarok-requirements.json` before seeding/switching. Both seed and resume read that file. Once captured, requirements are carried verbatim. Existing packets without original requirements receive an explicitly labeled legacy snapshot; original user wording cannot be reconstructed from an old summary.

## Reproduce

Requires the existing HQ MCP connection and reachable Alexus services. Tests create uniquely named synthetic projects and leave their receipted rows available for inspection.

```sh
python3 app/heimdall/checks/packet-storage-check.py
. app/heimdall/bin/local-config.sh
export OLLAMA_URL
RAGNAROK_PACKET_SUMMARIZER=ollama RAGNAROK_PACKET_MODEL=qwen2.5-coder:7b \
  python3 app/heimdall/checks/packet-context-check.py --live \
  --output app/heimdall/docs/packet-context-test/results-final.json
```

Default production summarization remains Claude Haiku. Ollama is selected only through the explicit environment variables above. `storage-checks.json` records 13 passing checks: initial save, deliberate failure and rollback, concurrent replacement, one active target, requirements/history immutability, whitespace and hash preservation, rejecting oversized packets, refusing changed evidence, and receipt-chain integrity. Additional local checks validated syntax, complete capture beyond 20,000 output lines, removal of temporary transcript files, unverified completion labels, and strict boolean continuation.

The live HQ MCP image was rebuilt successfully and its health check passed. Before migration, its database was backed up to `backups/ck-ragnarok-hq-20261104-031759.sql`; prior source files were saved under `backups/packet-handoff-20261103/`. See the HQ README for applying the schema and protection SQL to another installation.
