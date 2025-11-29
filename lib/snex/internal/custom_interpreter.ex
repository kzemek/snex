defmodule Snex.Internal.CustomInterpreter do
  @moduledoc false

  alias Snex.Internal

  @type option ::
          {:pyproject_toml, Path.t() | nil}
          | {:project_path, Path.t() | nil}
          | {:uv, String.t()}

  @spec using(module(), [option()]) :: Macro.t()
  def using(caller_module, opts) do
    args = validate_opts(opts)

    dirs = Internal.Paths.runtime_dirs(caller_module)
    File.mkdir_p!(dirs.project_dir)

    external_resources_quote =
      if args.pyproject_toml,
        do: copy_inline_project_files(dirs.project_dir, args.pyproject_toml),
        else: copy_external_project_files(dirs.project_dir, project_path: args.project_path)

    sync_venv!(args.uv, caller_module, dirs)

    quote do
      unquote(external_resources_quote)

      Module.register_attribute(__MODULE__, :snex, persist: true)
      Module.put_attribute(__MODULE__, :snex, true)

      def __mix_recompile__? do
        dirs = unquote(Internal.Paths).runtime_dirs(__MODULE__)
        {_, ret} = unquote(__MODULE__).uv_cmd(unquote(args.uv), ~w[sync --check --no-dev], dirs)
        ret != 0
      rescue
        _ -> true
      end

      def start_link(opts \\ []) do
        dirs = unquote(Internal.Paths).runtime_dirs(__MODULE__)

        path =
          case get_in(opts[:environment]["PATH"]) || System.get_env("PATH") do
            nil -> dirs.venv_bin_dir
            path -> "#{dirs.venv_bin_dir}:#{path}"
          end

        environment = %{"VIRTUAL_ENV" => dirs.venv_dir, "PATH" => path}

        opts
        |> Keyword.put_new(:python, Path.join(dirs.venv_bin_dir, "python"))
        |> Keyword.put_new(:cd, dirs.project_dir)
        |> Keyword.put_new(:label, __MODULE__)
        |> Keyword.update(:environment, environment, &Map.merge(&1, environment))
        |> Snex.Interpreter.start_link()
      end

      def child_spec(opts) do
        Supervisor.child_spec({Snex.Interpreter, opts},
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]}
        )
      end

      defoverridable __mix_recompile__?: 0, start_link: 1, child_spec: 1
    end
  end

  defp validate_opts(opts) do
    args =
      opts
      |> Keyword.validate!(
        pyproject_toml: nil,
        project_path: nil,
        uv: "uv"
      )
      |> Map.new()
      |> Map.update!(:uv, &System.find_executable/1)

    if is_nil(args.uv) do
      raise ArgumentError, """
      `uv` not found in PATH. Make sure that `uv` is installed and available \
      in PATH, or set the `uv` option in `use Snex.Interpreter`.\
      """
    end

    if is_nil(args.pyproject_toml) == is_nil(args.project_path) do
      raise ArgumentError, "Exactly one of `pyproject_toml` and `project_path` must be given."
    end

    args
  end

  defp sync_venv!(uv, caller_module, %Internal.Paths{} = dirs) do
    IO.puts("""
    #{inspect(caller_module)}: Fetching Python and dependencies
      project_dir: #{Path.relative_to_cwd(dirs.project_dir)}
      python_install_dir: #{Path.relative_to_cwd(dirs.python_install_dir)}
    """)

    if not File.dir?(dirs.venv_dir), do: make_venv!(uv, dirs)

    uv_sync!(uv, dirs)
    IO.puts("")

    :ok
  rescue
    e ->
      File.rm_rf!(dirs.venv_dir)
      reraise e, __STACKTRACE__
  end

  defp make_venv!(uv, dirs) do
    {_, 0} = uv_cmd(uv, ~w[--managed-python venv --relocatable], dirs, stream?: true)
    relativize_symlinks!(dirs)
    relativize_pyvenv_home!(dirs)
  end

  defp relativize_symlinks!(dirs) do
    for link_path <- Path.join(dirs.venv_dir, "**") |> Path.wildcard(match_dot: true),
        File.lstat!(link_path).type == :symlink,
        link_target = File.read_link!(link_path),
        Path.type(link_target) == :absolute do
      relative_link_target = Path.relative_to(link_target, Path.dirname(link_path), force: true)
      File.rm!(link_path)
      File.ln_s!(relative_link_target, link_path)
    end
  end

  defp relativize_pyvenv_home!(dirs) do
    pyvenv_cfg_path = Path.join(dirs.venv_dir, "pyvenv.cfg")

    updated_pyvenv_cfg =
      Regex.replace(
        ~r/^\s*home\s*=\s*(.*\S)\s*$/m,
        File.read!(pyvenv_cfg_path),
        fn _, home ->
          relative_home = String.trim(home) |> Path.relative_to(dirs.project_dir, force: true)
          "home = #{relative_home}"
        end,
        global: false
      )

    File.write!(pyvenv_cfg_path, updated_pyvenv_cfg)

    :ok
  end

  defp uv_sync!(uv, dirs) do
    {_, 0} = uv_cmd(uv, ~w[sync --no-dev], dirs, stream?: true)
    :ok
  end

  @doc false
  @spec uv_cmd(String.t(), [String.t()], Internal.Paths.t(), Keyword.t()) ::
          {String.t(), integer()}
  def uv_cmd(uv, args, %Internal.Paths{} = dirs, opts \\ []) do
    System.cmd(uv, args,
      into: if(opts[:stream?], do: IO.stream(), else: ""),
      stderr_to_stdout: true,
      cd: dirs.project_dir,
      env: %{
        "UV_PYTHON_INSTALL_DIR" => dirs.python_install_dir,
        "UV_PROJECT_ENVIRONMENT" => dirs.venv_dir
      }
    )
  end

  defp copy_inline_project_files(project_dir, pyproject_toml) do
    Path.join(project_dir, "pyproject.toml") |> File.write!(pyproject_toml)
    nil
  end

  defp copy_external_project_files(project_dir, project_path: src_project_path) do
    :ok = cp(src_project_path, project_dir, "pyproject.toml")

    with {:error, reason} <- cp(src_project_path, project_dir, "uv.lock") do
      IO.warn("Failed to copy `uv.lock` from #{src_project_path} due to #{inspect(reason)}")
    end

    pyproject_toml_path = Path.join(src_project_path, "pyproject.toml")
    uv_lock_path = Path.join(src_project_path, "uv.lock")

    quote do
      @external_resource unquote(pyproject_toml_path)
      @external_resource unquote(uv_lock_path)
    end
  end

  defp cp(src_dir, dst_dir, filename) do
    src_path = Path.join(src_dir, filename)
    dst_path = Path.join(dst_dir, filename)
    File.cp(src_path, dst_path)
  end
end
