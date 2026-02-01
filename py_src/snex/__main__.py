from __future__ import annotations

import asyncio
import io
import sys

from . import runner

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, line_buffering=True, newline="\r\n")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, line_buffering=True, newline="\r\n")

asyncio.run(runner.run_loop())
