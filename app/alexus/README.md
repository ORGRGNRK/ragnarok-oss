# ALEXUS

A native macOS workspace and iOS companion distilled from Ragnarok: the source-grounded work catalog, selected evidence, observed agent states, repair receipts, and owner-controlled changes. It uses the supplied black/gold design tokens and original Heimdall icon. Foundation excerpts are selected philosophy, not runtime claims.

## Build

Builds with the locally installed Xcode and XcodeGen. The Mac host uses installed Python 3, Codex CLI and libfido2 tools; no Python package dependencies are added. The native app uses Apple frameworks.

```
xcodegen generate
./check.sh
./make-app.sh --install
python3 Host/install-watcher.py
python3 Host/install-bridge.py
```

The Mac app is installed as `~/Applications/ALEXUS.app`; Ragnarok is a separate app and is not replaced. Build the iOS target with the generated `ALEXUS.xcodeproj`, scheme `ALEXUSiOS`. Simulator builds do not enroll physical keys. Installation on a physical iPhone and distribution provisioning are separate, Unverified steps.

## Current surfaces

- ALEXUS: selected Foundation quote, Origin and Branch Theory, evidence boundary.
- Work: live sanitized catalog from `https://work.example.com/api/catalog`, search, project descriptions and dated checks. No raw source or private archive payload is downloaded.
- Activity (Mac and approved paired device): current sibling Heimdall project revision and project-scoped changed-entry count, installed Ragnarok app presence, error-log presence/modification time, bounded provider/status fields from existing Ragnarok agent state files, and local ALEXUS repair receipt chain. Prompts, filenames, error contents, tasks and raw model output are excluded. The observation bridge does not authorize Heimdall edits; the automated repair target remains ALEXUS.
- Repairs (Mac): queue a change, isolate a copy, run Codex implementation, frozen checks, independent read-only review, inspect the diff, then authorize that exact repair. Force-stop revokes pending work and kills supervised subprocess groups; completed changes cannot be recalled.
- Authority: existing owner enrollment file presence and explicit verification limits. No profile is overwritten or silently re-enrolled.

The iOS/iPadOS app also controls the paired Mac: private status, queue, diff review, force stop and dual-key approval. A five-minute pairing file transfers the Mac endpoint, certificate pin and one-time enrollment capability directly to the device. Phone/iPad Enclave and external-key proof-of-possession are verified first; the already-enrolled Mac owner must then approve that device using both existing hardware profiles. Compare the device fingerprint on both screens. No device is automatically approved. Every repair still needs fresh device-Enclave and enrolled external-key proofs.

Authority has a connection-only check for the transferred file. It validates the file deadline, pinned TLS and bootstrap challenge without creating a key or granting authority. Enrollment failures persist in that panel with the stage and bounded local error/HTTP code; error payloads, URLs, credentials and raw server bodies are excluded. An expired file is reported distinctly. A Mac preflight pass does not establish iPad reachability or successful physical enrollment.

Browser failures distinguish Apple session codes, invalid callbacks, mismatched callback state and allowlisted WebAuthn error names. The hosted key page displays a bounded error name; its Cancel button returns that error to ALEXUS. Unknown error text is redacted. A browser error name alone does not establish its physical cause, and successful callback parsing does not replace server-side verification of either hardware proof.

The external-key ceremony uses a secure ASWebAuthenticationSession on `https://work.example.com/owner-auth`. Only challenge and credential data goes in its URL fragment; no device token, private Mac endpoint, prompt or repair source is sent to Sites. It returns proof to the calling app through a state-bound custom callback. This avoids the Associated Domains capability rejected by the current Personal Development Team. Browser registration requests a cross-platform security key, and assertion uses the enrolled credential ID. Manufacturer/hardware attestation remains Unverified; owner enrollment and proof-of-possession are the trust anchors. This is a development build, not an App Store release.

## Local chat

Chat follows the inspected Heimdall Agents patterns: provider/model/project selection, private persistent sessions, host tool actions and bounded runs. Mac Ollama uses localhost; Alexus resolves through Heimdall's existing `bin/local-config.sh`. Discovery lists only models actually returned by `/api/tags`, excluding embeddings. There is no cloud or guessed-model fallback. Chat inference uses Ollama `/api/chat` with a constrained JSON action schema; the host executes the resulting supported action after validating its arguments. Staged repair legs use tool calling. Model quality and tool selection remain model-dependent.

The Mac host executes three tools: bounded source reads (with exact line ranges), a source-path listing capped at 100, and fixed shell inspection commands (`pwd`, `ls`, scoped Git status/diff-stat/revision log, `sw_vers`, `uname`). Shell argv is never evaluated as a script. A macOS sandbox denies writes, networking and execution of other programs. Source reads reject private-looking paths, dotfiles and symlinks. Inputs, model text and tool outputs pass through Ragnarok's existing scrubber; if it is unavailable, the operation is held. Private transcripts stay under `~/.alexus/app/chats` and are not copied into the public portfolio or receipt feed. Receipts contain action codes and session IDs; per-tool output hashes are in the private session.

Each response is bounded to six model requests and four tool calls per request, with 30-second HTTP and eight-second shell limits. Chat stop blocks subsequent tools; an active model request may take up to its timeout to return. Global force-stop changes the persistent epoch, invalidating old runs. One session works at a time; 50 sessions and 100 tool observations/session bound retention. A working session after a host crash may need Stop and a new chat. The UI labels model text Unverified separately from host tool results. A model can still make incorrect claims; this is not a truth guarantee or full enterprise-product parity.

