#!/usr/bin/env python3
"""
check.py — a checker for THE BOX, not for a document.

WHY IT EXISTS, and it is the opposite of doc-reader's reason. Every check on
this machine is DOC-ANCHORED: prose-drift verifies sentences in ~/CLAUDE.md,
repo-drift walks an array of repo names, doc-reader resolves referents that
appear in prose. All of them can only ever see what somebody already wrote down.

On 2026-09-08 that gap was measured. The box carried, simultaneously:

  - an fstab whose two drive entries were CROSSED against the live mounts
  - a 1.8 TB disk that nothing in fstab mounts, written to hourly
  - / at 84% with 828 GB sitting unallocated in the volume group
  - a six-day-old loss of Airtable schema-write access

Every check on the box reported clean, correctly, because no document made a
claim about any of it. All four were found by a human looking. THAT is the
hole this file covers: state that is true whether or not anyone wrote it down.

WHAT IT DELIBERATELY DOES NOT DO. It does not check services, ports, pm2 apps
or systemd units — `crew doctor`, `ragnarok` and `ragnarok-did` own those, and a
second opinion that can disagree with them is worse than no opinion. It stays on
storage, boot-survival, headroom, and declared-but-unverifiable capability.

IT NEVER CHANGES ANYTHING. It does not mount, unmount, edit fstab, or extend a
volume. Every fix it can motivate changes what happens at BOOT, which is the
class n8n-drift refuses to automate: a seat that "fixes" a mount is a seat that
can make this box come up wrong with nobody watching. Report, never repair.

THE VERDICTS, same doctrine as doc-reader:
  ALARM   — a measured state that costs something the next time it matters.
  NOTE    — true and worth seeing, not urgent.
  UNKNOWN — the source could not be read, or the question cannot be answered
            read-only. NEVER rendered as clean. `ragnarok-did` shipped the
            opposite once and printed "All 0 running apps are up" in green.

Silent when clean. Read-only. Exit 0 always.
"""

import json
import os
import re
import subprocess
import sys

ALARM, NOTE, UNKNOWN = "ALARM", "NOTE", "UNKNOWN"

# Code roots scanned for /mnt references. Deliberately a list of ROOTS, not a
# list of mountpoints: hardcoding the paths that must survive a reboot is the
# F55-IP failure shape — the answer changes every time someone writes a script.
CODE_ROOTS = ["~/scripts", "~/repos", "~/crew", "~/panes", "~/bin"]

FULL_PCT = int(os.environ.get("BOX_CHECK_FULL_PCT", "80"))


# --- collectors: the only functions that touch the live box ------------------
# Each returns None when its source is unreadable, so every caller can tell
# "empty" from "could not look". They are separated from the checks below so
# the fixtures can inject a whole machine without one existing.

