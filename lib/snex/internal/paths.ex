defmodule Snex.Internal.Paths do
  @moduledoc false

  defstruct [:base_dir, :project_dir, :python_install_dir, :venv_bin_dir, :venv_dir]

  @type t :: %__MODULE__{
          base_dir: Path.t(),
          project_dir: Path.t(),
          python_install_dir: Path.t(),
          venv_bin_dir: Path.t(),
          venv_dir: Path.t()
        }

  @spec runtime_dirs(project_name :: module() | String.t()) :: t()
  def runtime_dirs(project_name) do
    %__MODULE__{
      base_dir: base_dir(),
      python_install_dir: python_install_dir(),
      project_dir: project_dir(project_name),
      venv_dir: venv_dir(project_name),
      venv_bin_dir: venv_bin_dir(project_name)
    }
  end

  @spec base_dir() :: Path.t()
  def base_dir, do: Path.join([:code.priv_dir(:snex), "..", "..", "..", "snex"]) |> Path.expand()

  @spec python_install_dir(Path.t() | nil) :: Path.t()
  def python_install_dir(base_dir \\ nil), do: (base_dir || base_dir()) |> Path.join("python")

  @spec projects_dir(Path.t() | nil) :: Path.t()
  def projects_dir(base_dir \\ nil), do: (base_dir || base_dir()) |> Path.join("projects")

  @spec project_dir(module() | String.t()) :: Path.t()
  def project_dir(project_name), do: projects_dir() |> Path.join("#{project_name}")

  @spec venv_dir(project_name :: module() | String.t()) :: Path.t()
  def venv_dir(project_name), do: project_dir(project_name) |> Path.join("venv")

  @spec venv_bin_dir(project_name :: module() | String.t()) :: Path.t()
  def venv_bin_dir(project_name), do: venv_dir(project_name) |> Path.join("bin")

  @spec snex_pythonpath() :: Path.t()
  def snex_pythonpath, do: :code.priv_dir(:snex) |> Path.join("py_src")
end
