defmodule Snex.Release do
  @moduledoc """
  Snex puts its managed files under `_build/$MIX_ENV/snex`.
  This works out of the box with `iex -S mix` and other local ways of running your code,
  but requires an additional step to copy files around to prepare your releases.

  This module provides a release step `after_assemble/1` that does this for you.
  Just add `&Snex.Release.after_assemble/1` to `:steps` of your Mix release config.
  The only requirement is that it's placed after `:assemble` (and before `:tar`, if you use it.)

      # mix.exs
      def project do
        [
          releases: [
            demo: [
              steps: [:assemble, &Snex.Release.after_assemble/1]
            ]
          ]
        ]
      end
  """

  alias Snex.Internal

  @doc """
  Prepares a release of Snex files.
  Add this function as a step in your Mix release config.

  See the `m:Snex.Release` module documentation for more detail.
  """
  @spec after_assemble(Mix.Release.t()) :: Mix.Release.t()
  def after_assemble(%Mix.Release{} = rel) do
    src_dir = Internal.Paths.base_dir()
    src_python_install_dir = Internal.Paths.python_install_dir()
    src_projects_dir = Internal.Paths.projects_dir()

    target_dir = Path.join(rel.path, "snex")
    target_python_install_dir = Internal.Paths.python_install_dir(target_dir)
    target_projects_path = Internal.Paths.projects_dir(target_dir)

    IO.puts("Copying #{Path.relative_to_cwd(src_dir)} to #{Path.relative_to_cwd(target_dir)}")
    File.rm_rf!(target_dir)
    File.mkdir_p!(target_python_install_dir)
    File.mkdir_p!(target_projects_path)

    used_pythons =
      for src_project_path <- Path.join(src_projects_dir, "*") |> Path.wildcard(),
          project_name = Path.basename(src_project_path),
          snex_custom_interpreter?(project_name),
          reduce: MapSet.new() do
        used_pythons ->
          target_project_path = Path.join(target_projects_path, project_name)
          File.cp_r!(src_project_path, target_project_path)

          python_name = python_name(src_project_path)
          with_symlinks(used_pythons, python_name, src_python_install_dir)
      end

    for python_name <- used_pythons do
      python_path = Path.join(src_python_install_dir, python_name)
      target_python_path = Path.join(target_python_install_dir, python_name)
      File.cp_r!(python_path, target_python_path)
    end

    rel
  end

  defp with_symlinks(%MapSet{} = acc, python_name, src_python_install_dir) do
    python_path = Path.join(src_python_install_dir, python_name)

    with false <- MapSet.member?(acc, python_name),
         %{type: :symlink} <- File.lstat!(python_path) do
      link_target = File.read_link!(python_path)
      linked_python_name = Path.basename(link_target)

      MapSet.put(acc, python_name)
      |> with_symlinks(linked_python_name, src_python_install_dir)
    else
      _ -> MapSet.put(acc, python_name)
    end
  end

  defp snex_custom_interpreter?(project_name) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    module = String.to_atom(project_name)
    module.__info__(:attributes) |> Keyword.has_key?(:snex)
  rescue
    UndefinedFunctionError -> false
  end

  defp python_name(src_project_path) do
    pyvenv_cfg = Path.join([src_project_path, "venv", "pyvenv.cfg"]) |> File.read!()
    [_, python_name] = Regex.run(~r"^\s*home\s*=.*python/([^/]+)/bin\s*$"m, pyvenv_cfg)
    python_name
  end
end
