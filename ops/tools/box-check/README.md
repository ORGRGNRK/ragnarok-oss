# box-check

`doc-reader` reads the document. **`box-check` checks the machine.**

## Why it exists

Every other check on this box is **doc-anchored**. `prose-drift` verifies
sentences in `~/CLAUDE.md`. `repo-drift` walks an array of repo names.
`doc-reader` resolves referents that appear in prose. Every one of them can only
ever see *what somebody already wrote down*.

On 2026-09-08 that gap was measured. The box was carrying, at the same moment:

- an `/etc/fstab` whose two drive entries were **crossed** against the live mounts
- a **1.8 TB disk that nothing in fstab mounts**, written to hourly by `transcript-backup.sh`
- `/` at **84% with 828 GB unallocated** in its own volume group
- a six-day-old loss of Airtable schema-write access

Every check on the box reported clean, and every one of them was *correct* —
no document made a claim about any of it. All four were found by a human
looking. That is the hole this covers: **state that is true whether or not
anyone wrote it down.**

## The five probes

Each traces to one of the things that was actually missed.

1. **fstab ↔ reality.** For every fstab entry: does its device exist, and is it
   mounted where fstab says? And the other direction — is any live `/mnt` mount
   *not* reproduced by fstab, so it vanishes at the next reboot?
2. **Unclaimed filesystems.** A partition mounted nowhere and named in no fstab
   entry. Not a fault by itself; but nothing on this box knows it exists.
3. **Fullness + headroom.** `df`, plus the volume group's free extents. **The
   finding is the pair.** "/ is at 84%" is a nag you learn to ignore. "/ is at
   84% *and there are 828 GB unallocated in its own VG*" is one command.
4. **Write destinations that don't survive a reboot.** Derived by scanning the
   scripts, never a hardcoded list — a list of paths typed into this file would
   go stale the way the F55's IP did while still looking authoritative.
5. **Airtable schema-write capability** — reported as permanently `UNKNOWN`,
   see below.

## What it deliberately does not do

**Services, ports, pm2 apps, systemd units.** `crew doctor`, `ragnarok` and
`ragnarok-did` own those. A second opinion that can disagree with them is worse
than no opinion.

**It never changes anything.** It does not mount, unmount, edit fstab, or extend
a volume. Every fix it can motivate changes what happens *at boot* — the class
`n8n-drift` refuses to automate, for the same reason: a seat that "fixes" a
mount is a seat that can make this box come up wrong with nobody watching.
Report, never repair.

## The verdicts

| | |
|---|---|
| **ALARM** | a measured state that costs something the next time it matters |
| **NOTE** | true and worth seeing, not urgent |
| **UNKNOWN** | the source could not be read, or the question cannot be answered read-only |

`UNKNOWN` is never rendered as clean and is printed **even when there are zero
alarms**. `ragnarok-did` shipped the opposite once and printed *"All 0 running
apps are up"* in green off a dead pm2 daemon.

### The permanent unknown

Airtable schema-write access was lost around 2026-09-02 and nothing noticed for
six days. The obvious probe does not work: `/v0/meta/whoami` returns this token's
id and **no scope list**. The only real test is to attempt a schema write, and a
checker with side effects is not a checker.

So it reports `UNKNOWN` forever, on purpose. Deleting a check because it cannot
be automated is exactly how that capability went missing unnoticed in the first
place.

## Calibration — the first run was wrong twice

Shipping this required the same discipline `doc-reader` needed the same day:

- It reported **the root filesystem** as *"mounted from a device that does not
  exist"*, because `/dev/disk/by-id/dm-uuid-LVM-…` would not resolve. The
  loudest possible false alarm. An fstab spec this parser cannot resolve on a
  mount that is *working right now* is `UNKNOWN` — a limit of the checker, not a
  fault on the box.
- It reported **16 boot hazards** from grepping *documents* — `/mnt/nvme`,
  `/mnt/coldarchive`, and `/mnt/newdri`, which is a path truncated mid-sentence
  in prose. Now it scans executable scripts only, and only reports a mountpoint
  that **is mounted today** — because "this works now and stops working after a
  reboot" is the whole claim worth making. A path named in code but never
  mounted is history, and history reported as an alarm teaches you to skim.

This channel reaches a phone, so it earns stricter controls than a report does.

## Tests

`tests/box-fixtures.py` — **22 assertions**, hermetic (every check is a pure
function over injected machine state, so it feeds whole fictional machines and
never reads the real box). Seven are negative controls, including cases 4 and 17
which force back exactly the two false-alarm families above. Count asserted
(`EXPECTED = 22`). Mutation-proved both ways.

Every probe is also wrapped: an exception becomes an `UNKNOWN` naming the probe
that threw, so one bad parse cannot take the run down and print nothing —
silence that looks exactly like a clean box.

## Running it

```
box-check              # silent unless something is wrong
box-check -v           # everything, including what is fine
box-check --notify     # push ALARMs to the owner's phone (what the timer does)
```

`box-check.timer`, daily at **12:30** — five past `n8n-drift`, continuing the
noon chain. `[TEST]` with `BOX_CHECK_TEST=1`, `[MANUAL]` for a hand run,
unprefixed only from the timer. `RAGNAROK_LANE=system`.

**Unlike `doc-reader`, this one earns a timer.** A crossed fstab is an alarm, not
a ratio — it costs you a backup lane at a moment you did not choose.

Nothing is queued to the conveyor: `ACTIONABLE_PATTERNS` is empty, because every
fix here changes what runs at boot.

Read-only. Exit 0 always.
