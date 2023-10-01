defmodule Stampede.MixProject do
  use Mix.Project

  def project do
    [
      app: :stampede,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      preferred_cli_env: [release: :prod],
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.4", runtime: false},
      {:credo, "~> 1.7", runtime: false},
      {:nostrum, "~> 0.8.0", runtime: false}, # TODO: totally disable when not configured
      {:logger_backends, "~> 1.0"},
      {:type_check, "~> 0.13.5"}, # https://hexdocs.pm/type_check/readme.html
      {:fast_yaml, "~> 1.0"},
      {:gen_stage, "~> 1.2"}, # https://hexdocs.pm/gen_stage/GenStage.html
      {:nimble_options, "~> 1.0"}, # https://hexdocs.pm/nimble_options/NimbleOptions.html
      ## NOTE: this would be great if it supported TOML
      #{:confispex, "~> 1.1"}, # https://hexdocs.pm/confispex/api-reference.html
    ]
  end
  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling],
      ignore_warnings: "config/dialyzer.ignore"
    ]
  end
end
