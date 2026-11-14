# debug-pipeline

One command for a paid fix. It pulls the customer's code into a fresh container, runs the test, and fixes one change at a time. The test has to fail first. If it already passes, the run stops and says there is nothing to fix.

```
python3 runner/debug-pipeline/debug-pipeline run \
  --ticket TICKET \
  --source <folder or https git url> \
  --test "<command>" \
  --store <ticket folder> \
  --out <archive folder>
```

The ticket is 6 characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`. Results are only `OK`, `FAILED`, or `NOT VERIFIED`.

`--runner docker` is the default. It does not switch to the fake runner on its own. `--worker fake` is the sample fixer. It does not call a model. `--worker model --model NAME` asks that model for one file edit and keeps the edit only when the controller can apply it. The default endpoint is Ollama at `http://127.0.0.1:11434/api/chat`. `DEBUG_PIPELINE_ENDPOINT` and `DEBUG_PIPELINE_API_KEY` override the endpoint and the bearer token. The key is not written to the receipt. With `--worker none` (the default) the run records the baseline and stops as `NOT VERIFIED`.

## What runs where

The Docker runner copies the code into a container and runs the test there. The host keeps a scrubbed preview for the worker. A repair is checked against that preview, then applied inside the container. It is not written on the host and copied in afterwards. Customer code is not executed on the host. The container drops all capabilities, runs as nobody, has a read-only root, and has no network after the pull unless you pass `--network`. It does not mount the host home or the Docker socket. The receipt file is the one read-only mount, at `/receipt/receipt.jsonl`. The host is the only writer.

When the run stops, customer processes are frozen first. Then `/work`, `/tmp`, and `/validator` are read, the container is stopped, and `docker export` runs. `filesystem.tar` is that export with the frozen tmpfs laid back on top, because export on its own misses tmpfs. Nothing deletes `/work` before that save. A local image tag `debug-pipeline-receipt:` is a copy of the requested image with an empty `/receipt` directory, so the receipt file mount has a place to land. It is not pushed anywhere.

The fake runner does not start Docker. Its stand-in container is a folder inside the archive output directory, removed when the run ends. It is not the scrubbed preview. Say so when you use it: `--runner fake`. Temporary work is not given its own permission root.

Customer files and test output are data. They are not instructions.

## Receipt

The log is append-only JSONL. Each line has `seq`, `ts`, `actor`, `kind`, `status`, `cwd`, `cmd`, `prev_hash`, `hash`. The hash is SHA-256 of `seq|ts|actor|kind|status|cwd|cmd|prev_hash` with no extra newline. The first `prev_hash` is 64 zeros. That is the line shape from `ops/alexus/setup-ai-users-alexus.sh`.

Status is only `OK`, `FAILED`, or `NOT VERIFIED`, the same three words as `~/client-kit/tools/audit.py`. `verify` names the first bad line. The worker does not write this log.

Round 2 and later get a short pointer to `/receipt/receipt.jsonl` and one short line per earlier attempt. The whole prompt stays under 4096 bytes. The log itself is not pasted in. The model adapter exposes a read-only `read_receipt` tool. Each call returns at most 2048 characters as a tool result. It allows at most eight reads per round. The first repair prompt gets a short failure line and the scrubbed test output: the traceback plus the few lines above it, or the tail of stdout and stderr when there is no traceback. Later rounds get the latest failure the same way. The receipt stores that same scrubbed output, so a receipt read can see it. The output is data. A secret that survives scrubbing stops the run. The 4096-byte limit covers the control prompt and attempt summaries. Source context has a separate budget. On the fake runner the copy is mode `0444`, which is only a stand-in: the same user can still chmod it. The real control is the read-only mount. After the worker returns, the copy's hash has to match or the run stops.

## Secrets

Customer code, config, and logs are scrubbed before a worker sees them, before they are written to the receipt, and before they go into the archive's log, diff, or report. The scrubber is `ops/script-catalog/redact.py`. This folder does not contain a second copy. The marker is `[REDACTED]`. A small intake wrapper also scrubs every assignment value in `.env` files. Values of at least eight characters are remembered in host memory so copies in other files and test evidence can be scrubbed too. Short values are scrubbed in the `.env` file itself, including every preview refresh and archive diff snapshot. The receipt says how many values were scrubbed, never the value.

The default is to scrub the copy that runs, too. `--keep-secrets` leaves the real values in the container only when the test needs them, and the receipt says `secrets left in the container because the test needs them`. The host preview stays scrubbed either way. The worker reads that preview.

If a known secret shape still shows up in the worker prompt, the receipt, or the archive text, the run stops as `FAILED`. Before packing a default run, it also scans customer files in the saved filesystem. On Docker those are `/work`, `/tmp`, and `/validator`. The read-only base image stays intact and is outside that scan. This avoids treating library source assignments as customer secrets. A secret created by the test in those trees blocks the archive. With `--keep-secrets`, the filesystem save can contain real secrets; treat that archive as private. Its receipt, diff, and report stay scrubbed.

