"""Serve rpyodide requests with CPython over stdin/stdout (no browser).

Each line on stdin is one JSON request, and each reply is one JSON line on
stdout. rpyodide uses this to test its R code and the Python bridge outside
webR, for example on CRAN.
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rpyodide_bridge  # noqa: E402


def main():
    protocol = sys.stdout
    sys.stdout = sys.stderr  # stray output must not corrupt the protocol
    loop = asyncio.new_event_loop()
    for line in sys.stdin:
        if line.strip():
            protocol.write(loop.run_until_complete(rpyodide_bridge.handle(line)) + "\n")
            protocol.flush()


main()
