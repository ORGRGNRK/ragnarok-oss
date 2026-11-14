#!/usr/bin/env python3
"""
Stream deduplicated archives from MacBook (~/Desktop/Alexus.) and Seagate ext4 (/dev/disk12s2)
directly to Google Drive (gdrive:RAGNAROK-Archive/) using zero local temporary disk space.
"""
import json
import os
import re
import subprocess
import sys
import time

RCLONE = "/opt/homebrew/bin/rclone"
DEBUGFS = "/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
DEV = "/dev/disk12s2"
LOG_FILE = "/tmp/gdrive-archive-sync.log"

# Canonical Seagate paths to sync (skips duplicate copies inside from-lexar-2026-10-14,
# skips KEYS AND SHIT, 1Password Emergency Kit.pdf, and SecretWaifu).
SEAGATE_TARGETS = [
    "freeze-2026-09-12",
    "ygg-exports",
    "2026-09-08",
    "ygg-cold-storage-2026-08-25-hel-alexus-identity",
    "ygg-cold-storage-2026-09-01-code-narratives",
    "ragnarok",
    "claude-transcripts",
    "postgres-nocodb-receipted-2026-10-27",
    "postgres-nocodb-receipted-clean-2026-10-27",
    "ragnarok-repair-shop-2026-10-27",
    "7-27-2026 (Freeze)",
    "restic-canon",
    "from-lexar-2026-10-14/alexus-pet-package.zip",
    "from-lexar-2026-10-14/OLVANTI-AND-IRIDESCENT.txt",
    "from-lexar-2026-10-14/New Text Document.txt",
    "from-lexar-2026-10-14/_VERIFY",
    "from-lexar-2026-10-14/ARK",
    "alexus-image",
]

SKIP_NAMES = {".", "..", "lost+found", "KEYS AND SHIT", "1Password Emergency Kit.pdf", ".DS_Store"}


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)


def debugfs_ls(rel_path: str):
    """Return list of (name, is_dir, size_bytes) inside rel_path on /dev/disk12s2."""
    cmd = f'ls -l "{rel_path}"'
    p = subprocess.run([DEBUGFS, "-c", "-R", cmd, DEV], capture_output=True, text=True)
    items = []
    for raw in p.stdout.splitlines():
        # Format: <inode> <octal_mode> (<type>) <uid> <gid> <size> <date> <time> <name>
        m = re.match(r"^\s*\d+\s+([0-7]+)\s+\(\d+\)\s+\d+\s+\d+\s+(\d+)\s+\S+\s+\S+\s+(.*)$", raw)
        if not m:
            continue
        mode_oct, size_s, name = m.group(1), m.group(2), m.group(3).strip()
        if name in SKIP_NAMES or "SecretWaifu" in name or "Emergency Kit" in name:
            continue
        is_dir = mode_oct.startswith("40")
        is_reg = mode_oct.startswith("100")
        if is_dir or is_reg:
            items.append((name, is_dir, int(size_s)))
    return items


def debugfs_stat(rel_path: str):
    """Check if rel_path itself is a regular file or directory."""
    parent = os.path.dirname(rel_path)
    base = os.path.basename(rel_path)
    for name, is_dir, sz in debugfs_ls(parent if parent else "."):
        if name == base:
            return is_dir, sz
    return None, 0


def get_remote_sizes(remote_dir: str) -> dict[str, int]:
    """Return {rel_path: size} already present under remote_dir on gdrive."""
    p = subprocess.run([RCLONE, "lsjson", "-R", "--files-only", remote_dir], capture_output=True, text=True)
    if p.returncode != 0:
        return {}
    try:
        data = json.loads(p.stdout)
        return {item["Path"]: int(item.get("Size", -1)) for item in data}
    except Exception:
        return {}


def stream_file_to_gdrive(rel_path: str, size_bytes: int, existing: dict[str, int]):
    if existing.get(rel_path) == size_bytes:
        log(f"SKIP (already in gdrive, {size_bytes} B): {rel_path}")
        return
    dest = f"gdrive:RAGNAROK-Archive/Seagate-Backup/{rel_path}"
    log(f"UPLOADING ({size_bytes / (1024*1024):.2f} MB): {rel_path} -> {dest}")
    dump_cmd = f'dump "{rel_path}" /dev/stdout'
    p1 = subprocess.Popen([DEBUGFS, "-c", "-R", dump_cmd, DEV], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen([RCLONE, "rcat", dest], stdin=p1.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert p1.stdout is not None
    p1.stdout.close()
    _, err = p2.communicate()
    p1.wait()
    if p2.returncode == 0:
        log(f"DONE: {rel_path}")
        existing[rel_path] = size_bytes
    else:
        log(f"ERROR uploading {rel_path}: {err.strip()}")


def walk_and_stream(rel_path: str, existing: dict[str, int]):
    is_dir, sz = debugfs_stat(rel_path)
    if is_dir is None:
        log(f"WARN: not found on Seagate: {rel_path}")
        return
    if not is_dir:
        stream_file_to_gdrive(rel_path, sz, existing)
        return
    for name, child_is_dir, child_sz in debugfs_ls(rel_path):
        child_path = f"{rel_path}/{name}"
        if child_is_dir:
            walk_and_stream(child_path, existing)
        else:
            stream_file_to_gdrive(child_path, child_sz, existing)


def main():
    log("=== Step 1: Syncing ~/Desktop/Alexus. -> gdrive:RAGNAROK-Archive/MacBook-Desktop-Alexus ===")
    alexus_desktop = os.path.expanduser("~/Desktop/Alexus.")
    if os.path.isdir(alexus_desktop):
        subprocess.run([
            RCLONE, "copy", alexus_desktop, "gdrive:RAGNAROK-Archive/MacBook-Desktop-Alexus",
            "--exclude", "5-Secrets-DO-NOT-SHARE/**",
            "--exclude", ".DS_Store",
            "--transfers", "4",
            "--stats", "30s",
            "--stats-one-line",
            "-v"
        ], check=False)
    log("=== Step 1 complete ===")

    log("=== Step 2: Streaming deduplicated Seagate ext4 folders -> gdrive:RAGNAROK-Archive/Seagate-Backup ===")
    existing = get_remote_sizes("gdrive:RAGNAROK-Archive/Seagate-Backup")
    log(f"Found {len(existing)} existing files in gdrive:RAGNAROK-Archive/Seagate-Backup")
    for target in SEAGATE_TARGETS:
        log(f"--- Processing Seagate target: {target} ---")
        walk_and_stream(target, existing)
    log("=== ALL TARGETS COMPLETE ===")


if __name__ == "__main__":
    main()
