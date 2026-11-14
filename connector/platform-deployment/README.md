# Secure MCP Docker Platform

A generic, self-contained **Docker Compose MCP platform** backed by PostgreSQL 17, featuring a **Hardware Presence Boot-Lock** (YubiKey FIDO2 + Apple Secure Enclave Touch ID biometrics for app companion modes).

All proprietary identifiers and personal references have been stripped into a clean, reusable platform template.

---

## 🔐 Hardware Presence Boot-Lock Architecture

The Docker container stack boots into a **LOCKED / SEALED** state by default:

```
┌────────────────────────────────────────────────────────┐
│                      DOCKER STACK                      │
│                                                        │
│  State: [ LOCKED / SEALED ]  ◀── (Boot Default)        │
│                                                        │
│  • Any query/tool call rejected with:                  │
│    "ERR_LOCKED: Hardware authorization required"       │
│  • Platform unseals ONLY after valid hardware proof    │
└───────────────────────────┬────────────────────────────┘
                            ▲
        ┌───────────────────┴───────────────────┐
        │                                       │
┌───────┴──────────────┐             ┌──────────┴───────────────┐
│     TERMINAL / CLI   │             │         APP MODE         │
│    YUBIKEY (FIDO2)   │             │   APPLE SECURE ENCLAVE   │
│                      │             │                          │
│ • Gold touch pad     │             │ • Native Touch ID        │
│ • CTAP2 / UP=1 bit   │             │ • LocalAuthentication    │
│ • Cross-platform     │             │ • macOS Companion App    │
└──────────────────────┘             └──────────────────────────┘
```

### Unlocking the Platform:
- **Terminal / Host CLI**: Run `./unlock.sh`. It checks for an inserted YubiKey and prompts for physical touch on the sensor pad. If no key is inserted, it falls back to Touch ID via Apple Secure Enclave.
- **App Companion Mode**: macOS desktop wrappers call Apple's `LocalAuthentication` framework (`deploy/auth/auth_gate.swift` compiled to `deploy/auth/auth-gate`) to verify biometric presence directly through the Apple Secure Enclave coprocessor.
- **Relocking**: Run `./lock.sh` to immediately re-seal the stack, or let the session lease expire automatically (default TTL: 60 minutes).

---

## 🗄️ Database Tables & Schema

The PostgreSQL database (`app_db`) is initialized with generic, extensible business tables:

1. **`items`**: Generic item/inventory records:
   - `id`, `sku` (unique), `name`, `category`, `condition`, `status`, `cost_basis`, `list_price`, `sold_price`, `sold_date`, `quantity`, `platform`, `notes`, `metadata` (JSONB), timestamps.
2. **`items_with_totals` (View)**:
   - Computes `total_cost_basis`, `total_revenue`, and realized `net_profit`.
3. **`leads`**: CRM pipeline and deal acquisition:
   - `id`, `title`, `contact`, `stage`, `target_value`, `offer_value`, `source`, `notes`, `metadata` (JSONB), timestamps.
4. **`channels`**: Sales channels and exit profiles:
   - `id`, `name`, `type`, `fee_pct`, `active`, `notes`, `metadata` (JSONB), timestamps.
5. **`mcp.receipts` & `mcp.auth_state`**:
   - Cryptographic SHA-256 audit ledger and hardware session authorization logs.

---

## 🛠️ MCP Tools

Tools adhere to the generic platform naming standard and reflect the updated tables:

| Tool | Description | Access While Locked? |
|---|---|:---:|
| `platform_status` | Operational health, lock state, and session lease TTL. | ✅ Allowed |
| `platform_unlock` | Unlocks platform with hardware presence token. | ✅ Allowed |
| `platform_lock` | Immediately seals the platform. | ✅ Allowed |
| `platform_list_items` | Page through inventory items with filters (`status`, `category`). | 🔒 Requires Unlock |
| `platform_get_item` | Full record lookup for a single item by `id` or `sku`. | 🔒 Requires Unlock |
| `platform_summarize_items` | Aggregate financial rollups grouped by `status`, `category`, `platform`, or `condition`. | 🔒 Requires Unlock |
| `platform_list_leads` | Pipeline tracking for deals and leads with `stage` filter. | 🔒 Requires Unlock |
| `platform_list_channels` | Sales outlets and outbound partner profiles. | 🔒 Requires Unlock |
| `platform_search_items` | Semantic vector search over items using Ollama embeddings. | 🔒 Requires Unlock |

---

## 🚀 Quickstart

### 1. Build and Start the Stack
```bash
./install.sh                # generates .env with secure random secrets, builds, and starts containers
./install.sh --with-search  # + Ollama semantic vector search profile
```

### 2. Unlock the Stack with Hardware Presence
```bash
./unlock.sh                 # prompts for YubiKey touch or Apple Touch ID biometric
```

### 3. Query via MCP
- **stdio**:
  ```bash
  docker compose exec -T mcp node dist/index.js
  ```
- **Streamable HTTP**:
  `http://127.0.0.1:8787/mcp` (or `/status`, `/unlock`, `/lock`)

### 4. Teardown
```bash
./uninstall.sh                                              # stops and removes containers (data kept)
PLATFORM_CONFIRM_DELETE=<project> ./uninstall.sh --delete-data # requires hardware auth before purging volumes
```

## Security test suites

The companion suites are in [security-test-suites/](security-test-suites/SUITES_OVERVIEW.md).
See their configuration and disposable-deployment requirements before running them.
