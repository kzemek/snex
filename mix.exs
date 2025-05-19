defmodule Snex.MixProject do
  use Mix.Project

  def project do
    [
      app: :snex,
      compilers: [:elixir_make] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      make_targets: ["all"],
      make_clean: ["clean"],
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ] ++ docs()
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:nimble_options, "~> 1.1.1"},
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
        main: "readme",
        extras: ["README.md", "LICENSE", "NOTICE"]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
