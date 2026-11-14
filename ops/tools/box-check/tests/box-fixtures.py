#!/usr/bin/env python3
"""
box-fixtures.py — the suite for box-check.

NAMED IN ~/CLAUDE.md, per the rule the prose-drift bullet carries: "A test suite
nothing runs is the same write-only failure as a log nothing reads — so if you
add one, name it in this sentence." macbook-fixtures.sh failed 6 of 9 for four
days with nothing saying so, because it was named nowhere.

HERMETIC. Every check in check.py is a pure function over parsed machine state,
so this feeds it whole fictional machines and never reads the real box. Its
result does not change when a disk is unplugged.

THE NEGATIVE CONTROLS ARE THE POINT — cases 4, 6, 7, 11, 12, 17, 18 force back the
exact false alarms this checker shipped and had to be calibrated out of on
2026-09-08:
  - case 4: the ROOT FILESYSTEM reported as "device does not exist", because a
    dm-uuid spec would not resolve. The loudest possible false alarm.
  - cases 6-7: a nofail disk unplugged on purpose reported as a missing
    device. An alarm that fires daily for a deliberate act mutes the channel.
  - case 18: /mnt/nvme, /mnt/coldarchive, "/mnt/newdri" (a path truncated in
    prose) all reported as boot hazards, because the scan read documents.
An alarm channel that reaches a phone earns stricter controls than a report.

Run: python3 tests/box-fixtures.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("boxcheck", os.path.join(HERE, "..", "check.py"))
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)

npass = nfail = 0
def ok(m):
    global npass; npass += 1; print(f"  ok   {m}")
def bad(m):
    global nfail; nfail += 1; print(f"  FAIL {m}")
def check(m, want, got):
    ok(m) if want == got else bad(f"{m} (want {want!r}, got {got!r})")

def sevs(findings):
    return [f[0] for f in findings]
def heads(findings):
    return " | ".join(f[1] for f in findings)


# A fictional machine: one system disk, two USB disks.
BLOCKS = [
    {"name": "sda", "size": "931.5G", "type": "disk", "children": [
        {"name": "sda1", "size": "1G", "fstype": "vfat", "mountpoint": "/boot/efi",
         "uuid": "EFI-1", "type": "part"},
        {"name": "sda3", "size": "928G", "fstype": "LVM2_member", "mountpoint": None,
         "uuid": "LVM-1", "type": "part"},
    ]},
    {"name": "sdb1", "size": "931.5G", "fstype": "ntfs", "mountpoint": "/mnt/drive",
     "label": "New Volume", "uuid": "NTFS-1", "type": "part"},
    {"name": "sdc2", "size": "1.8T", "fstype": "ext4", "mountpoint": "/mnt/newdrive",
     "label": "RAGNAROK-BACKUP", "uuid": "EXT-1", "type": "part"},
    {"name": "sdc1", "size": "32G", "fstype": "vfat", "mountpoint": None,
     "label": "ESD-USB", "uuid": "VFAT-9", "type": "part"},
]
MOUNTS = ("/dev/sdb1 /mnt/drive fuseblk rw 0 0\n"
          "/dev/sdc2 /mnt/newdrive ext4 rw 0 0\n"
          "/dev/sda1 /boot/efi vfat rw 0 0\n")

CROSSED = ("UUID=EXT-1 /mnt/drive ext4 defaults,nofail 0 2\n"
           "UUID=NTFS-1 /mnt/e300 ntfs-3g defaults,nofail 0 0\n")
MATCHING = ("UUID=NTFS-1 /mnt/drive ntfs-3g defaults,nofail 0 0\n"
            "UUID=EXT-1 /mnt/newdrive ext4 defaults,nofail 0 2\n")

print("-- 1-3: the crossed fstab that was live on this box today")
f = C.check_fstab_vs_reality(CROSSED, MOUNTS, BLOCKS)
check("both crossed drives fire", 2, sum(1 for s, h, _ in f if "DISAGREE" in h))
check("...and they are ALARMs", True, all(s == C.ALARM for s, h, _ in f if "DISAGREE" in h))
check("the hand-mounted path with no fstab entry fires", True,
      any("NOTHING in fstab brings it back" in h for _, h, _ in f))

print("-- 4 NEGATIVE CONTROL: an unresolvable spec on a WORKING mount is unknown,")
print("   not 'the device does not exist'. This fired on / and is the loudest")
print("   thing this checker could possibly get wrong.")
f = C.check_fstab_vs_reality(
    "/dev/disk/by-id/dm-uuid-LVM-deadbeef / ext4 defaults 0 1\n",
    "/dev/mapper/vg-lv / ext4 rw 0 0\n", BLOCKS)
check("unresolvable + mounted -> UNKNOWN", [C.UNKNOWN], sevs(f))

print("-- 5: an fstab device that genuinely does not exist IS an alarm")
print("   (no nofail: the boot really does depend on a disk that is gone)")
f = C.check_fstab_vs_reality("UUID=GONE-9 /mnt/gone ext4 defaults 0 2\n", "", BLOCKS)
check("missing device, no nofail -> ALARM", [C.ALARM], sevs(f))

print("-- 6-7 NEGATIVE CONTROL: the SAME missing disk, declared nofail, is a")
print("   NOTE. The Lexar was unplugged on purpose on 2026-09-08 and this")
print("   alarmed to the owner's phone daily for a thing they did deliberately.")
f = C.check_fstab_vs_reality("UUID=GONE-9 /mnt/gone ext4 defaults,nofail 0 2\n", "", BLOCKS)
check("missing device + nofail -> NOTE", [C.NOTE], sevs(f))
check("...and it does not say 'does not exist'", False, "does not exist" in heads(f))

print("-- 8-9 NEGATIVE CONTROLS: an unreadable source is never clean")
check("no fstab -> UNKNOWN", [C.UNKNOWN], sevs(C.check_fstab_vs_reality(None, MOUNTS, BLOCKS)))
check("no lsblk -> UNKNOWN", [C.UNKNOWN], sevs(C.check_fstab_vs_reality(CROSSED, MOUNTS, None)))

print("-- 10: a matching fstab is SILENT (this is what a fixed box looks like)")
check("no findings", [], sevs(C.check_fstab_vs_reality(MATCHING, MOUNTS, BLOCKS)))

print("-- 11-13: unclaimed devices, and the two things that are NOT one")
f = C.check_unclaimed_devices(BLOCKS, MATCHING)
check("the unmounted, undeclared vfat stick is reported", True, "sdc1" in heads(f))
check("NEGATIVE: an LVM2_member is not 'unclaimed'", False, "sda3" in heads(f))
check("NEGATIVE: a mounted device is not 'unclaimed'", False, "sdb1" in heads(f))

print("-- 14-16: fullness -- the finding is the PAIR, not the percentage")
DF_FULL = ("Filesystem 1K-blocks Used Available Capacity Mounted on\n"
           "/dev/mapper/vg-lv 102400000 86000000 16000000 84% /\n")
DF_OK = ("Filesystem 1K-blocks Used Available Capacity Mounted on\n"
         "/dev/mapper/vg-lv 102400000 20000000 82400000 20% /\n")
VG = f"ubuntu-vg {928*1024**3} {828*1024**3}\n"
f = C.check_headroom(DF_FULL, VG)
check("84% + 828 GB unallocated -> ALARM naming lvextend", True,
      f[0][0] == C.ALARM and any("lvextend" in d for d in f[0][2]))
check("NEGATIVE: a 20% filesystem says nothing", [], sevs(C.check_headroom(DF_OK, VG)))
check("full but VG unreadable -> UNKNOWN, never clean", [C.UNKNOWN], sevs(C.check_headroom(DF_FULL, None)))

print("-- 17-19: write destinations that do not survive a reboot")
f = C.check_write_destinations({"/mnt/newdrive/claude-transcripts": 3}, CROSSED, MOUNTS)
check("mounted + used + absent from fstab -> ALARM", [C.ALARM], sevs(f))
check("NEGATIVE: the same path, once fstab restores it, is silent",
      [], sevs(C.check_write_destinations({"/mnt/newdrive/x": 3}, MATCHING, MOUNTS)))
print("   (case 19 forces back the /mnt/nvme and '/mnt/newdri' noise --")
print("    a path named in code but never mounted is history, not a hazard)")
check("NEGATIVE: named but never mounted is SILENT by default",
      [], sevs(C.check_write_destinations({"/mnt/nvme/old": 9}, MATCHING, MOUNTS)))
check("...and under -v it is a NOTE, never an ALARM",
      [C.NOTE], sevs(C.check_write_destinations({"/mnt/nvme/old": 9}, MATCHING, MOUNTS, True)))

print("-- 20: could not scan -> UNKNOWN")
check("refs unreadable -> UNKNOWN", [C.UNKNOWN], sevs(C.check_write_destinations(None, CROSSED, MOUNTS)))

print("-- 21: the capability that cannot be probed read-only stays visible")
check("airtable schema-write is permanently UNKNOWN", [C.UNKNOWN], sevs(C.check_airtable_capability()))

print("-- 22-23: the report. Silent when clean -- but never silent about unknowns.")
out = C.render([(C.NOTE, "a note", [])])
check("a lone NOTE prints nothing", "", out)
out = C.render([(C.UNKNOWN, "could not look at the disks", [])])
check("an UNKNOWN prints even with zero alarms", True, "could not check at all" in out.lower()
      or "could not look at the disks" in out)

print("-- 24: an ALARM leads the report")
out = C.render([(C.NOTE, "a note", []), (C.ALARM, "the real thing", [])])
check("alarms come first", True, out.splitlines()[0].startswith("THIS COSTS SOMETHING"))

EXPECTED = 25
ran = npass + nfail
if ran != EXPECTED:
    nfail += 1
    print(f"  FAIL {ran} assertions ran, {EXPECTED} expected — one was skipped")
print(f"box-fixtures.py: {npass} passed, {nfail} failed ({ran}/{EXPECTED} assertions ran)")
sys.exit(0 if nfail == 0 else 1)
