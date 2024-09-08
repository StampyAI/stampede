defmodule Stampede.MixProject do
  use Mix.Project

  def project do
    [
      app: :stampede,
      version: "0.1.2-dev",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      preferred_cli_env: [release: :prod, compile: :prod, test: :test],
      # Appears to not work at all
      erlc_options: [
        strong_validation: true,
        recv_opt_info: true,
        bin_opt_info: true
      ],

      # Docs
      name: "Stampede",
      source_url: "https://github.com/ProducerMatt/stampede",
      docs: [
        main: "Stampede",
        extras: ["README.md"]
      ]
    ]
  end

  defp service_requirements_map() do
    %{
      Services.Discord => fn config_acc ->
        config_acc
        |> Keyword.update!(:extra_applications, fn app_list ->
          [:certifi, :gun, :inets, :jason, :kcl, :mime | app_list]
        end)
      end
    }
  end

  def application do
    configure_app(Application.fetch_env!(:stampede, :services_to_install))
  end

  @doc "Dynamically configure app dependencies for given services"
  def configure_app(:all) do
    service_requirements_map()
    |> Map.keys()
    |> configure_app()
  end

  def configure_app(list) when is_list(list), do: configure_app(list, nil)

  defp configure_app(mod_list, nil) when is_list(mod_list) do
    configure_app(mod_list,
      extra_applications: [:logger, :runtime_tools],
      mod: {Stampede.Application, []},
      included_applications: [],
      env: [
        installed_services: [Services.Dummy]
      ]
    )
  end

  defp configure_app([first_service_name | rest], config_acc) when is_list(config_acc) do
    update_fun = Map.fetch!(service_requirements_map(), first_service_name)

    new_acc =
      update_fun.(config_acc)
      |> Keyword.update!(:env, fn env_ls ->
        # always add service name to :installed_services
        Keyword.update!(env_ls, :installed_services, fn installed ->
          if first_service_name in installed,
            do:
              raise(
                "There's no reason for #{first_service_name |> inspect()} to already be there??"
              )

          [first_service_name | installed]
        end)
      end)

    configure_app(rest, new_acc)
  end

  defp configure_app([], config_acc) when is_list(config_acc), do: config_acc

  defp deps do
    [
      # Checking
      {:ex_check, "~> 0.16.0", only: [:dev], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:doctor, ">= 0.0.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:gettext, ">= 0.0.0", only: [:dev], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev], runtime: false},
      # must be started before use, see test/test_helper.exs
      {:assert_value, "~> 0.10.4", only: [:test, :dev]},

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
      {:nostrum, "~> 0.9.1", runtime: false},
      # {:nostrum, github: "Kraigie/nostrum", runtime: false},

      # EXTERNAL PLUGIN SUPPORT
      {:doumi_port, "~> 0.6.0"},
      # override erlport for newer version
      {:erlport, "~> 0.11.0", override: true},

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
      {:memento, "~> 0.3.2"},

      # Erlang match specifications in Elixir style
      {:ex2ms, "~> 1.7"},

      # storage for Services.Dummy
      {:ets, "~> 0.9.0"}

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
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      # NOTE: Nostrum for some reason doesn't give type info without explicitly demanding it
      plt_add_apps: [:nostrum]
    ]
  end
end
