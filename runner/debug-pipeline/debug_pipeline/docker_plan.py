"""The Docker command, as data. Nothing here starts a daemon.

The live container gets no host home, no Docker socket, no host secrets, and
no network after the code is pulled unless the run asked for network.
The receipt file is a read-only mount. The host is the only writer.
"""
import os


def plan_create(name, image, receipt_file, network):
    return [
        "docker", "run", "-d", "--name", name,
        "--network", "bridge" if network else "none",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--pids-limit", "128",
        "--memory", "1g",
        "--cpus", "2",
        "--read-only",
        "--tmpfs", "/tmp:rw,nosuid,size=64m",
        "--tmpfs", "/work:rw,exec,nosuid,size=512m,uid=65534,gid=65534,mode=755",
        # Root-owned, so the customer user cannot change the frozen check.
        # Docker tmpfs is noexec unless exec is set, and the check is a script.
        "--tmpfs", "/validator:rw,exec,nosuid,size=32m,uid=0,gid=0,mode=755",
        "--mount", f"type=bind,source={receipt_file},target=/receipt/receipt.jsonl,readonly",
        "--user", "65534:65534",
        "-e", "HOME=/tmp",
        "-e", "PATH=/usr/local/bin:/usr/bin:/bin",
        "-e", "LANG=C.UTF-8",
        "-e", "PYTHONDONTWRITEBYTECODE=1",
        "-w", "/work",
        "--entrypoint", "sleep",
        image,
        "infinity",
    ]


def plan_disconnect(name):
    return ["docker", "network", "disconnect", "bridge", name]


def plan_exec(name, argv):
    return [
        "docker", "exec", "-i", "-u", "65534:65534",
        "-e", "HOME=/tmp",
        "-e", "PATH=/usr/local/bin:/usr/bin:/bin",
        "-e", "LANG=C.UTF-8",
        "-e", "PYTHONDONTWRITEBYTECODE=1",
        name,
        *argv,
    ]


def assert_safe(args):
    """Raise ValueError if the planned command could see the host home or the socket."""
    text = " ".join(args)
    if "docker.sock" in text:
        raise ValueError("docker socket must not be mounted")
    if "--privileged" in args:
        raise ValueError("privileged is refused")
    mounts = []
    for i, arg in enumerate(args):
        if arg in ("-v", "--volume"):
            raise ValueError("host volumes are refused")
        if arg == "--mount":
            mounts.append(args[i + 1])
    if len(mounts) != 1:
        raise ValueError("the only mount is the read-only receipt")
    mount = mounts[0]
    if "target=/receipt/receipt.jsonl,readonly" not in mount:
        raise ValueError("receipt mount must be read-only")
    source = mount.split("source=", 1)[1].split(",target=", 1)[0]
    home = os.path.expanduser("~").rstrip("/")
    banned = {home, "/Users", "/home", "/var/run/docker.sock"}
    if source.rstrip("/") in banned or "docker.sock" in source:
        raise ValueError("host home or docker socket must not be mounted")
    if "--cap-drop" not in args or args[args.index("--cap-drop") + 1] != "ALL":
        raise ValueError("capabilities must be dropped")
    if "no-new-privileges" not in text:
        raise ValueError("no-new-privileges is required")
    if "--user" not in args or args[args.index("--user") + 1] != "65534:65534":
        raise ValueError("container user must be nobody")
    return True
