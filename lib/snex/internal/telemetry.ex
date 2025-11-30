defmodule Snex.Internal.Telemetry do
  @moduledoc false

  alias Snex.Internal.OSMonotonic

  defmodule Result do
    @moduledoc false
    defstruct [:value, extra_measurements: %{}, stop_metadata: %{}]
  end

  @doc """
  Modified version of `:telemetry.span/3` to provide a more convenient API for Snex.

  The major differences are:

  - `with_span/3` is a macro and directly runs the block instead of wrapping it in a function call

  - timestamps are gathered with `m:OSMonotonic` module, and the gathered start timestamp is exposed
    to the calling code as `opts[:start_time_var]`

  - `start_meta` is always merged into stop metadata

  - instead of requiring the block to return `{result, stop_metadata}`, it can opt-in to return
    a `%Snex.Internal.Telemetry.Result{}` struct with telemetry extras. Otherwise, the value
    of the block is the value returned from `with_span/3`.
  """
  defmacro with_span(event_prefix, opts \\ [], do: block) do
    start_meta = Keyword.get(opts, :start_meta, quote(do: %{}))
    start_time_var = Keyword.get(opts, :start_time_var, quote(do: _))

    quote generated: true do
      unquote(start_time_var) = start_time = unquote(OSMonotonic).time()

      event_prefix = unquote(event_prefix)

      start_meta =
        Map.put_new_lazy(unquote(start_meta), :telemetry_span_context, fn -> make_ref() end)

      :telemetry.execute(
        event_prefix ++ [:start],
        %{
          monotonic_time: unquote(OSMonotonic).to_beam_monotonic_time(start_time),
          system_time: unquote(OSMonotonic).to_system_time(start_time)
        },
        start_meta
      )

      try do
        result =
          case unquote(block) do
            %unquote(Result){} = result -> result
            value -> %unquote(Result){value: value}
          end

        stop_time = unquote(OSMonotonic).time()

        :telemetry.execute(
          event_prefix ++ [:stop],
          Map.merge(result.extra_measurements, %{
            duration: stop_time - start_time,
            monotonic_time: unquote(OSMonotonic).to_beam_monotonic_time(stop_time)
          }),
          Map.merge(start_meta, result.stop_metadata)
        )

        result.value
      catch
        class, reason ->
          stop_time = OSMonotonic.time()

          :telemetry.execute(
            event_prefix ++ [:exception],
            %{
              duration: start_time - stop_time,
              monotonic_time: unquote(OSMonotonic).to_beam_monotonic_time(stop_time)
            },
            Map.merge(start_meta, %{kind: class, reason: reason, stacktrace: __STACKTRACE__})
          )

          :erlang.raise(class, reason, __STACKTRACE__)
      end
    end
  end
end
