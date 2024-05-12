defmodule Stampede.MixProject do
  use Mix.Project

  def project do
    [
      app: :stampede,
      version: "0.1.1-dev",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      preferred_cli_env: [release: :prod, test: :test],
      aliases: [test: "test --no-start"],

      # Docs
      name: "Stampede",
      source_url: "https://github.com/ProducerMatt/stampede",
      docs: [
        main: "Stampede",
        extras: ["README.md"]
      ]
    ]
  end

  @doc "Dynamically configure app dependencies for given services"
  def configure_app(list) when is_list(list), do: configure_app(list, nil)

  def configure_app(mod_list, nil) when is_list(mod_list) do
    configure_app(mod_list,
      extra_applications: [:logger, :runtime_tools],
      mod: {Stampede.Application, [installed_services: [:dummy]]},
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
            [:certifi, :gun, :inets, :jason, :kcl, :mime | app_list]
          end)

        configure_app(rest, new_acc)
    end
  end

  def configure_app([], config_acc) when is_list(config_acc), do: config_acc

  def application do
    configure_app([:discord])
  end

  defp deps do
    [
      # Checking
      {:ex_check, "~> 0.16.0", only: [:dev], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev], runtime: false},
      {:doctor, ">= 0.0.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:gettext, ">= 0.0.0", only: [:dev], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev], runtime: false},

      # RUNTIME TYPE CHECKING
      # https://hexdocs.pm/type_check/readme.html
      {:type_check, "~> 0.13.5"},
      # for type checking streams
      {:stream_data, "~> 0.5.0"},

      # Benchmarking
      {:benchee, "~> 1.1", runtime: false, only: :bench},

      # profiling
      # {:eflambe, ">= 0.0.0", only: :dev},
      {:eflambe, ">= 0.0.0"},
      {:sweet_xml, ">= 0.0.0"},

      # Fast arrays
      {:arrays_aja, "~> 0.2.0"},

      # SERVICES
      # {:nostrum, "~> 0.8.0", runtime: false},
      {:nostrum, github: "Kraigie/nostrum", runtime: false},

      # For catching Erlang errors and sending to services
      {:logger_backends, "~> 1.0"},

      # For site configs
      {:fast_yaml, "~> 1.0"},
      # NimbleOptions generates docs with its definitions. Use for site configs.
      # https://hexdocs.pm/nimble_options/NimbleOptions.html
      {:nimble_options, "~> 1.0"},

      # JSON logging to disk. Parse easily with `jq -s <query> ./logs/<env>/<logfile>`
      {:uinta, "~> 0.13.0"},

      # Cron jobs
      {:quantum, "~> 3.5"},

      # CLI monitoring
      {:observer_cli, "~> 1.7", only: :dev},

      # Persistant storage, particularly interaction logging
      {:memento, "~> 0.3.2"}

      ## NOTE: this would be great if it supported TOML
      # {:confispex, "~> 1.1"}, # https://hexdocs.pm/confispex/api-reference.html
    ]
  end

  defp dialyzer() do
    [
      flags: [
        :missing_return,
        :extra_return,
        :unmatched_returns,
        :error_handling,
        :no_improper_lists
      ],
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
