defmodule Snex.Internal.Script do
  @moduledoc false
  # This module is used to track and copy the `py_src/snex.py` script to the priv directory
  # in compile time.

  @script_in_path "py_src/snex.py"
  @script_out_path :code.priv_dir(:snex) |> Path.join("snex.py") |> Path.relative_to_cwd()
  @external_resource @script_in_path

  IO.puts("Copying #{@script_in_path} to #{@script_out_path}")
  File.cp!(@script_in_path, @script_out_path)

  @spec path() :: String.t()
  def path, do: :code.priv_dir(:snex) |> Path.join("snex.py")
end
