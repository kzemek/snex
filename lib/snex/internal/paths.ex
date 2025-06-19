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

  def base_dir, do: Path.expand(Path.join([:code.priv_dir(:snex), "..", "..", "..", "snex"]))
  def python_install_dir(base_dir \\ nil), do: Path.join(base_dir || base_dir(), "python")
  def projects_dir(base_dir \\ nil), do: Path.join(base_dir || base_dir(), "projects")
  def project_dir(project_name), do: Path.join(projects_dir(), to_string(project_name))
  def venv_dir(project_name), do: Path.join(project_dir(project_name), "venv")
  def venv_bin_dir(project_name), do: Path.join(venv_dir(project_name), "bin")
  def snex_pythonpath, do: Path.join(:code.priv_dir(:snex), "py_src")
end
