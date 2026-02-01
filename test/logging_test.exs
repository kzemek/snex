defmodule SnexLoggingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Snex.Sigils

  setup_all do
    inp =
      start_link_supervised!(
        {SnexTest.NumpyInterpreter,
         init_script: ~P"""
         import logging
         import snex
         logger = logging.getLogger(__name__)
         logger.setLevel(logging.DEBUG)
         logger.addHandler(snex.LoggingHandler())
         """}
      )

    %{inp: inp}
  end

  describe "LoggingHandler" do
    for level <- [:debug, :info, :warning, :error, :critical] do
      test "logs #{level} message from Python", %{inp: inp} do
        log =
          capture_log(fn ->
            {:ok, _} =
              Snex.pyeval(inp, ~p"""
              logger.#{unquote(level)}("hello from Python")
              """)

            Process.sleep(5)
          end)

        assert log =~ "[#{unquote(level)}] hello from Python"
      end
    end

    test "includes python metadata in log output", %{inp: inp} do
      {{thread_name, thread_id, pid}, log} =
        with_log(fn ->
          {:ok, result} =
            Snex.pyeval(inp, ~P"""
            import threading
            import os

            logger.info("metadata test")

            t = threading.current_thread()
            return (t.name, t.ident, os.getpid())
            """)

          Process.sleep(5)
          result
        end)

      assert log =~ "python_module=logging_test"
      assert log =~ "python_function=<module>"
      assert log =~ "python_log_level=INFO"
      assert log =~ "python_thread_name=#{thread_name}"
      assert log =~ "python_thread_id=#{thread_id}"
      assert log =~ "python_process_id=#{pid}"
    end

    test "includes default_metadata in log output", %{inp: inp} do
      log =
        capture_log(fn ->
          {:ok, _} =
            Snex.pyeval(inp, ~P"""
            test_logger = logging.getLogger("test_default_meta")
            test_logger.addHandler(snex.LoggingHandler(
              default_metadata={"application": "my_test_app"}
            ))
            test_logger.setLevel(logging.DEBUG)
            test_logger.info("with default metadata")
            """)

          Process.sleep(5)
        end)

      assert log =~ "with default metadata"
      assert log =~ "application=my_test_app"
      assert log =~ "domain=elixir.snex"
    end

    test "includes extra_metadata_keys in log output", %{inp: inp} do
      log =
        capture_log(fn ->
          {:ok, _} =
            Snex.pyeval(inp, ~P"""
            test_logger = logging.getLogger("test_extra_keys")
            test_logger.addHandler(snex.LoggingHandler(
              extra_metadata_keys={"extra_1"}
            ))
            test_logger.setLevel(logging.DEBUG)
            test_logger.info("with extra keys", extra={"extra_1": "extra_value"})
            """)

          Process.sleep(5)
        end)

      assert log =~ "with extra keys"
      assert log =~ "extra_1=extra_value"
    end

    test "includes file and line metadata", %{inp: inp} do
      log =
        capture_log(fn ->
          {:ok, _} =
            Snex.pyeval(inp, ~P"""
            logger.info("location test")
            """)

          Process.sleep(5)
        end)

      assert log =~ "file=#{__ENV__.file}"
      assert log =~ "line=#{__ENV__.line - 7}"
    end
  end
end
