# Portability audit

Scope: scanned 90 workspace text-file candidates outside node_modules and dist for personal names, private host addresses and absolute user paths. Separately checked .env without printing values. Read the client provisioning implementation, receipt hook installer/classifier and hook tests, authentication scripts, Dockerfile, Compose configuration, database initialization scripts, package manifest, environment generator, and install-guide validator. This is a static review plus local checks; no running containers, client configurations, hardware authentication, or external services were tested. The supplied native auth-gate binary was not inspected.

## Removed assumptions

- Replaced personal names in documentation, comments, install instructions and evaluation prompts with operator/host wording.
- Removed the private embedder address and user-home configuration discovery from environment generation. The local .env embedder endpoint now uses http://ollama:11434; enable the search profile or configure PLATFORM_EMBEDDER_URL explicitly. No passwords were changed.
- Removed private remote-host addresses from receipts. PLATFORM_RECEIPTS_REMOTE_HOSTS optionally supplies a JSON address-to-label map; its default is empty.
- Restricted the default HTTP host allowlist to loopback names; deployments can set PLATFORM_HTTP_ALLOWED_HOSTS.
- Removed installation of unrelated prompt hooks referencing scripts outside this workspace.
- Resolve FIDO2 executables through PATH or FIDO2_TOKEN/FIDO2_ASSERT; PLATFORM_FIDO2_KEYS_DIR can supply an enrollment directory.
- Resolve receipt scripts relative to this workspace and Node through PATH rather than a particular Developer directory or Node installation.
- Provisioning requires absolute PLATFORM_KIT_DIR and PLATFORM_CLIENT_BASE settings (legacy RAGNAROK_* equivalents remain accepted).
- Aligned package-lock root package/bin naming with package.json.

## Dependencies and compatibility still present

- Legacy YGG_* and RAGNAROK_* environment keys, ygg_app/ygg_read roles, scratch database names, .ragnarok receipt paths, and ragnarok_get_client_stack identifiers remain compatibility interfaces. Removing them requires a coordinated database, client and host-hook migration. Existing installed hooks and logs outside this workspace were not modified.
- The legacy business evaluation/receipt utilities still expect their historical Business schema, ygg_business/ygg_receipts databases, and ygg roles. Default Compose initializes app_db and generic platform tables; these legacy utilities are not interchangeable with the generic platform. Pointing their env-file lookup to this workspace does not migrate their schema.
- Provisioning still requires a separately supplied client kit providing new-client.sh and ./kit up/seed/verify, with port bases 5442/8090/8790 and database clientdata. That kit is not bundled or verified.
- Docker Compose service names, internal port 5432, app_db/app_owner/app_read, MCP port 8787, and schema names are built-in deployment contracts. Published ports are configurable.
- Dockerfile and Compose pin Node, PostgreSQL, NocoDB and Ollama image tags. package.json pins npm packages; no availability or vulnerability lookup was performed.
- Optional semantic search requires Ollama and the configured embedding model. The pull job now prefers PLATFORM_EMBEDDER_MODEL, matching the MCP service, with BUSINESS_EMBEDDER_MODEL retained as a fallback.
- Apple Secure Enclave/Touch ID uses a macOS-specific Swift implementation; FIDO2 uses libfido2 tools and enrolled credentials. Hardware behavior was not tested.
- The supplied auth-gate executable may contain build-machine metadata; it was neither inspected nor rebuilt. Rebuild from auth_gate.swift on the target Mac.

Personalized filesystem directory names of the surrounding workspace were not renamed.

## Validation

Final targeted scan: 92 workspace text files, including .env, with no matches for the personal names, private addresses, personal domain or absolute user paths searched. Excluded node_modules, dist, .git and the native executable; this is not a guarantee against other identifying strings. All 11 receipt-hook Node tests passed. Edited shell scripts passed syntax checks; a clean zsh source check resolved the adjacent receipt script. JSON parsing and package/lock root metadata checks passed. npm build, install-guide schema validation and the Vitest suite were started but did not return results during the review; their outcome and regeneration of dist remain unverified. No Docker or hardware integration checks were run.
