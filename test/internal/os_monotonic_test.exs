defmodule Snex.Internal.OSMonotonicTest do
  use ExUnit.Case,
    async: true,
    parameterize: [%{perf_counter_is_monotonic?: true}, %{perf_counter_is_monotonic?: false}]

  alias Snex.Internal.OSMonotonic

  @delta System.convert_time_unit(1, :millisecond, :native)

  setup_all do
    Code.ensure_loaded!(OSMonotonic)
    :ok
  end

  setup ctx do
    orig = :persistent_term.get({OSMonotonic, :perf_counter_is_monotonic?})

    :persistent_term.put(
      {OSMonotonic, :perf_counter_is_monotonic?},
      ctx.perf_counter_is_monotonic?
    )

    on_exit(fn ->
      :persistent_term.put({OSMonotonic, :perf_counter_is_monotonic?}, orig)
    end)

    :ok
  end

  test "to_beam_monotonic_time/1" do
    now_os_monotonic = OSMonotonic.time()
    now_beam_monotonic = System.monotonic_time()

    assert_in_delta OSMonotonic.to_beam_monotonic_time(now_os_monotonic),
                    now_beam_monotonic,
                    @delta
  end

  test "to_system_time/1" do
    now_os_monotonic = OSMonotonic.time()
    now_system_time = System.system_time()

    assert_in_delta OSMonotonic.to_system_time(now_os_monotonic),
                    now_system_time,
                    @delta
  end

  test "from_system_time/1" do
    now_system_time = System.system_time()
    now_os_monotonic = OSMonotonic.time()

    assert_in_delta OSMonotonic.from_system_time(now_system_time),
                    now_os_monotonic,
                    @delta
  end
end
