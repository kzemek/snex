defmodule Snex.Internal.OSMonotonic do
  @moduledoc false
  @on_load :init

  @type timestamp() :: non_neg_integer()
  @type portable_timestamp() :: {node(), timestamp(), non_neg_integer()}

  defp init do
    :persistent_term.put(
      {__MODULE__, :perf_counter_is_monotonic?},
      check_if_perf_counter_is_monotonic()
    )

    :persistent_term.put(
      {__MODULE__, :beam_monotonic_time_offset},
      measure_beam_monotonic_time_offset()
    )

    :ok
  end

  defp check_if_perf_counter_is_monotonic do
    perf_ts = :os.perf_counter()
    monotonic_ts = :erlang.system_info(:os_monotonic_time_source)[:time]
    delta = :erlang.convert_time_unit(5, :millisecond, :native)

    perf_ts >= monotonic_ts - delta and perf_ts <= monotonic_ts + delta
  end

  defp measure_beam_monotonic_time_offset do
    measurements =
      for _ <- 1..1000,
          monotonic1 = time(),
          beam_monotonic = System.monotonic_time(),
          monotonic2 = time(),
          diff <- [beam_monotonic - monotonic1, beam_monotonic - monotonic2],
          do: diff

    # Almost-median value
    measurements |> Enum.sort() |> Enum.at(1000)
  end

  @spec time() :: timestamp()
  def time do
    # Most of the time, :os.perf_counter() will be equal but ~15x faster than
    # `:erlang.system_info(:os_monotonic_time_source)[:time]`.
    # Checking `persistent_term` first is still 14x faster, and almost 2x faster than
    # System.monotonic_time().
    # `System.monotonic_time/0` doesn't cut it, as we want the same monotonic value as the one
    # returned by Python's `time.monotonic()`.
    if :persistent_term.get({__MODULE__, :perf_counter_is_monotonic?}),
      do: :os.perf_counter(),
      else: :erlang.system_info(:os_monotonic_time_source)[:time]
  end

  # estimated offset between BEAM monotonic time and OS monotonic time
  defp beam_monotonic_time_offset,
    do: :persistent_term.get({__MODULE__, :beam_monotonic_time_offset})

  @spec from_system_time(non_neg_integer()) :: timestamp()
  def from_system_time(timestamp),
    do: timestamp - System.time_offset() - beam_monotonic_time_offset()

  @spec to_beam_monotonic_time(timestamp()) :: integer()
  def to_beam_monotonic_time(timestamp),
    do: timestamp + beam_monotonic_time_offset()

  @spec to_system_time(timestamp()) :: non_neg_integer()
  def to_system_time(timestamp),
    do: timestamp + beam_monotonic_time_offset() + System.time_offset()

  @spec to_portable_time(timestamp()) :: portable_timestamp()
  def to_portable_time(timestamp),
    do: {node(), timestamp, to_system_time(timestamp)}

  @spec from_portable_time(portable_timestamp()) :: timestamp()
  def from_portable_time({node, timestamp, system_time}) do
    if node == node(),
      do: timestamp,
      else: from_system_time(system_time)
  end
end
