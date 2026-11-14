# Ragnarok Work Atlas

A dated, read-only portfolio of the visible `~/Developer` inventory and selected source-oriented Seagate archive packages. Builtless HTML/JS/CSS; no external dependencies, analytics, model calls or credentials.

```
python3 catalog.py
python3 validate.py
python3 -m http.server 8766 --bind 127.0.0.1 --directory dist
```

`catalog.py` inspects directory structure, document metadata/checksums and selected Python syntax without executing source. It does not follow aliases recursively. Descriptions are manually curated, conservative summaries. Dependency/build folders, raw logs, databases and private records are excluded. Parent and child components can overlap; source-file counts must not be summed as unique files.

`check-results.json` records three actually executed suites: Greenlight (16 cases), Doctor (34 tests), Proof Lab (20 tests). On regeneration, recorded checks are downgraded to stale when the named source checksums no longer match. Matching hashes retain a historical, dated observation; they do not rerun the tests or create third-party attestation. No whole-product runtime is declared verified.

`archive-projects.json` records **member-header metadata** from 31 chosen project packages in the Seagate consolidation snapshot. `archive-observation.json` records the scan scope and confirmed read-only mount. All 18 top-level archive entries were listed; secret material, private data exports, transcript content, disk images, encrypted repositories and other non-source payloads are withheld. Packages are not extracted or executed and their original bytes are not published.

The separate business opportunities document is a local file in Documents. It is intentionally outside this publication. No outreach was sent.

The source manifest preserves this Site's own identity and declares the `BUCKET` R2 binding. Build the Worker using `build-host.py` from reviewed `public/` assets in the publication checkout; the monorepo keeps its static local preview in `dist/`. Publish the generated Worker through the Sites workflow. Do not copy private source, runtime data, a credential file or the server archive into the deployment. `dist/catalog.json` contains only the curated metadata described above.

Shared presentation: both sites use the unchanged Heimdall `Resources/AppIcon.png`, resized web icons, and identical `dist/brand.css`. Run `python3 demos/sync-brand.py` from the Heimdall folder to synchronize the original icon and canonical `demos/brand.css`.

Design tokens: supplied Ragnarok Design System ZIP (November 4, 2026). Black app ground, gold signal, Courier display, system UI/data fonts. Shared CSS preserves those tokens; operator-requested Heimdall icon takes precedence over the older no-logo note. Unverified remains an explicit evidence state.

Background catalog and clean-commit synchronization is documented in `../../docs/sync.md`. The hosted catalog accepts sanitized metadata from separately authenticated Mac/Alexus publishers. Source changes and real hardware runs are not automatically uploaded.
