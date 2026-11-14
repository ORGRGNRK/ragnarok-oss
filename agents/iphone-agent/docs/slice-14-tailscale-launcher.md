# Slice 14 — Tailnet Launcher Exposure

Completed and remotely verified on 2026-08-24.

## Outcome

The existing signed Mac launcher remains bound to `127.0.0.1:4177` and remains the process that
owns iPhone Mirroring permissions. Tailscale Serve now publishes that loopback service at:

```text
https://<your-mac>.<tailnet>.ts.net/
```

The endpoint is tailnet-only. It is not a public Funnel and is not bound to the home LAN.

## Host security

The launcher's existing Host-header guard initially and correctly rejected the proxied request as
`LOCAL_ONLY`. Startup now asks the local Tailscale CLI for `Self.DNSName`, validates that it is an
exact `*.ts.net` DNS name, and adds only that name to the allowlist. It does not accept arbitrary
tailnet hosts or suffix wildcards.

If Tailscale is stopped, absent, slow, or returns malformed state, discovery returns no proxy
hosts and the launcher remains localhost-only. The listener itself never leaves loopback.

## Live configuration

The requested operational configuration was applied with:

```sh
tailscale serve --bg --yes 4177
```

Tailscale state is external to git and must be rechecked rather than inferred. The launcher and
Tailscale do not auto-start on this Mac. Disable this exposure without changing launcher code by
running:

```sh
tailscale serve --https=443 off
```

## Verification

- Tailscale reported the Mac as connected at its tailnet address (100.x.y.z) and `alexus` as a direct peer.
- Tailscale Serve reported an HTTPS tailnet-only proxy to `http://127.0.0.1:4177`.
- An unallowlisted Host is rejected by automated coverage.
- A request from `alexus` returned the live macOS platform and all six launcher commands.
- The remote bootstrap returned a fresh per-launch mutation token.
- A token-authenticated remote dry-run of `Open Settings` returned HTTP 200, `supported: true`,
  one step, and `actionsExecuted: 0`.
- `npm run check` passed with 98/98 automated tests.

No live phone action was needed for this network acceptance. The existing execution, local native
confirmation, stale-screen binding, risk ceilings, and screenshot storage behavior are unchanged.

## Next architecture

This solution is intentionally available only while the Mac and launcher are running. The plan
for an always-on Linux interface with an outbound signed Mac worker is
[`option-2-alexus-control-plane-plan.md`](./option-2-alexus-control-plane-plan.md).
