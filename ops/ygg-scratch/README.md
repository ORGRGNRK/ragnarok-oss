# ygg-scratch — Yggdrasil split rehearsal on the Mac (SCRATCH, not live)

Compose project `ygg-scratch`: `ygg-scratch-pg` (postgres:17-alpine, 127.0.0.1:5547) and
`ygg-scratch-nocodb` (nocodb/nocodb:2026.10.0, http://127.0.0.1:8091). Volumes `ygg-scratch_ygg_scratch_pgdata`
and `ygg-scratch_ygg_scratch_ncdata`. Nothing here is shared with `ragnarok-shop`.
Secrets: `.env` (chmod 600; NocoDB login = NC_ADMIN_EMAIL / NC_ADMIN_PASSWORD). Never paste them anywhere.

Always: `export PATH=$PATH:/opt/homebrew/bin:~/.orbstack/bin; cd ~/Developer/ygg-scratch`

| what | command |
|---|---|
| start | `docker compose -p ygg-scratch up -d` |
| stop (keeps data) | `docker compose -p ygg-scratch stop` |
| status | `docker compose -p ygg-scratch ps` |
| remove containers+volumes (scratch data gone) | `docker compose -p ygg-scratch down -v` |
| remove everything | the line above, then `docker rmi postgres:17-alpine` and `rm -rf ~/Developer/ygg-scratch` |

Never use plain `docker compose down` without `-p ygg-scratch` from another folder.

## Rebuild from nothing
1. `scripts/gen-env.sh` (only if .env is missing) then `docker compose -p ygg-scratch up -d pg`
2. `scripts/10-pull-and-restore.sh` — pg_dump the 5 DBs from Alexus `ygg-rehearsal-pg` over ssh, restore (owner ygg_app), grant ygg_read
3. `scripts/40-verify-mac.sh` — rows, max Id, sequences, md5 vs the rehearsal and vs the Alexus copy, Target_Key, view, grants
4. `docker compose -p ygg-scratch up -d nocodb`, then `cd tools && python3 nc_rebuild.py`
5. `docker exec -i ygg-scratch-pg psql -U postgres -d nocodb_meta < tools/nc_system_titles.sql && docker restart ygg-scratch-nocodb`
6. `python3 tools/nc_verify_split.py` (writes out/nc-verify.md); re-run step 3 to prove NocoDB changed no data

## Files
- docker-compose.yml, .env (600), initdb/01-roles.sh (roles ygg_app / ygg_read / nocodb, the 5 DBs + nocodb_meta)
- scripts/: gen-env.sh, 10-pull-and-restore.sh, 40-verify-mac.sh, split.conf, expected.txt
- tools/: nc_api.py (session login, no stored token), split_map.py, nc_rebuild.py, nc_verify_split.py,
  nc_system_titles.sql, live-field-meta.json (field settings only, from nocodb-20261027-0315.dump), live-copy/ (read-only copies of the live tools)
- dumps/ (600): the 5 pg_dump files. out/: verify-mac.md, verify-mac-after-nocodb.md, nc-verify.md, nc-rebuild.log
