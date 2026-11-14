# ALEXUS

Native macOS and iOS app. Shared SwiftUI sources; no third-party runtime packages.

- Generate: `xcodegen generate`; build/check: `./check.sh`.
- Owner requirement: every applied repair needs a fresh enrolled Secure Enclave signature AND an enrolled YubiKey/uTrust FIDO assertion, bound to that exact tested candidate. No passwords, software signing fallback, reusable approval sessions or AI-issued approvals.
- The automated repair lane may change only `Sources/Views.swift` and `Sources/Models.swift`. Changes to the host, authorization, policy, build system or verification require a separately reviewed owner change. Do not expand this allowlist from inside a repair.
- Keep model work in a staging copy. Never apply, install or commit its proposal from a model process. Host applies only after independent checks, review and owner hardware approval.
- No prompts, credentials, raw agent output or unsanitized errors in receipts. Runtime and physical hardware behavior stay Unverified until observed.
- The app cannot stop the OS account owner or malicious same-account code from editing files. Do not describe this workflow as an OS-level isolation guarantee.
- Preserve other Ragnarok working-tree changes. Never use stash/reset/clean to make the parent repository clean.
