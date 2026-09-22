#!/usr/bin/env python3
"""Bound registry/scanner tools, including downloads that ignore their own timeout."""

import argparse
import math
import os
import signal
import subprocess
import sys


class Interrupted(Exception):
    def __init__(self, number):
        self.number = number


def stop(process, grace):
    # This group was created exclusively for this invocation, never a daemon or
    # an existing shell. Also stop descendants when the tool ignores SIGTERM.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run(command, timeout, grace):
    process = subprocess.Popen(command, start_new_session=True)

    def interrupted(number, _frame):
        raise Interrupted(number)

    handlers = {number: signal.signal(number, interrupted) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            result = process.wait(timeout=timeout)
            return result if result >= 0 else 128 - result
        except subprocess.TimeoutExpired:
            result = 124
        except Interrupted as error:
            result = 128 + error.number
        # Finish owned-process cleanup even if the caller sends another signal.
        for number in handlers:
            signal.signal(number, signal.SIG_IGN)
        stop(process, grace)
        return result
    finally:
        for number, handler in handlers.items():
            signal.signal(number, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--kill-after", type=float, default=5)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if (not command or not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600
            or not math.isfinite(args.kill_after) or not 0 <= args.kill_after <= 30):
        parser.error("a command and finite, bounded time budgets are required")
    try:
        return run(command, args.timeout, args.kill_after)
    except OSError:
        # Do not copy tool arguments, image metadata or credentials to errors.
        print("[image-security] bounded tool could not execute", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
