defmodule Snex.MultiprocessingTest do
  use ExUnit.Case, async: true

  import Snex.Sigils

  setup do
    init_script = ~PY"""
    import asyncio
    import multiprocessing
    from concurrent.futures import ProcessPoolExecutor

    mp_ctx = multiprocessing.get_context('forkserver')
    process_task = ProcessPoolExecutor(mp_context=mp_ctx, max_workers=1)
    """

    interpreter = start_supervised!({SnexTest.MyProject, init_script: init_script})
    {:ok, env} = Snex.make_env(interpreter)
    %{env: env}
  end

  test "can run snex functions in a separate process", %{env: env} do
    os_pid = System.pid()

    {:ok, ^os_pid} =
      Snex.pyeval(
        env,
        ~PY"""
        from in_multiprocessing_process import do_something

        async with snex.subprocess_io_loop() as subprocess_comms:
          loop = asyncio.get_running_loop()
          return await loop.run_in_executor(
            process_task,
            do_something,
            self,
            subprocess_comms,
          )
        """,
        %{"self" => self()}
      )

    assert_receive "hello from the subprocess"
  end
end
