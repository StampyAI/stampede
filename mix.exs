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
      preferred_cli_env: [release: :prod, t: :test],
      aliases: [t: "test --no-start"]
    ]
  end

  def configure_app(list) when is_list(list), do: configure_app(list, nil)

  def configure_app(mod_list, nil) when is_list(mod_list) do
    configure_app(mod_list,
      extra_applications: [:logger, :runtime_tools],
      mod: {Stampede.Application, [installed_services: []]},
      included_applications: []
    )
  end

  def configure_app([first | rest], config_acc) when is_list(config_acc) do
    case first do
      :discord ->
        new_acc =
          config_acc
          |> Keyword.update!(:mod, fn {mod, kwlist} ->
            {mod,
             Keyword.update!(kwlist, :installed_services, fn list ->
               [:discord | list]
             end)}
          end)
          |> Keyword.update!(:extra_applications, fn app_list ->
            [:nostrum, :certifi, :gun, :inets, :jason, :kcl, :mime | app_list]
          end)

        configure_app(rest, new_acc)
    end
  end

  def configure_app([], config_acc) when is_list(config_acc), do: config_acc
  # Run "mix help compile.app" to learn about applications.
  def application do
    configure_app([:discord])
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.4", runtime: false},
      {:credo, "~> 1.7", runtime: false},
      {:nostrum, "~> 0.8.0", runtime: false},
      {:logger_backends, "~> 1.0"},
      {:type_check, "~> 0.13.5"},
      # https://hexdocs.pm/type_check/readme.html
      {:fast_yaml, "~> 1.0"},
      {:gen_stage, "~> 1.2"},
      # https://hexdocs.pm/gen_stage/GenStage.html
      {:nimble_options, "~> 1.0"},
      # https://hexdocs.pm/nimble_options/NimbleOptions.html
      {:logstash_logger_formatter, "~> 1.1"}
      ## NOTE: this would be great if it supported TOML
      # {:confispex, "~> 1.1"}, # https://hexdocs.pm/confispex/api-reference.html
    ]
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling],
      ignore_warnings: "config/dialyzer.ignore"
    ]
  end
end
