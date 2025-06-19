defmodule SnexTest.ReleaseTest do
  use ExUnit.Case, async: false

  # credo:disable-for-this-file Credo.Check.Readability.NestedFunctionCalls

  setup_all do
    tmpdir = Path.join(System.tmp_dir!(), "#{__MODULE__}-#{System.pid()}")
    File.mkdir_p!(tmpdir)
    on_exit(fn -> File.rm_rf!(tmpdir) end)

    IO.puts("\n=================== START CREATE TEST RELEASE ===================")

    make_project!(tmpdir)
    assert {_, 0} = run(~w"mix deps.get", cd: tmpdir, into: IO.stream())
    assert {_, 0} = run(~w"mix release", cd: tmpdir, into: IO.stream())

    File.cp_r!(
      Path.join([tmpdir, "_build", "dev", "rel", "default_release"]),
      Path.join(tmpdir, "default_release")
    )

    IO.puts("==================== END CREATE TEST RELEASE ====================\n")

    %{release_dir: Path.join(tmpdir, "default_release")}
  end

  test "creates a relocatable release", %{release_dir: release_dir} do
    {output, _} = run([Path.join([release_dir, "bin", "default_release"]), "start"])
    assert output =~ "error: :relocatable_test_done"
  end

  test "release only includes used python installations", %{release_dir: release_dir} do
    copied_pythons = File.ls!(Path.join(["_build", "test", "snex", "python"]))
    rel_pythons = File.ls!(Path.join([release_dir, "snex", "python"]))
    assert length(copied_pythons) != length(rel_pythons)
    assert length(rel_pythons) == 1
  end

  test "release doesn't include python projects that are not used", %{release_dir: release_dir} do
    copied_projects = File.ls!(Path.join(["_build", "test", "snex", "projects"]))
    rel_projects = File.ls!(Path.join([release_dir, "snex", "projects"]))
    assert length(copied_projects) != length(rel_projects)
    assert length(rel_projects) == 1
  end

  defp make_project!(tmpdir) do
    mix_exs_path = Path.join(tmpdir, "mix.exs")
    modules_ex_path = Path.join([tmpdir, "lib", "modules.ex"])
    snex_path = Path.join([tmpdir, "_build", "dev", "snex"])
    snex_python_path = Path.join(snex_path, "python")
    snex_projects_path = Path.join(snex_path, "projects")

    File.write!(mix_exs_path, mix_exs())
    File.mkdir_p!(Path.dirname(modules_ex_path))
    File.write!(modules_ex_path, modules_ex())
    File.ln_s!(Path.absname("deps"), Path.join(tmpdir, "deps"))

    # Seed python directory with what we have in test
    File.mkdir_p!(Path.dirname(snex_python_path))
    File.cp_r!(Path.join(["_build", "test", "snex", "python"]), snex_python_path)

    # Add a fake python project
    fake_python_proj_path = Path.join(snex_projects_path, "Elixir.RelocatableTest")
    File.mkdir_p!(fake_python_proj_path)

    fake_python_proj_path
    |> Path.join("pyproject.toml")
    |> File.write!("""
    [project]
    name = "fake_python_proj"
    version = "0.1.0"
    """)
  end

  defp run([arg0 | args], opts \\ []) do
    System.cmd(arg0, args, [stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}]] ++ opts)
  end

  defp mix_exs do
    """
    defmodule RelocatableTest.MixProject do
      use Mix.Project

      def project do
        [
          app: :relocatable_test,
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: Mix.env() == :prod,
          default_release: :default_release,
          releases: [
            default_release: [
              steps: [:assemble, &Snex.Release.after_assemble/1]
            ]
          ],
          deps: deps()
        ]
      end

      def application do
        [
          mod: {RelocatableTest, []},
          extra_applications: [:logger]
        ]
      end

      defp deps do
        [
          {:snex, path: #{inspect(Path.absname("."))}}
        ]
      end
    end
    """
  end

  defp modules_ex do
    ~s'''
    defmodule RelocatableTest.Interpreter do
      use Snex.Interpreter,
        pyproject_toml: """
          [project]
          name = "python-files"
          version = "0.1.0"
          description = "Add your description here"
          readme = "README.md"
          requires-python = ">=3.10"
          dependencies = [
              "dill",
              "numpy",
          ]
          """
    end

    defmodule RelocatableTest do
      use Application

      def start(_type, _args) do
        children = [{RelocatableTest.Interpreter, name: RelocatableTest.Interpreter}]
        Supervisor.start_link(children, strategy: :one_for_one, name: RelocatableTest.Supervisor)
        {:ok, env} = Snex.make_env(RelocatableTest.Interpreter)
        {:ok, "[1 2 3]"} = Snex.pyeval(env, """
          import dill
          import numpy
          x = dill.loads(dill.dumps(numpy.array([1, 2, 3])))
          """, returning: "str(x)")
        {:error, :relocatable_test_done}
      end
    end
    '''
  end
end
