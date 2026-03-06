defmodule Snex.PyPyExampleTest do
  use ExUnit.Case, async: true

  test "run PyPy interpreter" do
    {_, 0} = System.cmd("uv", ~w[python install pypy-3.11], stderr_to_stdout: true)
    {pypy_path, 0} = System.cmd("uv", ~w[python find pypy-3.11])

    {:ok, interpreter} =
      Snex.Interpreter.start_link(
        python: String.trim(pypy_path),
        init_script: "import platform"
      )

    {:ok, env} = Snex.make_env(interpreter)
    {:ok, "PyPy"} = Snex.pyeval(env, "return platform.python_implementation()")
  end
end
