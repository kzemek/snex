defmodule SnexTest.NumpyInterpreter do
  @moduledoc false
  use Snex.Interpreter,
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
    project_path: "test/my_python_proj"
end