The paired iPad uses the existing authenticated, pinned-TLS Mac bridge for these same tools. Unpaired/pending/revoked devices are denied. Chat itself has no live write, arbitrary execution, install, or hardware-approval tool. Copy an ALEXUS change proposal and its local provider/model into Repairs and review it there before queueing. Both implementation and independent review then use fresh direct Ollama tool loops with that selected local model. The implementation tool can replace only the two allowlisted source files in the isolated staging copy; the reviewer has read tools only. Host checks, capture, review validation and hardware application remain separate. Local repair legs are bounded to eight requests, four tool calls/request and 90 seconds/request. There is no cloud fallback if the model is incompatible. Requests made directly in Repairs retain the existing Codex default unless a local proposal was selected. Copying does not transmit or queue anything. Heimdall source changes remain outside that lane's ALEXUS-only allowlist.

## Deploy agents from iPad

Agents uses the existing private Mac bridge. Approved iPads can deploy, inspect, stop and (for held inspections) resume jobs; unknown, pending and revoked devices cannot. Mac launches detached bounded workers, so the iPad can close the app without owning the process. Commands execute on the Mac; model inference runs on the selected Mac/Alexus Ollama endpoint. The public site exposes no deployment API.

Inspection jobs accept one to eight frozen steps against Heimdall or ALEXUS. Each step gets fresh context plus bounded prior host outputs, explicitly untrusted. At least one new host observation and a completed bounded model leg are required before advancing. An observation is not proof that a user's entire requirement is satisfied. Changed specs/handoff transcripts, failures, missing evidence, stop markers and revoked epochs hold the chain. Completed evidence and scrubbed step transcripts are retained privately, with hashes; retry resumes from checkpoints, never reexecutes completed steps and allows at most two attempts/step. Explicit stop cannot resume. Deployment records are limited to 50, one active deployment at a time.

Repair deployments accept an ALEXUS requirements list and queue the existing implement → frozen host verification → independent read-only review lane. They support the Codex default or an explicitly discovered local model; application remains a separate fresh dual-key action in Repairs. They do not expand the two-file repair allowlist, deploy source directly, or authorize edits to Heimdall. Stopping a repair deployment invokes global repair revocation. The earlier unmerged Heimdall `agent-chains` worktree remains separate; its older authorization/session design is not imported into this owner bridge.

The multistep correction uses a constrained action schema that requires a command for shell actions and a path for source reads. The local repair loop uses the same schema boundary, with staged `write_source` only in its implementation leg. Schema compliance and model reasoning quality are separate; unsupported conclusions remain Unverified.

## Repair contract

Fresh Secure Enclave biometric signature **and** an enrolled external FIDO key assertion are required for each application. Either `yubikey-primary` or `utrust-spare` may supply the external proof. Existing enrollment lives outside the source tree. Public-key fingerprints are pinned in private configuration at first host initialization; a changed profile fails closed. No password fallback, shared repair session, or AI-issued approval.

Approval also binds the recorded receipt-chain prefix. It is an authorization, not remote attestation that later commands ran.

Approval binds a random nonce, expiration, exact source snapshot, candidate snapshot, check-output hash and tested app artifact. Any changed source/candidate/artifact, cancellation, missing review, failed check or expired approval holds the change. Authorization is consumed before source/install mutation; it cannot be replayed. Previous Mac app and source backups are retained. When the owner-selected iOS target is configured, staging also builds and verifies its signed physical-device artifact and provisioning membership. Approval binds both app artifacts and the selected target. The host installs that iOS build through the paired development connection; the iOS app may relaunch. If installation fails, the Mac transaction is restored where possible and any uncertain iOS outcome needs owner inspection. A physical-device install is not a runtime verification claim.

The automated lane can modify only `Sources/Views.swift` and `Sources/Models.swift`. Host, hardware, policy, evidence core, tests and build scripts are protected from this lane. Changes there need a separate owner-reviewed update. Model work never operates on the live source. It uses workspace-write with approval escalation disabled. Only captured allowlisted source bytes are promoted into a separate verifier directory; model-written caches, bytecode, generated projects and Git metadata are excluded. The host commits only the applied files; it excludes unrelated staged work.

The stage-only watcher observes new `ALEXUS*.ips` crash-file metadata and queued owner requests, with at most three staging attempts/day. It does not read unsanitized crash payloads, and cannot infer their cause. A crash that cannot be justified from source/checks is held. Network-unavailable events are logged as bounded codes and do not automatically launch repairs. Test output is hashed; prompts and raw agent output are not put in receipts.

The private bridge uses TLS with an owner-imported certificate pin, rejects redirects, and requires an enrolled-device token before exposing private state. The public portfolio has no private control API. A persistent revocation epoch invalidates old proofs even after staging resumes. The current pairing endpoint uses the Mac’s local hostname and requires device-to-Mac network reachability.

Configuration, private requests, retained candidates, approvals and receipts are under `~/.alexus/app` with private permissions. Stop scheduling using `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/co.rgnrk.alexus.repair-stage.plist`.

## Limits that remain explicit

A passing build/check is not proof that a reported runtime incident was fixed. Local receipt hashes detect changes relative to their recorded chain; they are not third-party attestation. A valid signature under an enrolled public key does not remotely attest the key's hardware origin. Hardware presence and successful physical flows must be observed on the actual device.

This workflow gates its own apply/install path. It does not prevent the OS account owner or malicious code running as that account from editing files, replacing the coordinator, or changing local trust files. Enforcing that stronger property requires a separate privileged isolation/deployment boundary and independent key enrollment, not a UI claim.

References consulted: [Apple Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave), [Apple physical security keys](https://developer.apple.com/documentation/authenticationservices/asauthorizationsecuritykeypublickeycredentialprovider), [OpenAI iterative repair loops](https://developers.openai.com/cookbook/examples/codex/build_iterative_repair_loops_with_codex). Installed Codex CLI help was also checked for actual supported flags.
