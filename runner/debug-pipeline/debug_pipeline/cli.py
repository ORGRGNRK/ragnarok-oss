"""Command line for the debug pipeline."""
import argparse
import os
import sys

from debug_pipeline.pipeline import run
from debug_pipeline.receipt import verify
from debug_pipeline.workers import ModelWorker, sample_worker

HELP = """debug-pipeline run --ticket TICKET --source FOLDER --test "command"
debug-pipeline verify RECEIPT.jsonl
debug-pipeline selfcheck

The ticket is 6 characters. The test must fail before any fix.
Results are only OK, FAILED, or NOT VERIFIED.
--runner docker is the default. It does not fall back to fake.
Use --runner fake when Docker is not running. That runs the sample in a temp folder.
Use --worker fake for the sample bug. No model is called.
Use --worker model --model NAME to ask a model for one validated file edit.
Customer secrets are scrubbed before a worker, the receipt, or the archive text.
"""


def _run(args):
    if args.worker == "fake":
        worker = sample_worker
    elif args.worker == "model":
        model = args.model or os.environ.get("DEBUG_PIPELINE_MODEL", "")
        if not model:
            print("an explicit model is required", file=sys.stderr)
            return 2
        worker = ModelWorker(model, endpoint=args.endpoint or None)
    else:
        worker = None
    try:
        result = run(
            args.ticket, args.source, args.test, args.out, args.store,
            runner_name=args.runner, worker=worker, rounds=args.rounds,
            keep_secrets=args.keep_secrets, network=args.network, image=args.image,
        )
    except (ValueError, OSError) as err:
        print(str(err), file=sys.stderr)
        return 2
    print(f"result {result['result']}")
    print(f"runner {result['runner']}")
    if result["archive"] is not None:
        print(f"archive {result['archive']}")
        print(f"sha256 {result['sha256']}")
        print(f"head {result['head_hash']}")
    if result["ticket_record"] is not None:
        print(f"ticket {result['ticket_record']}")
    if result["result"] == "OK":
        return 0
    if result["result"] == "FAILED":
        return 1
    return 2


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(HELP)
        return 0
    if argv[0] == "selfcheck":
        from debug_pipeline.selfcheck import main as selfcheck_main
        return selfcheck_main(argv[1:])
    if argv[0] == "verify":
        if len(argv) != 2:
            print("usage: debug-pipeline verify RECEIPT.jsonl", file=sys.stderr)
            return 2
        ok, msg = verify(argv[1])
        print(msg)
        return 0 if ok else 1
    parser = argparse.ArgumentParser(prog="debug-pipeline")
    sub = parser.add_subparsers(dest="cmd", required=True)
    run_p = sub.add_parser("run")
    run_p.add_argument("--ticket", required=True)
    run_p.add_argument("--source", required=True)
    run_p.add_argument("--test", required=True)
    run_p.add_argument("--runner", choices=("docker", "fake"), default="docker")
    run_p.add_argument("--worker", choices=("fake", "none", "model"), default="none")
    run_p.add_argument("--model", default="")
    run_p.add_argument("--endpoint", default="")
    run_p.add_argument("--store", required=True)
    run_p.add_argument("--out", required=True)
    run_p.add_argument("--rounds", type=int, default=4)
    run_p.add_argument("--network", action="store_true")
    run_p.add_argument("--keep-secrets", action="store_true")
    run_p.add_argument("--image", default="python:3.12-slim")
    sub.add_parser("verify")
    args = parser.parse_args(argv)
    if args.cmd == "run":
        return _run(args)
    print(HELP, file=sys.stderr)
    return 2
