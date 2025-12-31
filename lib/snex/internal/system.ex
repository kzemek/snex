defmodule Snex.Internal.System do
  @moduledoc false

  @doc """
  Get RSS (Resident Set Size) in bytes for a process via `ps` command.

  Works on GNU/BSD systems (Linux, macOS, BSD).
  """
  @spec get_rss_via_ps(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, :ps_failed}
  def get_rss_via_ps(os_pid) do
    case System.cmd("ps", ["-o", "rss=", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      {output, 0} ->
        rss_kb = output |> String.trim() |> String.to_integer()
        {:ok, rss_kb * 1024}

      {_output, _exit_code} ->
        {:error, :ps_failed}
    end
  end

  @doc """
  Get RSS (Resident Set Size) in bytes for a process via `/proc/[pid]/status`.

  Works on Linux/BusyBox systems with limited `ps`.
  """
  @spec get_rss_via_proc(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :vmrss_not_found | atom()}
  def get_rss_via_proc(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, content} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/, content) do
          [_, rss_kb] ->
            {:ok, String.to_integer(rss_kb) * 1024}

          nil ->
            {:error, :vmrss_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