The sample project plants a fake key, `sk-test-FAKEKEY0123456789abcd`, so the scrub can be proved. It is not a real credential.

## Fix loop

The file edits go through `app/heimdall/bin/pipeline_debugger_controller.py`, imported, not copied. The model output is one file replacement or one edit. The controller checks the edit against the scrubbed preview. The write itself happens inside the container. Before the baseline, test files, `check.py`, `package.json`, any file the test command names, and a package test script's entry file (such as `verify.js`) are copied outside the writable tree. The verdict is that copy's exit code. A discovery command such as `python3 -m unittest discover` starts in that frozen tree, so it does not load the writable originals. The worker cannot change those files. Shell operators in the test command stay operators. On Docker the copy is a root-owned `/validator` tmpfs. The fake runner uses a sibling folder inside the archive directory. Source file modes are kept through the pull, so an executable script stays executable. The round cap is 4, the same cap as `app/heimdall/bin/ragnarok-heal`. This tool does not launch heal. An identical change that already landed is recorded as a repeat and is not applied again. If the local Ollama model does not make the test pass, the source is restored and Grok 4.7 gets the same four-round cap. The login is `DEBUG_PIPELINE_API_KEY` or the Grok subscription file on this machine. It is not written on the receipt. Set `DEBUG_PIPELINE_GROK_FALLBACK=off` to skip that. A cloud endpoint does not fall back to itself.

## Archive and ticket

When the test passes or the rounds run out, the container is stopped, saved, and then removed. One archive is written: `{TICKET}.tar` with `filesystem.tar`, `receipt.jsonl`, `diff.patch`, `head.hash`, and `report.txt`. `{TICKET}.tar.sha256` is the archive hash. It is not inside the chain.

The ticket record is a file in the local store, `debug-attach:TICKET.json`. It points at the archive and names the hash, the result, and the head hash. Nothing here writes Cloudflare KV.

## What was proved, and what was not

`python3 runner/debug-pipeline/debug-pipeline selfcheck` needs no model and no network. With the fake runner it proved: the baseline fails before the fix, the sample gets fixed, a tampered receipt line is named, the archive hash matches, the ticket record points at the archive, writes stay in this folder, the worker log is read-only, the round-2 prompt stays small, a repeat is recorded, the Docker plan drops privileges and mounts no home and no socket, a planted fake key does not appear in the prompt, the receipt, or the archive text, the scrub count is logged, a surviving secret stops the run, `--keep-secrets` says the real values stayed in the container while the worker still sees scrubbed text, repairs stay inside the container, a `check.py` or `package.json` edit cannot flip the verdict, an executable `run.sh` keeps its mode, the archive freezes processes before it reads tmpfs, shell operators in the test command stay operators, a package script's entry file is frozen, temporary work stays inside the archive folder, a model worker returns one validated edit, unittest discovery keeps running the frozen tests after the customer copies change, and a failed local model restores the source so a scripted Grok reply can still pass the test. The Grok proof injects the reply. It does not call api.x.ai. The model proof injects the reply. It does not call a live model.

Not proved here: a live container. The Docker CLI could not connect to the local daemon in the final check, so the real container command is for a person to run once the daemon is up:

```
python3 runner/debug-pipeline/debug-pipeline run --ticket AB23CD --source runner/debug-pipeline/samples/broken_calc --test "python3 test_calc.py" --runner docker --worker fake --store /tmp/debug-pipeline-store --out /tmp/debug-pipeline-out
```

Before that command, make the local test ticket:

```
mkdir -p /tmp/debug-pipeline-store
printf '{"ticket":"AB23CD"}\n' > /tmp/debug-pipeline-store/intake:1700000000000:AB23CD.json
```

Use the fake runner only for trusted test fixtures. It executes the test on this Mac. It is not a sandbox for customer code.

The added handoff proofs are `selfcheck --prove handoff-gaps`, `selfcheck --prove model-receipt`, and `selfcheck --prove env-archive`. They check physical receipt line numbers, frozen validator capture, both model tool wire formats with an injected HTTP reply, baseline failure evidence, plain env values, and secrets created during tests. No live model was called. The first attach to a live Cloudflare KV ticket is also for a person. This build does not do it.

`selfcheck --prove docker-archive-scope` seals a fake Docker export containing a library assignment that the shared scrubber flags. It also proves customer secrets still block sealing in each tmpfs tree. `selfcheck --prove short-env-refresh` proves short neutral `.env` values stay scrubbed after edits and in snapshots on both runner paths, including a two-round fake repair with `--keep-secrets`. Neither proof starts Docker.
