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
      version: "0.1.0",
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9.0", runtime: false},
      # dev dependencies
      {:ex_doc, "~> 0.38.1", only: :dev, runtime: false, optional: true},
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
        extras: ["LICENSE", "NOTICE"]
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
      lint: ["credo", "dialyzer", "ruff", "mypy"]
    ]
  end

  defp ruff(_) do
    Mix.shell().info("Running ruff")
    Mix.shell().cmd("uv run ruff check", cd: "py_src")
  end

  defp mypy(_) do
    Mix.shell().info("Running mypy")
    Mix.shell().cmd("uv run mypy --strict .", cd: "py_src")
  end
end
