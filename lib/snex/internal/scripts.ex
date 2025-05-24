defmodule Snex.Internal.Scripts do
  @moduledoc false
  # This module is used to track and copy the `py_src/snex` script directory to the priv directory
  # in compile time.

  @script_in_path "py_src/snex"
  @script_out_path :code.priv_dir(:snex) |> Path.join("snex")
  for path <- Path.wildcard("py_src/snex/*") do
    @external_resource path
  end

  IO.puts("Copying #{@script_in_path} to #{Path.relative_to_cwd(@script_out_path)}")
  File.cp_r!(@script_in_path, @script_out_path)
end
