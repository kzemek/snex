defmodule Snex.TelemetryTest do
  use ExUnit.Case, async: true

  alias Snex.Internal.OSMonotonic

  @time_delta System.convert_time_unit(5, :millisecond, :native)

  setup ctx do
    :telemetry.attach_many(
      {ctx.module, ctx.test},
      [[:snex, :interpreter, :command, :start], [:snex, :interpreter, :command, :stop]],
      &__MODULE__.send_telemetry_event/4,
      %{self: self()}
    )

    on_exit(fn ->
      :telemetry.detach({ctx.module, ctx.test})
    end)

    :ok
  end

  test "telemetry events timestamp ordering" do
    {:ok, interpreter} = Snex.Interpreter.start_link(label: :eval_test)
    {:ok, env} = Snex.make_env(interpreter)
    {:ok, 20} = Snex.pyeval(env, "x = 10", returning: "x * 2")

    [:init, :make_env, :eval]
    |> Enum.flat_map(&[{&1, :start}, {&1, :stop}])
    |> Enum.map(fn {command, event_type} ->
      assert_receive {:telemetry_event, [:snex, :interpreter, :command, ^event_type],
                      measurements, %{command_name: ^command}}

      {{command, event_type}, measurements.monotonic_time}
    end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{key1, monotonic_time1}, {key2, monotonic_time2}] ->
      assert monotonic_time1 < monotonic_time2,
             "event #{inspect(key1)} should be before event #{inspect(key2)}"
    end)
  end

  test "emits telemetry events for commands" do
    before_start_link_timestamp = timestamp()
    {:ok, interpreter} = Snex.Interpreter.start_link(label: :eval_test)

    before_make_env_timestamp = timestamp()
    {:ok, env} = Snex.make_env(interpreter)

    before_pyeval_timestamp = timestamp()
    {:ok, 20} = Snex.pyeval(env, "x = 10", returning: "x * 2")

    after_pyeval_timestamp = timestamp()

    Enum.each(
      [
        init: {before_start_link_timestamp, before_make_env_timestamp},
        make_env: {before_make_env_timestamp, before_pyeval_timestamp},
        eval: {before_pyeval_timestamp, after_pyeval_timestamp}
      ],
      fn {command, {before_timestamp, after_timestamp}} ->
        max_duration = after_timestamp.os_monotonic - before_timestamp.os_monotonic

        # Start event
        assert_receive {:telemetry_event, [:snex, :interpreter, :command, :start],
                        start_measurements,
                        %{
                          command_name: ^command,
                          interpreter_label: :eval_test,
                          telemetry_span_context: span_context
                        }}

        assert_in_delta start_measurements.monotonic_time,
                        before_timestamp.beam_monotonic,
                        @time_delta

        assert_in_delta start_measurements.system_time,
                        before_timestamp.system_time,
                        @time_delta

        # Stop event
        assert_receive {:telemetry_event, [:snex, :interpreter, :command, :stop],
                        stop_measurements,
                        %{
                          telemetry_span_context: ^span_context,
                          interpreter_label: :eval_test,
                          command_name: ^command
                        }}

        assert_in_delta stop_measurements.monotonic_time,
                        after_timestamp.beam_monotonic,
                        @time_delta

        assert_in_delta stop_measurements.system_time,
                        after_timestamp.system_time,
                        @time_delta

        assert stop_measurements.duration in 0..max_duration

        total_duration =
          stop_measurements
          |> Map.drop([:duration, :system_time, :monotonic_time])
          |> Enum.reduce(0, fn {key, value}, acc ->
            assert value in 0..max_duration,
                   "value #{value} for key #{key} is not in 0..#{max_duration}"

            acc + value
          end)

        assert total_duration == stop_measurements.duration
      end
    )
  end

  test "interpreter label defaults to nil when not provided" do
    {:ok, _interpreter} = Snex.Interpreter.start_link()

    assert_receive {:telemetry_event, [:snex, :interpreter, :command, :start], _,
                    %{interpreter_label: nil}}
  end

  @spec send_telemetry_event(any(), any(), any(), any()) :: any()
  def send_telemetry_event(event_name, event_measurements, event_metadata, handler_config) do
    send(handler_config.self, {:telemetry_event, event_name, event_measurements, event_metadata})
  end

  defp timestamp do
    %{
      os_monotonic: OSMonotonic.time(),
      system_time: System.system_time(),
      beam_monotonic: System.monotonic_time()
    }
  end
end
