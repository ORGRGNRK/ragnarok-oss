# Ragnarok project and catalog sync

`bin/ragnarok-sync` is a per-user, five-minute service on the Mac and Alexus. It syncs **clean commits on enrolled tracking branches** with their existing upstream. It never creates commits, switches branches, stashes, resets, forces pushes, copies uncommitted files, or writes to Seagate.

- `init --role mac|alexus`: discover Git roots under `~/Developer` (bounded to five levels, no symlink traversal), enroll current tracking destinations and create private configuration.
- `once`: perform one bounded, locked cycle.
- `status`: read dated results and hold reasons.
- `install`: install a stable script plus a Mac LaunchAgent or Alexus user-systemd timer.

Configuration, publisher credentials, status and rotating receipts are in `~/.ragnarok/sync`, with private file permissions. Git stdout/stderr and remote URLs are never logged. Publisher tokens are separate per host and stored as secret runtime variables on the existing Work Atlas Site. They authorize only sanitized snapshot updates, not source changes or model execution.

Dirty repositories, missing upstreams, changed tracking destinations, divergent history, in-progress Git operations, hidden index flags, and custom checkout filters/submodules hold for manual handling. Repository hooks and fsmonitor are disabled. Network calls are noninteractive and time-bounded. Normal non-force pushes can still fail because of upstream permissions or races; those are recorded as holds.

There is no automatic branch mapping: Mac `macos` and Alexus `main` are not treated as equivalent. Enrollment does not create new remotes or upstreams. New Git roots require an explicit enrollment/configuration update. Files outside Git remain in place.

The Mac refreshes the curated catalog into a **private output file**, without modifying tracked site assets. The generator's checksum is pinned at enrollment; changed generator code holds until deliberately reviewed and re-pinned. Python runs in isolated mode. It inventories metadata and selected syntax without executing project source. Existing dated test observations retain their original dates, and changed source checksums downgrade those observations. A refresh does not rerun product tests or verify runtime behavior.

The Work Atlas Worker embeds the nine reviewed assets and uses Sites-managed R2 (`BUCKET`) for the last accepted snapshots. `/api/catalog` serves the Mac's sanitized catalog; `/api/sync/status` exposes aggregate host counts and timestamps only. Alexus can publish its aggregate heartbeat, not replace the Mac catalog. Ingress validates schema, pinned project identities, size, freshness and evidence-state boundaries. Missing or fifteen-minute-old heartbeats display Unverified. The original embedded inventory remains a fallback before the first catalog upload. Neither a sync heartbeat nor a matching checksum is independent attestation.

Build hosted source with `python3 build-host.py` when assets are in `public/`. In this monorepo, use `python3 demos/work-atlas/build-host.py --public-directory dist --output /tmp/ragnarok-work-host` to keep generated hosting output separate from the static local preview. Publication uses the existing Sites project and domain; source edits still require the normal Sites workflow. The daemon updates catalog data only. Proof Lab continues to use its published static viewer; real local hardware runs are not uploaded automatically.

Checks:

```
python3 checks/sync-check.py
python3 demos/work-atlas/build-host.py --public-directory dist --output /tmp/ragnarok-sync-worker-check
node checks/sync-worker-check.mjs
```

Stop Mac scheduling with `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/co.rgnrk.ragnarok.sync.plist`. On Alexus use `systemctl --user disable --now ragnarok-sync.timer`. These retain configuration and receipts. Remove the two `SYNC_*_TOKEN` runtime variables and redeploy to revoke upload access.
