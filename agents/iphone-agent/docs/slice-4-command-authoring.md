# Slice 4 — command authoring tools

Date: 2026-08-19

Status: **complete**

Slice 4 makes portable commands practical to create and exchange without requiring AI. Every
authoring route produces the same canonical command object and passes through the Slice 2
validator before output.

## CLI

The package publishes the `iphone-command` executable with four commands:

| Command | Purpose |
|---|---|
| `create` | Interactive guided authoring for all protocol actions, inputs, safety, verification, and failure behavior. |
| `from-text` | Conservative local natural-language patterns with no provider, network, or credential. |
| `validate` | Parse, normalize, and validate a JSON or YAML command file. |
| `convert` | Import JSON or YAML and export canonical JSON or author-friendly YAML. |

Examples from the ALEXUS repository root:

```sh
npm run cli --workspace @alexus/iphone-agent -- create --format yaml --output command.yaml
npm run cli --workspace @alexus/iphone-agent -- from-text "open Settings" --format json
npm run cli --workspace @alexus/iphone-agent -- validate command.yaml
npm run cli --workspace @alexus/iphone-agent -- convert command.yaml --to json --output command.json
```

Output defaults to standard output. `--output FILE` writes with owner-only permissions and
refuses to overwrite an existing file unless `--force` is present.

## Guided authoring

The guided flow collects:

- command identity and description;
- typed runtime inputs and secret markers;
- overall safety risk and optional extra confirmation;
- one or more actions from the full `0.1` vocabulary;
- action-specific fields such as app, target, text, direction, or condition;
- final observable screen text; and
- stop, bounded retry, request-help, or recovery failure behavior.

The result is normalized and schema-validated before it can be printed or written.

## Natural-language boundary

`ValidatingNaturalLanguageAuthor` accepts any future provider through the
`NaturalLanguageDraftProvider` interface. Provider output is treated as untrusted data:

1. normalize the proposed document;
2. validate it against the canonical schema and semantic checks;
3. run safety classification so `requiresConfirmation: false` cannot lower a risk floor; and
4. return it only after all checks pass.

The built-in `RuleBasedNaturalLanguageProvider` is local and deterministic. It supports only:

- `open <app>`
- `press home`, `press app switcher`, or `press back`
- `swipe up`, `down`, `left`, or `right`
- `wait for <screen text>`
- `assert <screen text>`

It rejects ambiguous requests, including sends and other potentially consequential actions,
and directs the author to guided creation. It does not call OpenAI or any other provider and
does not need an API key.

## Verification

The strict TypeScript build and 28 automated tests pass. Slice 4 coverage includes:

- JSON and YAML round trips;
- supported local text patterns;
- rejection of ambiguous requests;
- rejection of invalid future-provider output;
- proof that provider output cannot lower confirmation requirements;
- a complete guided-authoring flow;
- CLI validation;
- CLI text authoring; and
- CLI JSON-to-YAML conversion.

An interactive CLI smoke test created the `Open Settings` command as canonical YAML.

## Slice 5 handoff

The final hardening slice can now add command registries and `call`, version compatibility,
dry runs, resumable receipt execution, recovery commands, durable template management, and
additional device-state detection. These features remain runner/driver concerns; the command
creation interfaces stay independent of the execution mechanism.
