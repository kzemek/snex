defmodule Snex.TelemetryTest do
  use ExUnit.Case, async: false

  alias Snex.Internal.OSMonotonic

  @time_delta System.convert_time_unit(1, :millisecond, :native)

  @all_events [
    [:snex, :interpreter, :init, :start],
    [:snex, :interpreter, :init, :stop],
    [:snex, :make_env, :start],
    [:snex, :make_env, :stop],
    [:snex, :pyeval, :start],
    [:snex, :pyeval, :stop]
  ]

  setup ctx do
    :telemetry.attach_many(
      {ctx.module, ctx.test},
      @all_events,
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

    @all_events
    |> Enum.map(fn event ->
      assert_receive {:telemetry_event, ^event, measurements, _metadata}
      {event, measurements.monotonic_time}
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

    before_make_env_timestamp = timestamp() |> dbg()
    {:ok, env} = Snex.make_env(interpreter)

    before_pyeval_timestamp = timestamp()
    {:ok, 20} = Snex.pyeval(env, "x = 10", returning: "x * 2")

    after_pyeval_timestamp = timestamp()

    Enum.each(
      [
        {[:snex, :interpreter, :init], {before_start_link_timestamp, before_make_env_timestamp}},
        {[:snex, :make_env], {before_make_env_timestamp, before_pyeval_timestamp}},
        {[:snex, :pyeval], {before_pyeval_timestamp, after_pyeval_timestamp}}
      ],
      fn {event_prefix, {before_timestamp, after_timestamp}} ->
        dbg(event_prefix)
        max_duration = after_timestamp.os_monotonic - before_timestamp.os_monotonic

        stop_event = event_prefix ++ [:stop]
        start_event = event_prefix ++ [:start]

        # Start event
        assert_receive {:telemetry_event, ^start_event, start_measurements,
                        %{telemetry_span_context: span_context}}

        assert start_measurements.monotonic_time in before_timestamp.beam_monotonic..after_timestamp.beam_monotonic

        assert start_measurements.system_time in before_timestamp.system_time..after_timestamp.system_time

        # Stop event
        assert_receive {:telemetry_event, ^stop_event, stop_measurements,
                        %{telemetry_span_context: ^span_context, interpreter_label: :eval_test}}

        assert stop_measurements.monotonic_time in before_timestamp.beam_monotonic..after_timestamp.beam_monotonic

        assert stop_measurements.duration in 0..max_duration

        total_measurements_duration =
          stop_measurements
          |> Map.drop([:duration, :system_time, :monotonic_time])
          |> Enum.reduce(0, fn {key, value}, acc ->
            assert value in 0..max_duration,
                   "value #{value} for key #{key} is not in 0..#{max_duration}"

            acc + value
          end)

        assert_in_delta total_measurements_duration, stop_measurements.duration, @time_delta
      end
    )
  end

  test "interpreter label defaults to nil when not provided" do
    {:ok, _interpreter} = Snex.Interpreter.start_link()

    assert_receive {:telemetry_event, [:snex, :interpreter, :init, :start], _,
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
