defmodule Snex.Internal.Scripts do
  @moduledoc false
  # This module is used to track and copy the `py_src/snex` script directory to the priv directory
  # in compile time.

  alias Snex.Internal

  @script_in_path Path.join("py_src", "snex")
  @script_out_path Path.join(Internal.Paths.snex_pythonpath(), "snex")
  for path <- Path.join(@script_in_path, "**") |> Path.wildcard() do
    @external_resource path
  end

  IO.puts("Copying #{@script_in_path} to #{Path.relative_to_cwd(@script_out_path)}")
  File.rm_rf!(@script_out_path)
  File.mkdir_p!(@script_out_path)
  File.cp_r!(@script_in_path, @script_out_path)
end
