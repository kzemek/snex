defmodule Snex.DockerExampleTest do
  use ExUnit.Case, async: true

  if System.find_executable("docker") == nil do
    @moduletag skip: "docker not found"
  end

  test "run interpreter inside docker container" do
    {:ok, interpreter} =
      SnexTest.MyProject.start_link(
        init_script: "import socket",
        wrap_exec: fn _python, args ->
          cwd = File.cwd!()

          # Port communication uses fds 3 and 4, but we can't passthrough them to Docker.
          # This example works around it by tunneling them through stdin/stdout.
          shell = """
          docker run \
            --rm -i --hostname=snex-test-container  \
            -v #{cwd}:/app -w /app \
            -e PYTHONPATH=$(echo $PYTHONPATH | sed 's|#{cwd}|/app|g') \
            python:3.11 \
            sh -c "exec 3<&0 4>&1; exec python #{Enum.join(args, " ")}" \
            <&3 >&4\
          """

          {"/bin/bash", ["-c", shell]}
        end
      )

    {:ok, env} = Snex.make_env(interpreter)
    {:ok, "snex-test-container"} = Snex.pyeval(env, "return socket.gethostname()")
  end
end
