defmodule Snex.MixProject do
  use Mix.Project

  def project do
    [
      app: :snex,
      description: "🐍 Easy and efficient Python interop for Elixir",
      compilers: [:elixir_make] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      make_targets: ["all"],
      make_clean: ["clean"],
      version: "0.4.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      dialyzer: dialyzer()
    ] ++ docs()
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Snex.Application, []}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9.0", runtime: false},
      # dev dependencies
      {:makeup_syntect, "~> 0.1", only: :dev, runtime: false},
      {:markdown_doctest, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:ex_unit_clustered_case, "~> 0.5", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false, optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false, optional: true}
    ]
  end

  defp docs do
    [
      name: "Snex",
      source_url: "https://github.com/kzemek/snex",
      homepage_url: "https://github.com/kzemek/snex",
      docs: [
        main: "Snex",
        extras: [
          "CHANGELOG.md": [title: "Changelog"],
          License: [title: "License"],
          Notice: [title: " Notice"]
        ],
        assets: %{"doc_helpers/script" => "script"},
        before_closing_head_tag: fn
          :html -> ~s'<script src="script/rename_python_interface_documentation.js"></script>'
          _ -> ""
        end
      ]
    ]
  end

  defp package do
    [
      links: %{"GitHub" => "https://github.com/kzemek/snex"},
      licenses: ["Apache-2.0"],
      files: [
        ".formatter.exs",
        "c_src/*.[ch]",
        "CHANGELOG.md",
        "lib",
        "LICENSE",
        "Makefile",
        "mix.exs",
        "NOTICE",
        "py_src/snex/*.py",
        "py_src/pyproject.toml",
        "py_src/uv.lock",
        "README.md"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      credo: "credo --strict",
      ruff: &ruff/1,
      mypy: &mypy/1,
      lint: ["credo", "dialyzer", "ruff", "mypy"],
      docs: [&gen_python_doc/1, "docs", &clean_python_doc/1]
    ]
  end

  defp ruff(_) do
    Mix.shell().info("Running ruff")
    Mix.shell().cmd("uv run --python 3.14 ruff check", cd: "py_src")
  end

  defp mypy(_) do
    Mix.shell().info("Running mypy")
    Mix.shell().cmd("uv run --python 3.14 mypy --strict .", cd: "py_src")
  end

  defp gen_python_doc(_) do
    Mix.shell().info("Generating Python documentation")

    script_path = Path.join(["doc_helpers", "gen_python_doc.py"])
    dest_path = Path.join(["lib", "python_interface_documentation.ex"])
    env = [{"PYTHONPATH", "py_src"}]

    if Mix.shell().cmd(~s'uv run "#{script_path}" "#{dest_path}"', env: env) != 0,
      do: Mix.raise("Failed to generate Python documentation; see stdout/stderr for details")
  end

  defp clean_python_doc(_) do
    Path.join(["lib", "python_interface_documentation.ex"])
    |> File.rm_rf!()

    Path.join([Mix.Project.build_path(), "ebin", "Elixir.Python_Interface_Documentation.beam"])
    |> File.rm_rf!()
  end
end