def sh(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else None
    except Exception:
        return None


def read_fstab(path="/etc/fstab"):
    try:
        return open(path).read()
    except Exception:
        return None


def read_mounts(path="/proc/self/mounts"):
    try:
        return open(path).read()
    except Exception:
        return None


def read_blocks():
    out = sh(["lsblk", "-J", "-o", "NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID,TYPE"])
    if not out:
        return None
    try:
        return json.loads(out)["blockdevices"]
    except Exception:
        return None


def read_df():
    return sh(["df", "-P", "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs"])


def read_vg_free():
    # sudo -n: never prompt. A timer has no terminal, and a checker that hangs
    # waiting for a password is a checker that silently stops running.
    return sh(["sudo", "-n", "vgs", "--noheadings", "--nosuffix", "--units", "b",
               "-o", "vg_name,vg_size,vg_free"])


def read_mnt_refs(roots=None):
    """Which /mnt paths does the code on this box actually write to?"""
    roots = [os.path.expanduser(r) for r in (roots or CODE_ROOTS)]
    roots = [r for r in roots if os.path.exists(r)]
    if not roots:
        return None
    try:
        p = subprocess.run(["grep", "-rhoI", "--exclude-dir=node_modules", "--exclude-dir=.git",
                            "--exclude-dir=dist", "--exclude-dir=archive", "--exclude-dir=.venv", "--exclude-dir=tests",
                            "--include=*.sh", "--include=*.py", "--include=*.mjs", "--include=*.js",
                            "-E", r"/mnt/[a-zA-Z0-9_-]+"] + roots,
                           capture_output=True, text=True, timeout=120)
    except Exception:
        return None
    # exit 1 = no matches (a real, empty answer); exit 2 = some paths unreadable,
    # but whatever it DID read is still true. Only a crash is unreadable.
    out = p.stdout
    if p.returncode not in (0, 1, 2):
        return None
    refs = {}
    for line in out.splitlines():
        refs[line.strip()] = refs.get(line.strip(), 0) + 1
    return refs


# --- parsing -----------------------------------------------------------------

def parse_fstab(text):
    """[{spec, target, fstype, opts}] for real entries only."""
    rows = []
    for line in (text or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split()
        if len(f) < 3:
            continue
        rows.append({"spec": f[0], "target": f[1], "fstype": f[2],
                     "opts": f[3] if len(f) > 3 else ""})
    return rows


def parse_mounts(text):
    """{target: (source, fstype)} from /proc/self/mounts."""
    out = {}
    for line in (text or "").splitlines():
        f = line.split()
        if len(f) >= 3:
            out[f[1]] = (f[0], f[2])
    return out


def flatten(blocks, out=None):
    out = [] if out is None else out
    for b in blocks or []:
        out.append(b)
        flatten(b.get("children"), out)
    return out


def uuid_index(blocks):
    """{UUID: device} plus, under a reserved key, every device — because an
    fstab spec may name a device that HAS no uuid (a dm node), and dropping
    those made three correct mounts read as missing disks."""
    idx = {b["uuid"]: b for b in flatten(blocks) if b.get("uuid")}
    idx["\x00all"] = flatten(blocks)
    return idx


def flatten_all(uuids):
    """Every device the index was built from, uuid or not."""
    return uuids.get("\x00all", list(uuids.values()))


def resolve_spec(spec, uuids):
    """The device an fstab spec names, or None."""
    if spec.startswith("UUID="):
        return uuids.get(spec[5:])
    if spec.startswith("LABEL="):
        for b in flatten_all(uuids):
            if b.get("label") == spec[6:]:
                return b
    if spec.startswith("/dev/"):
        # by-uuid / by-id / by-label are symlinks to the real node.
        real = os.path.realpath(spec)
        for b in flatten_all(uuids):
            if "/dev/" + b.get("name", "") in (spec, real):
                return b
        # A device-mapper node: lsblk names it "ubuntu--vg-ubuntu--lv" while the
        # spec resolves to /dev/dm-0, so compare through /dev/mapper/<name>,
        # which is the symlink that connects the two.
        base = os.path.basename(real)
        for b in flatten_all(uuids):
            name = b.get("name", "")
            if name == base:
                return b
            if name and os.path.realpath("/dev/mapper/" + name) == real:
                return b
    return None


# --- checks ------------------------------------------------------------------
# Pure functions over parsed data. A finding is (severity, headline, [detail]).

def check_fstab_vs_reality(fstab_text, mounts_text, blocks):
    """Does the running machine match the one fstab would produce at boot?

    THE MEASUREMENT, NOT THE VERDICT. Same discipline as doc-reader's ABSENT:
    a disagreement is stated as "fstab puts X here, X is actually there". Which
    one is wrong is a reading — a half-finished migration and an accident look
    identical from here — so it prints both and leaves the ruling to the owner.
    """
    if fstab_text is None:
        return [(UNKNOWN, "/etc/fstab could not be read, so nothing here was checked", [])]
    if mounts_text is None or blocks is None:
        return [(UNKNOWN, "the live mounts or block devices could not be read", [])]

    fstab, mounts, uuids = parse_fstab(fstab_text), parse_mounts(mounts_text), uuid_index(blocks)
    found = []

    for e in fstab:
        if e["fstype"] == "swap" or e["target"] in ("none", "/proc", "/sys"):
            continue
        dev = resolve_spec(e["spec"], uuids)
        if dev is None:
            # Is it working right now regardless? Then this parser is the thing
            # that failed, not the disk, and saying so is the honest answer.
            if e["target"] in mounts:
                found.append((UNKNOWN,
                              f"could not resolve fstab's device for {e['target']}",
                              [f"spec: {e['spec']}",
                               f"It IS mounted right now (from {mounts[e['target']][0]}), so this is a "
                               "limit of this checker, not a fault on the box."]))
            elif "nofail" in e["opts"].split(","):
                # nofail is a DECLARATION that this disk comes and goes. The
                # Lexar was unplugged on purpose on 2026-09-08 and this branch
                # alarmed to the owner's phone for it — an alert that fires every
                # day for a thing he did deliberately is how an alarm channel
                # gets muted, and a muted channel is the failure this whole
                # checker exists to prevent. Reported, never alarmed.
                found.append((NOTE, f"fstab declares {e['target']} but its disk is not connected",
                              [f"{e['spec']} matches no disk on this box.",
                               "The entry is nofail, so boot is unaffected and the mount "
                               "comes back on its own when the disk is plugged in.",
                               "Expected for a drive that is unplugged on purpose; a "
                               "surprise only if you thought it was attached."]))
            else:
                # No nofail: the boot genuinely depends on a disk that is gone.
                found.append((ALARM, f"fstab mounts {e['target']} from a device that does not exist",
                              [f"{e['spec']} matches no disk on this box.",
                               "The entry is NOT nofail, so at the next boot that mountpoint "
                               "will be empty and systemd will wait on it first."]))
            continue
        live = dev.get("mountpoint")
        if live is None:
            found.append((NOTE, f"fstab declares {e['target']} but /dev/{dev['name']} is not mounted",
                          [f"({dev.get('label') or 'no label'}, {dev.get('size')}) — "
                           "expected if the disk is unplugged; a surprise if it is not."]))
        elif live != e["target"]:
            found.append((ALARM, f"fstab and the running machine DISAGREE about /dev/{dev['name']}",
                          [f"fstab puts it at {e['target']}.  It is actually at {live}.",
                           f"({dev.get('label') or 'no label'}, {dev.get('size')}, {dev.get('fstype')})",
                           "One of those is wrong and a reboot will pick fstab's answer."]))

    # The other direction: a live mount nothing in fstab reproduces.
    targets = {e["target"] for e in fstab}
    for tgt, (src, fstype) in sorted(mounts.items()):
        if not tgt.startswith("/mnt/") or tgt in targets:
            continue
        found.append((ALARM, f"{tgt} is mounted now and NOTHING in fstab brings it back",
                      [f"{src} ({fstype}) was mounted by hand.",
                       "It disappears at the next reboot, with no error."]))
    return found


def check_unclaimed_devices(blocks, fstab_text):
    """Filesystems on this box that nothing mounts and nothing declares."""
    if blocks is None:
        return [(UNKNOWN, "block devices could not be listed", [])]
    fstab = parse_fstab(fstab_text or "")
    specs = {e["spec"] for e in fstab}
    out = []
    for b in flatten(blocks):
        if b.get("type") not in ("part", "disk") or not b.get("fstype"):
            continue
        if b.get("fstype") in ("LVM2_member", "swap"):
            continue
        if b.get("mountpoint"):
            continue
        if f"UUID={b.get('uuid')}" in specs or f"LABEL={b.get('label')}" in specs:
            continue
        out.append((NOTE, f"/dev/{b['name']} ({b.get('size')}, {b.get('fstype')}) is mounted nowhere "
                          f"and named in no fstab entry",
                    [f"label: {b.get('label') or '(none)'}   uuid: {b.get('uuid') or '(none)'}",
                     "Not a fault by itself — but nothing on this box knows it exists."]))
    return out


def check_headroom(df_text, vg_text):
    """Fullness, and the free space that would fix it.

    THE FINDING IS THE PAIR. "/ is at 84%" is a nag. "/ is at 84% and there are
    828 GB unallocated in its own volume group" is an action, and neither half
    says it alone. That pairing is why this is not just `df` in a cron job.
    """
    if df_text is None:
        return [(UNKNOWN, "df could not be read, so fullness was not checked", [])]
    out, full = [], []
    for line in df_text.splitlines()[1:]:
        f = line.split()
        if len(f) < 6 or not f[4].endswith("%"):
            continue
        pct = int(f[4].rstrip("%"))
        if pct >= FULL_PCT:
            full.append((f[5], pct, f[0], f[3]))
    if not full:
        return out

    if vg_text is None:
        vg = None
    else:
        vg = []
        for line in vg_text.splitlines():
            p = line.split()
            if len(p) >= 3:
                try:
                    vg.append((p[0], int(float(p[1])), int(float(p[2]))))
                except ValueError:
                    pass

    for mp, pct, dev, avail_kb in full:
        detail = [f"{int(avail_kb)//1024//1024} GB free on {dev}."]
        sev = NOTE
        if vg is None:
            detail.append("Could not read the volume group — run `sudo vgs` to see if there is "
                          "unallocated space that would fix this.")
            sev = UNKNOWN
        else:
            for name, size, free in vg:
                if free > 50 * 1024**3 and "mapper" in dev:
                    sev = ALARM
                    detail.append(f"Volume group {name} has {free//1024**3} GB UNALLOCATED — "
                                  f"space you already own and are not using.")
                    detail.append(f"One command uses it: sudo lvextend -r -l +100%FREE {dev}")
        out.append((sev, f"{mp} is {pct}% full", detail))
    return out


def check_write_destinations(refs, fstab_text, mounts_text, verbose=False):
    """Every /mnt path the code writes to — does it survive a reboot?

    Derived, never a hardcoded list. The destinations change whenever someone
    writes a script, and a list typed into this file would go stale the way the
    F55's IP did, while still looking authoritative.
    """
    if refs is None:
        return [(UNKNOWN, "could not scan the code for /mnt destinations", [])]
    if fstab_text is None or mounts_text is None:
        return [(UNKNOWN, "fstab or the live mounts could not be read", [])]
    targets = {e["target"] for e in parse_fstab(fstab_text)}
    mounts = parse_mounts(mounts_text)
    out = []
    seen = {}
    for path, n in refs.items():
        mp = "/".join(path.split("/")[:3])          # /mnt/<name>
        seen[mp] = seen.get(mp, 0) + n
    for mp, n in sorted(seen.items(), key=lambda kv: -kv[1]):
        if mp in targets:
            continue
        if mp not in mounts:
            # Named in a script but never mounted: dead reference, not a boot
            # hazard. Reported only under -v, because there is nothing to lose.
            if not verbose:
                continue
            out.append((NOTE, f"code names {mp} ({n} reference(s)) and it is not mounted",
                        ["Probably a path from an older layout. Nothing breaks at reboot "
                         "that is not already broken now."]))
            continue
        out.append((ALARM, f"code writes to {mp}, it works today, and NO fstab entry brings it back",
                    [f"{n} reference(s) in scripts. Mounted now from "
                     f"{mounts.get(mp, ('an unknown device',))[0]}.",
                     "After a reboot the mount is gone and those writes either land on the "
                     "root filesystem or are skipped quietly."]))
    return out


def check_airtable_capability():
    """The one thing here that CANNOT be answered read-only, stated as such.

    Schema-write access was lost on ~2026-09-02 and nothing noticed for six
    days. The obvious probe does not work: /v0/meta/whoami returns this token's
    id and NO scope list, so there is no read-only way to ask whether it may
    still write schema. The only test is to attempt a schema write, which this
    checker will not do — a checker with side effects is not a checker.

    So it renders UNKNOWN, forever, on purpose. That is the honest answer and it
    keeps the question visible. Deleting the check because it cannot be automated
    is exactly how the capability went missing unnoticed in the first place.
    """
    return [(UNKNOWN, "whether the Airtable token can still write SCHEMA is unverifiable from here",
             ["/v0/meta/whoami reports the token id and no scopes.",
              "The only probe is an actual schema write, which this checker will not perform.",
              "Last known-good schema write: 2026-09-01 22:26. Last measured refusal: 2026-09-08."])]


# --- report ------------------------------------------------------------------

def guarded(name, fn, *args):
    """Run one probe; an exception becomes UNKNOWN instead of killing the run."""
    try:
        return fn(*args)
    except Exception as e:
        return [(UNKNOWN, f"the {name} check crashed and reported nothing",
                 [f"{type(e).__name__}: {e}",
                  "The other checks still ran. This one told you nothing, which is "
                  "not the same as finding nothing."])]


def collect(verbose=False):
    fstab = read_fstab()
    mounts = read_mounts()
    blocks = read_blocks()
    return (guarded("fstab-vs-reality", check_fstab_vs_reality, fstab, mounts, blocks)
            + guarded("unclaimed-device", check_unclaimed_devices, blocks, fstab)
            + guarded("headroom", check_headroom, read_df(), read_vg_free())
            + guarded("write-destination", check_write_destinations, read_mnt_refs(), fstab, mounts, verbose)
            + guarded("airtable-capability", check_airtable_capability))


def render(findings, verbose=False):
    alarms = [f for f in findings if f[0] == ALARM]
    notes = [f for f in findings if f[0] == NOTE]
    unknowns = [f for f in findings if f[0] == UNKNOWN]
    lines = []

    if not alarms and not verbose:
        # Silent when clean, like every other check here — but UNKNOWNs are not
        # clean and are never swallowed.
        if unknowns:
            lines.append("box-check: nothing wrong that I can measure. "
                         f"{len(unknowns)} thing(s) I could not check at all:")
            for _, head, _ in unknowns:
                lines.append(f"  - {head}")
        return "\n".join(lines)

    for sev, group in ((ALARM, alarms), (NOTE, notes), (UNKNOWN, unknowns)):
        if not group:
            continue
        if sev == ALARM:
            lines.append("THIS COSTS SOMETHING THE NEXT TIME IT MATTERS:")
        elif sev == NOTE:
            lines.append("\nTRUE AND WORTH SEEING:")
        else:
            lines.append("\nI COULD NOT CHECK THESE AT ALL — that is not a pass:")
        for _, head, detail in group:
            tag = {ALARM: "ALARM", NOTE: "NOTE ", UNKNOWN: "?    "}[sev]
            lines.append(f"  {tag}  {head}")
            for d in detail:
                lines.append(f"      {d}")
    return "\n".join(lines)


def main():
    verbose = "-v" in sys.argv or "--all" in sys.argv
    findings = collect(verbose)
    text = render(findings, verbose)
    if text:
        print(text)

    if "--notify" in sys.argv and [f for f in findings if f[0] == ALARM]:
        prefix = ""
        if os.environ.get("BOX_CHECK_TEST"):
            prefix = "[TEST] "
        elif not os.environ.get("INVOCATION_ID"):
            prefix = "[MANUAL] "
        notify = os.environ.get("NOTIFY", os.path.expanduser("~/bin/ragnarok-notify"))
        if os.access(notify, os.X_OK):
            import base64
            msg = prefix + "box-check @alexus:\n" + text
            env = dict(os.environ, RAGNAROK_LANE=os.environ.get("RAGNAROK_LANE", "system"))
            subprocess.run([notify, "--b64", base64.b64encode(msg.encode()).decode()],
                           capture_output=True, env=env)
    # Exit 0 always: a checker that can fail is a checker that gets disabled.
    return 0


if __name__ == "__main__":
    sys.exit(main())
