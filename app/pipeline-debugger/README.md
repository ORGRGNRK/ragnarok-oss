# Pipeline Debugger

This candidate repairs disposable copies. It does not merge a repair into your project.

The native app's Agent tab needs a scoped project folder, repair goal, an installed Ollama model, and an **outside acceptance JSON**. Local models are discovered from the configured Ollama endpoint. Choose an explicit cloud model if continuation is wanted. Claude text continuation uses the existing login with tools, hooks, MCP, skills and persistence disabled; direct OpenAI/Anthropic/Gemini APIs use existing environment credentials. No account or paid service is provisioned.

A minimal acceptance file, stored outside the project:

```json
{
  "image": "node:22.23.4-alpine",
  "editable": ["answer.js"],
  "checks": [{
    "id": "answer-is-42",
    "argv": ["node", "/validator/check.js"],
    "inputs": {"check.js": "/absolute/outside/check.js"}
  }]
}
```

The image must already be installed. The outside script can use `process.cwd()` to load the disposable project. Supply the actual assertion in that outside script; calling an editable project test is not an independent acceptance check. Dependencies must already be available in the image or scoped source. Network is disabled. macOS UI/toolchains cannot be assumed to work in Linux containers.

The engine's `repair` action takes `--cwd`, `--acceptance`, `--provider ollama`, `--model`, optional `--cloud-provider` / `--cloud-model`, and an optional new `--evidence` directory. Default is three rounds per stage, 120 seconds per command/request, 15 minutes per run, 128 KiB command output, 30 changed files per proposal. Source snapshots exclude generated directories, git metadata and common credential files; choose a narrow project and review the manifest. Scrubbing covers known patterns/configured values, not every possible secret embedded in arbitrary source.

Evidence contains source/validator manifests, baseline and candidate snapshots, actual command results, events, best checkpoint, selected diff and handoff packet. Existing baseline passes alone report unverified. A candidate must improve required checks without losing earlier required passes to become best. All snapshots are kept when tradeoffs remain. Stop cancels the owned process group and container; a cancelled callback cannot restore success.

`agent` (the old host-shell repair action) is disabled. `run` still executes the user's explicit command in the chosen folder; it is a command runner, not the isolated repair loop. Diagnose-only CLI transports do not support images; use supported APIs or a discovered Ollama vision model. `--json` wraps command/diagnosis output in a result envelope. `--log-file` is supported for `last` / `triage`; unsupported watch override fails explicitly.

Checks live in `checks/`: deterministic controller tests, engine regressions, native Swift bridge checks and explicit real-Docker isolation/cancellation checks. A fake provider passing a fixture does not validate live model repair. Development evidence is recorded outside the project in `pipeline-debugger-verification`.

The controller enforces three gates: proposal validity, frozen acceptance results, and no regression against retained passes. `policy.json` records budgets and validator/check identities. Each tested checkpoint records a structured decision (`baseline`, `reject`, `retain`, `accept`, `blocked`, or `cancelled`), gate results and reason code. Human-readable output and model verdicts cannot override those fields. Rejected proposals leave the workspace unchanged; a repeated identical rejected proposal stops that stage after two occurrences. The next request identifies both the previous decision and the restored workspace/checkpoint hash, so the model can distinguish failed candidate evidence from retained source. This is deterministic policy over recorded inputs, not a guarantee that models or arbitrary tests are repeatable.
