defmodule Snex.Internal.CustomInterpreter do
  @moduledoc false

  def using(caller, opts) do
    args =
      opts
      |> Keyword.validate!(
        pyproject_toml: nil,
        project_path: nil,
        otp_app: Application.get_application(caller.module),
        uv: "uv"
      )
      |> Map.new()
      |> Map.update!(:uv, &System.find_executable/1)

    if is_nil(args.otp_app) do
      raise ArgumentError, """
      `otp_app` not given to `use Snex.Interpreter`, and cannot be inferred \
      from caller module #{inspect(caller.module)}.\
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

    %{project_dir: project_dir} = dirs(args.otp_app, caller.module)
    File.mkdir_p!(project_dir)

    external_resources_quote =
      if args.pyproject_toml,
        do: copy_inline_project_files(project_dir, args.pyproject_toml),
        else: copy_external_project_files(project_dir, project_path: args.project_path)

    uv_sync(caller.module, args)

    quote do
      unquote(external_resources_quote)

      def start_link(opts \\ []) do
        %{venv_dir: venv_dir, venv_bin_dir: venv_bin_dir} =
          unquote(__MODULE__).dirs(unquote(args.otp_app), __MODULE__)

        python = Keyword.get(opts, :python, Path.join(venv_bin_dir, "python"))

        environment =
          Map.merge(
            %{"VIRTUAL_ENV" => venv_dir, "PATH" => "#{venv_bin_dir}:#{System.get_env("PATH")}"},
            Keyword.get(opts, :environment, %{})
          )

        Snex.Interpreter.start_link(python: python, environment: environment)
      end

      def child_spec(opts \\ []) do
        %{Snex.Interpreter.child_spec(opts) | start: {__MODULE__, :start_link, [opts]}}
      end
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
    File.write!(Path.join(project_dir, "pyproject.toml"), pyproject_toml)
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

  def dirs(otp_app, module) do
    priv_dir = List.to_string(:code.priv_dir(otp_app))
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

  defp cp(src_dir, dst_dir, filename),
    do: File.cp(Path.join(src_dir, filename), Path.join(dst_dir, filename))
end
