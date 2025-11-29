defmodule Snex.Internal.Telemetry.CommandSpan do
  @moduledoc false

  alias Snex.Internal.OSMonotonic

  defstruct meta: %{}, timestamps: %{}

  @expected_timestamps [
    :start,
    :request_elixir_received,
    :request_sent_to_python,
    :response_received,
    :stop
  ]

  @type t :: %__MODULE__{
          meta: %{optional(atom()) => any()},
          timestamps: %{optional(atom()) => OSMonotonic.timestamp()}
        }

  @spec start_ts(GenServer.server()) :: {:wall | :os_monotonic, non_neg_integer()}
  def start_ts(interpreter) do
    interpreter_node =
      case GenServer.whereis(interpreter) do
        pid when is_pid(pid) -> node(pid)
        {_name, node} -> node
      end

    if interpreter_node == node(),
      do: {:os_monotonic, OSMonotonic.time()},
      else: {:wall, System.system_time()}
  end

  @spec timestamp_now(t(), atom()) :: t()
  def timestamp_now(%__MODULE__{} = span, key)
      when key in @expected_timestamps,
      do: timestamp(span, key, {:os_monotonic, OSMonotonic.time()})

  @spec timestamp(t(), atom(), {:wall | :os_monotonic, non_neg_integer()}) :: t()
  def timestamp(%__MODULE__{} = span, key, {:wall, wall_time})
      when key in @expected_timestamps,
      do: put_in(span.timestamps[key], OSMonotonic.from_system_time(wall_time))

  def timestamp(%__MODULE__{} = span, key, {:os_monotonic, monotonic_time})
      when key in @expected_timestamps,
      do: put_in(span.timestamps[key], monotonic_time)

  @spec meta(t(), atom(), any()) :: t()
  def meta(%__MODULE__{} = span, key, value),
    do: put_in(span.meta[key], value)

  @spec emit_start(t()) :: t()
  def emit_start(%__MODULE__{} = span) do
    :telemetry.execute(
      [:snex, :interpreter, :command, :start],
      %{
        monotonic_time: OSMonotonic.to_beam_monotonic_time(span.timestamps.start),
        system_time: OSMonotonic.to_system_time(span.timestamps.start)
      },
      span.meta
    )

    span
  end

  @spec emit_stop(t(), %{optional(atom()) => integer()}) :: :ok
  def emit_stop(%__MODULE__{} = span, python_timestamps) do
    :telemetry.execute(
      [:snex, :interpreter, :command, :stop],
      stop_measurements(span.timestamps, python_timestamps),
      span.meta
    )

    :ok
  end

  defp stop_measurements(ts, python_ts) do
    python_ts =
      Map.new(python_ts, fn {key, timestamp_ns} ->
        timestamp = System.convert_time_unit(timestamp_ns, :nanosecond, :native)
        {key, timestamp}
      end)

    durations =
      %{
        monotonic_time: OSMonotonic.to_beam_monotonic_time(ts.stop),
        system_time: OSMonotonic.to_system_time(ts.stop),
        duration: ts.stop - ts.start,
        request_elixir_queue_duration: ts.request_elixir_received - ts.start,
        request_encoding_duration: ts.request_sent_to_python - ts.request_elixir_received,
        response_decoding_duration: ts.stop - ts.response_received
      }

    python_extra_durations =
      case python_ts do
        %{
          "request_python_dequeued" => request_python_dequeued_ts,
          "request_decoded" => request_decoded_ts,
          "command_executed" => command_executed_ts
        } ->
          %{
            request_python_queue_duration: request_python_dequeued_ts - ts.request_sent_to_python,
            request_decoding_duration: request_decoded_ts - request_python_dequeued_ts,
            command_execution_duration: command_executed_ts - request_decoded_ts,
            response_encoding_and_queue_duration: ts.response_received - command_executed_ts
          }

        %{"request_python_dequeued" => request_python_dequeued_ts} ->
          %{request_python_queue_duration: request_python_dequeued_ts - ts.request_sent_to_python}

        _ ->
          %{}
      end

    Map.merge(durations, python_extra_durations)
  end
end
