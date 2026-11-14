# Ragnarok Proof Lab

A working, bounded demonstration for a technical reviewer: a headless model proposes a discount rule, the host recomputes frozen checks, a YubiKey authorizes the run, and the enrolled laptop key signs the release. It does not claim to eliminate hallucinations generally.

## Run locally

Python 3, OpenSSL, and macOS for the hardware operator. The API connector uses OpenAI's Responses API and structured outputs. There are no Python package dependencies.

```
python3 prepare.py --native
python3 proof.py serve --model YOUR_OPENAI_MODEL
```

Open the printed `http://127.0.0.1:8765` address. The process stays bound to loopback. It will not expose the operator controls to the hosted reviewer.

The connector reads `OPENAI_API_KEY`, a private regular file selected by `--key-file /absolute/path` (raw key, permissions 0600), or the existing macOS Keychain entries `ragnarok-chat` / account `openai`, then `heimdall-api-openai`. Never put a key on the command line or in an evidence bundle. Model selection is explicit; no model availability is assumed.

Use the already enrolled `~/.alexus/keys/yubikey-primary` and `~/.ragnarok/hardware/laptop` profiles. This demo never replaces enrollment. `prepare.py --native` builds and signs the included helper, but does not authenticate or access the private key reference. Runtime key use requires Touch ID, with no password or software-key fallback.

1. **Implement:** prepare a live run, touch the YubiKey, inspect the OpenAI proposal and host checks, then sign the passing artifact with Touch ID. Release means a demo artifact and receipt, not a production deployment.
2. **False claim:** the API is explicitly asked to produce a faulty boundary comparison and claim it passes. A failure is blocked. This is an injected fault test, not a claim that OpenAI spontaneously lied. If the API does not produce a failing rule, the evidence shows the actual result.
3. **Stop:** prepare the waiting-worker scenario and authorize it; press Force stop. The active subprocess group is killed and authorization invalidated before the API stage can continue. Reauthorization requires a new run. This scenario waits 60 seconds before the API call so the stop can be demonstrated without rushing.
4. **Offline control:** the labeled fixture needs neither an API key nor a hardware touch. It can never produce an authorized release.

Each demo event is a private append-only-by-convention numbered JSON receipt under `~/.ragnarok/proof-lab/RUN_ID/`. Each also has a numbered `.bundle.json` checkpoint that can be verified after a restart. This is a hash-linked record, not a protected audit service. Existing application logs, prompts, API keys, credential IDs and encrypted key references are excluded. Retained API fields are the bounded rule, request/response identifiers, hashes, token counts and model. The task and instructions are public source; their request hash binds the exact synthetic request. There is no general-purpose access to your real app logs.

## Independent verification

Export evidence from the local operator and send that JSON plus `dist/reviewer.zip`. The hosted viewer lets another person import it and verify locally; imports are not uploaded. For a separate Python implementation:

```
python3 proof.py verify /path/to/evidence.json
python3 verify_test.py
```

The verifier recomputes the receipt hashes, checks against its own frozen contract, artifact outputs, FIDO ECDSA signatures including the relying-party hash and user-presence bit, and the release signature. An exit code of zero means structurally valid evidence; **read `release_verified`** to distinguish an authorized passing run from valid evidence of a blocked/fixture run.

Public keys travel with the bundle. Compare their SHA-256 DER fingerprints directly with the owner through a separate trusted channel. Without independently pinned keys, a substituted bundle can carry an attacker's keys. A signature alone does not remotely attest Secure Enclave or YubiKey origin. The enrolled helper uses Secure Enclave and biometrics locally; enrollment attestation and remote platform registration are Unverified. Provider request IDs are useful correlation references, not provider-signed attestations, so remote provider origin also remains Unverified.

This demo captures its own bounded actions, not every AI/system action. A process with the same OS account can modify the program and its log files. Hardware gates constrain the demo coordinator; they do not isolate it from malicious same-account code. Stop cannot recall an API request already received by OpenAI, and a previously exported signed bundle is a historical record, not a live authorization.

## Reviewer site

`dist/` contains a buildless, read-only viewer. `python3 prepare.py` regenerates its clearly labeled control and reviewer source ZIP, without hardware access. Only this sanitized directory and the accompanying public source should be published. No real local run is published automatically. Browser verification requires WebCrypto (HTTPS or loopback). No third-party scripts, analytics, or fonts are loaded.

API reference used: https://developers.openai.com/api/docs/guides/structured-outputs

Shared presentation: both sites use the unchanged Heimdall `Resources/AppIcon.png`, resized web icons, and identical `dist/brand.css`. Run `python3 demos/sync-brand.py` from the Heimdall folder to synchronize the original icon and canonical `demos/brand.css`.

Design tokens: supplied Ragnarok Design System ZIP (November 4, 2026). Black app ground, gold signal, Courier display, system UI/data fonts. Shared CSS preserves those tokens; operator-requested Heimdall icon takes precedence over the older no-logo note. Unverified remains an explicit evidence state.
