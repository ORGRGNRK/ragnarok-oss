# RAGNAROK Design System

**Ragnarok** — "A system that helps me maintain my thought process and prepare for the unknown." A personal operating system (CLR — Rgnrk), with **Alexus** as its AI layer: a silver-haired, golden-eyed cat-eared companion who "learns, remembers, and evolves alongside the user." The brand is a black void lit by gold — ceremonial, quiet, watching.

## Sources

- GitHub: https://github.com/ORGRGNRK/ALEXUS (branch `master`) — portal (`apps/portal/index.html`), status dashboard (`apps/portal/status.html`), tools (`tools/*.html`), Alexus system prompt (`agents/prompts/alexus.md`). Explore these further for deeper context when designing.
- Uploads: Alexus seed portrait, mood variants (gold/violet/green/blue/red), chibi spritesheet, evolution infographic (`assets/`).

## Products / surfaces

1. **Portal** (`alexus.rgnrk.co`) — full-black ceremonial landing: Alexus portrait, eye glow, gold particles, "CLR — Rgnrk." wordmark, three nav links.
2. **Status dashboard** — utilitarian near-black service monitor: grouped rows, status dots (up/down/checking/local), refresh loop.
3. **Tools** (Forge Bot, Momentum Run, Deal Analyzer) — standalone utilities with their own warmer palettes; they share the panel/badge/mono-data grammar but are not the core identity.

## CONTENT FUNDAMENTALS

- **Voice**: declarative, compressed, unflinching. Short sentences. No hedging — the system prompt literally names hedging as the failure mode. "Say what's actually true."
- **Casing**: ceremonial elements are UPPERCASE with wide tracking ("SYSTEM ONLINE", "RAGNAROK / status"). Body copy is sentence case. Wordmark is exactly `CLR — Rgnrk.` (em dash, trailing period).
- **Person**: the system speaks *to* the operator ("you"), Alexus speaks as "I". No royal "we".
- **Verdicts as vocabulary**: PURSUE / MAYBE / IGNORE, GO / CONDITIONAL / NO-GO, GRADE A/B — decisions are stamped, not narrated.
- **No emoji.** Ever. Meaning is carried by casing, tracking, and color.
- **Data is honest**: timestamps ("checked 03:13:26"), latency ("212ms"), tabular numerals. Status is lowercase ("checking", "timeout", "down").
- **Naming**: Norse mythology (Ragnarok, Yggdrasil, Forge, Skald) + system verbs (`/boot`, `/switch`, `/end`, `learn()`, `become()`).
- Examples: "System Online" · "Forge reads the listing before you waste the drive." · "No boot = no ops." · "Three columns. One trunk."

## VISUAL FOUNDATIONS

- **Color**: pure black `#000` (portal) and `#0d0d0d` (app) grounds; gold `#c9a84c` → `#ffe680` is the only brand hue and is used sparingly, as signal. Status colors green `#22c55e` / red `#ef4444` / amber `#f59e0b` appear only as dots, stamps, and state text. Neutrals are a long gray ramp (`#e8e8e8` → `#2a2a2a`) doing most of the hierarchy work.
- **System states**: Green (execution) / Yellow (building) / Red (stabilize) / Limbo (gray, thinking) / Living (gold, underneath everything).
- **Type**: Courier New (light weight, huge letter-spacing, uppercase) for ceremony; system sans for UI; SF Mono for data. Text is small — 11–13px UI scale; hierarchy comes from color and tracking, not size.
- **Backgrounds**: darkness itself. Full-bleed character imagery at low opacity (0.08–0.22) behind vignettes; gold particle fields; radial gold haze. Never patterns, never gradients-as-decoration.
- **Glow, not shadow**: gold text-shadow on titles (`0 0 12px` + `0 0 40px`), dot glow on live status. Box-shadows are nearly absent on the core surfaces.
- **Animation**: slow, ceremonial reveals (600ms–2.2s fades, ease-out), ambient pulses (eye glow, checking dot at 1s). UI transitions fast (0.1–0.3s). Underline scaleX on nav hover. `prefers-reduced-motion` respected in tools.
- **Hover**: color brightens toward `--gold-bright` + glow; surfaces lift one step (`#111`→`#151515`); borders lighten (`#222`→`#333`). Press: scale(.98–.99) in tools.
- **Borders**: 1px, barely-there (`#1f1f1f`/`#222`). Cards = `#111` on `#0d0d0d` with 10px radius; small elements 4–6px; pills 20px; dots circular.
- **Layout**: centered single columns (640–760px) or full-viewport fixed compositions. Grids with 1px gutters (`gap:1px; background:#1a1a1a`) for row groups.
- **Imagery**: anime cyber-fantasy, forward-facing, cinematic. Black grounds, one dominant glow color per mood (gold default; violet=creative, green=recovery, blue=focus, red=alert). Silver/white hair, cat ears, glowing eyes — always.
- **Transparency/blur**: rgba golds for haze layers; blur only on glow ellipses, never frosted-glass UI.

## ICONOGRAPHY

- **No icon font, no icon set.** The repo's core surfaces use zero icons: 7px status dots, unicode arrows (`→`, `↓`, `↳`), dashes, and typographic pills carry all meaning.
- Tools embed a handful of inline 24px stroke SVGs (1.6px stroke: ID, lock, wrench, battery) — utility-local, not a system.
- **No logo exists.** The mark is the wordmark `CLR — Rgnrk.` set in Courier New. Do not draw one.
- Emoji: never. Unicode: arrows and em dashes only.
- If a design genuinely needs icons, use a thin-stroke set (e.g. Lucide at 1.5–1.75px stroke) and flag it — this is a substitution, not brand canon.

## Fonts

All type is system-native (Courier New, system sans, SF Mono) — the repo ships no webfont files, so there are no `@font-face` rules. Nothing to substitute.

## Index

- `styles.css` — global entry; imports `tokens/` (colors, typography, spacing, effects, base link styles)
- `assets/` — alexus-seed.jpg, mood portraits (`moods/`), chibi spritesheet, evolution infographic
- `components/core/` — Button, NavLink, Panel, Badge, StatChip, StatusDot, ServiceRow, VerdictPill, StateBadge, Wordmark
- `ui_kits/portal/` — portal landing recreation
- `ui_kits/status/` — status dashboard recreation
- `guidelines/` — specimen cards (Design System tab)
- `SKILL.md`, `github.md`

## Intentional additions

- `Wordmark` component — codifies the repeated `.brand`/`#title` pattern.
- `StateBadge` — the five RAGNAROK system states exist in prose (README/prompt) but had no UI; colors mapped from the status palette, Limbo=gray, Living=gold.
