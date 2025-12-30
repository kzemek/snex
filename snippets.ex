defmodule RelocatableTest.Interpreter do
  use Snex.Interpreter,
    pyproject_toml: """
    [project]
    name = "python-files"
    version = "0.1.0"
    description = "Add your description here"
    readme = "README.md"
    requires-python = ">=3.10"
    dependencies = [
    "dill",
    "numpy",
    ]
    """
end

{:ok, interpreter} = RelocatableTest.Interpreter.start_link([])
{:ok, env} = Snex.make_env(interpreter)
{:ok, result} = Snex.pyeval(env, returning: "1 + 2")

pycode = """
  import os
  import resource
  import sys
  import numpy as np
  
  # Set address space limit to 195 MB
  limit_mb = 195
  limit_bytes = limit_mb * 1024 * 1024
  resource.setrlimit(resource.RLIMIT_AS, (limit_bytes, limit_bytes))
  
  print(f"PID {os.getpid()}: set RLIMIT_AS to {limit_mb} MB", file=sys.stderr)
  
  # Now try to allocate 200 MB - this should fail
  # try:
  #     target_mb = 200
  #     arr = np.zeros(target_mb * 1024 * 1024, dtype=np.uint8)
  #     print(f"Allocated {arr.nbytes / 1024**2:.0f} MB", file=sys.stderr)
  # except MemoryError as e:
  #     print(f"MemoryError: Cannot allocate 200 MB with {limit_mb} MB limit", file=sys.stderr)
  target_mb = 200
  arr = np.zeros(target_mb * 1024 * 1024, dtype=np.uint8)
  print(f"Allocated {arr.nbytes / 1024**2:.0f} MB", file=sys.stderr)
  """

{:ok, result} = Snex.pyeval(env, pycode)

:erlang.apply(:os, :cmd, [~c"ps -eo pid,rss,comm | grep python | sort -k2 -rn"]) |> IO.puts()

:os.cmd(~c"cat /opt/app/lib/snex-0.2.0/priv/py_src/snex/runner.py") |> IO.puts
