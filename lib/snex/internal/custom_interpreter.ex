defmodule Snex.Internal.CustomInterpreter do
  @moduledoc false

  @type option ::
          {:pyproject_toml, String.t() | nil}
          | {:project_path, String.t() | nil}
          | {:otp_app, atom()}
          | {:uv, String.t()}

  @spec using(module(), [option()]) :: Macro.t()
  def using(caller_module, opts) do
    args =
      opts
      |> Keyword.validate!(
        pyproject_toml: nil,
        project_path: nil,
        otp_app: Application.get_application(caller_module),
        uv: "uv"
      )
      |> Map.new()
      |> Map.update!(:uv, &System.find_executable/1)

    if is_nil(args.otp_app) do
      raise ArgumentError, """
      `otp_app` not given to `use Snex.Interpreter`, and cannot be inferred \
      from caller module #{inspect(caller_module)}.\
      """
    end

    if is_nil(args.uv) do
      raise ArgumentError, """
      `uv` not found in PATH. Make sure that `uv` is installed and available \
      in PATH, or set the `uv` option in `use Snex.Interpreter`.\
      """
    end

    if is_nil(args.pyproject_toml) == is_nil(args.project_path) do
      raise ArgumentError, "Exactly one of `pyproject_toml` and `project_path` must be given."
    end

    %{project_dir: project_dir} = dirs(args.otp_app, caller_module)
    File.mkdir_p!(project_dir)

    external_resources_quote =
      if args.pyproject_toml,
        do: copy_inline_project_files(project_dir, args.pyproject_toml),
        else: copy_external_project_files(project_dir, project_path: args.project_path)

    uv_sync(caller_module, args)

    quote do
      unquote(external_resources_quote)

      def start_link(opts \\ []) do
        %{venv_dir: venv_dir, venv_bin_dir: venv_bin_dir} =
          unquote(__MODULE__).dirs(unquote(args.otp_app), __MODULE__)

        default_env = %{
          "VIRTUAL_ENV" => venv_dir,
          "PATH" => "#{venv_bin_dir}:#{System.get_env("PATH")}"
        }

        opts
        |> Keyword.put_new(:python, Path.join(venv_bin_dir, "python"))
        |> Keyword.update(:environment, default_env, &Map.merge(default_env, &1))
        |> Snex.Interpreter.start_link()
      end

      def child_spec(opts) do
        Supervisor.child_spec({Snex.Interpreter, opts},
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]}
        )
      end

      defoverridable start_link: 1, child_spec: 1
    end
  end

  defp uv_sync(caller_module, args) do
    %{project_dir: project_dir, python_install_dir: python_install_dir, venv_dir: venv_dir} =
      dirs(args.otp_app, caller_module)

    IO.puts("""
    #{inspect(caller_module)}: Fetching Python and dependencies
      project_dir: #{project_dir}
      python_install_dir: #{python_install_dir}
    """)

    with {_, retcode} when retcode != 0 <-
           System.cmd(args.uv, ~w[--managed-python sync],
             into: IO.stream(),
             stderr_to_stdout: true,
             cd: project_dir,
             env: %{
               "UV_PYTHON_INSTALL_DIR" => python_install_dir,
               "UV_PROJECT_ENVIRONMENT" => venv_dir
             }
           ) do
      File.rm_rf!(venv_dir)
      raise "uv sync failed"
    end

    IO.puts("")
    :ok
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

  # credo:disable-for-next-line Credo.Check.Readability.Specs
  def dirs(otp_app, module) do
    priv_dir = otp_app |> :code.priv_dir() |> List.to_string()
    base_dir = Path.join(priv_dir, "snex")
    python_install_dir = Path.join(base_dir, "python")
    project_dir = Path.join(base_dir, inspect(module))
    venv_dir = Path.join(project_dir, ".venv")
    venv_bin_dir = Path.join(venv_dir, "bin")

    %{
      priv_dir: priv_dir,
      base_dir: base_dir,
      python_install_dir: python_install_dir,
      project_dir: project_dir,
      venv_dir: venv_dir,
      venv_bin_dir: venv_bin_dir
    }
  end

  defp cp(src_dir, dst_dir, filename) do
    src_path = Path.join(src_dir, filename)
    dst_path = Path.join(dst_dir, filename)
    File.cp(src_path, dst_path)
  end
end
