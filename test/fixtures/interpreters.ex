defmodule SnexTest.NumpyInterpreter do
  @moduledoc false
  use Snex.Interpreter,
    otp_app: :snex,
    pyproject_toml: """
    [project]
    name = "project"
    version = "0.0.0"
    requires-python = "==3.10.*"
    dependencies = ["numpy>=2"]
    """
end

defmodule SnexTest.MyProject do
  @moduledoc false
  use Snex.Interpreter,
    otp_app: :snex,
    project_path: "test/my_python_proj"

  @spec start_link(list()) :: GenServer.on_start()
  def start_link(opts) do
    my_project_path = "test/my_python_proj"

    opts
    |> Keyword.put(:environment, %{"PYTHONPATH" => my_project_path})
    |> super()
  end
end
