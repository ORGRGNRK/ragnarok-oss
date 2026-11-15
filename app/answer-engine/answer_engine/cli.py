"""Command line: serve the local page, or run selfcheck."""

import sys

sys.dont_write_bytecode = True

USAGE = """usage: answer-engine serve [--port N]
       answer-engine selfcheck

serve listens on 127.0.0.1 only. The default port is 8734.
"""


def parse_port(args):
    port = 8734
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--port":
            index += 1
            if index >= len(args):
                raise ValueError("missing port")
            port = int(args[index])
        elif arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
        else:
            raise ValueError("unknown argument")
        index += 1
    if port < 0 or port > 65535:
        raise ValueError("bad port")
    return port


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        return 0 if argv else 2
    command = argv[0]
    if command == "selfcheck":
        if len(argv) != 1:
            sys.stderr.write(USAGE)
            return 2
        from answer_engine.selfcheck import main as run_selfcheck
        return run_selfcheck()
    if command == "serve":
        try:
            port = parse_port(argv[1:])
        except ValueError as exc:
            sys.stderr.write(str(exc) + "\n")
            return 2
        from answer_engine.server import serve
        return serve(port)
    sys.stderr.write(USAGE)
    return 2
