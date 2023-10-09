defmodule Stampede.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger
  use TypeCheck
  alias Stampede, as: S

  use Application

  @services %{discord: Service.Discord}

  def app_config_schema() do
    NimbleOptions.new!(
      app_id: [
        type: {:or, [:atom, :string]},
        default: Stampede
      ],
      installed_services: [
        type: {:or, [{:in, [[]]}, {:list, {:in, Map.keys(@services)}}]},
        required: true,
        doc: "Services installed as part of the mix project. Passed in from mix.exs"
      ],
      services: [
        type: {:or, [{:in, [:none, :all]}, {:list, {:in, [Map.keys(@services)]}}]},
        default: :all,
        doc: "what will actually be started by Stampede"
      ],
      config_dir: [
        type: :string,
        default: "./Sites",
        doc: "read from :stampede/:config_dir"
      ],
      log_to_file: [
        type: :boolean,
        default: true,
        doc: "enable file logging"
      ]
    )
  end

  @impl Application
  def start(_type, override_args \\ []) do
    :ok = Logger.metadata(stampede_component: :application)

    args =
      S.keyword_put_new_if_not_falsy(
        override_args,
        :services,
        Application.get_env(:stampede, :services, false)
      )
      |> S.keyword_put_new_if_not_falsy(
        :config_dir,
        Application.get_env(:stampede, :config_dir, false)
      )
      |> NimbleOptions.validate!(app_config_schema())

    if args[:log_to_file], do: :ok = Logger.add_handlers(:stampede)

    app_id = Keyword.get(args, :app_id)

    children = make_children(args, app_id)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Module.concat(app_id, "Supervisor")]
    Supervisor.start_link(children, opts)
  end

  def service_spec(atom, app_id) when is_atom(atom) do
    @services
    |> Map.fetch!(atom)
    |> then(fn name -> {name, app_id: app_id} end)
  end

  def all_services(installed, app_id) do
    installed |> Enum.map(&service_spec(&1, app_id))
  end

  def make_children(args, app_id) do
    default_children = [
      {Registry,
       keys: :unique,
       name: Module.concat(app_id, "Registry"),
       partitions: System.schedulers_online()},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: S.via(app_id, "QuickTaskSupers")}
      # NOTE: call with {:via, S.via(app_id, "PartitionSupervisor"), {S.via(app_id, "QuickTaskSupers"), self()}}
      # See Stampede.quick_task_via(app_id)
      # {Stampede.CfgTable,
      # config_dir: Keyword.fetch!(args, :config_dir),
      # app_id: app_id,
      # name: S.via(app_id, "CfgTable")}
    ]

    service_tuples =
      case Keyword.fetch!(args, :services) do
        :all ->
          Logger.debug("#{app_id} starting all services")
          all_services(Keyword.fetch!(args, :installed_services), app_id)

        :none ->
          Logger.debug("#{app_id} starting no services")
          []

        name when is_atom(name) ->
          Logger.debug("#{app_id} starting only #{name}")
          [service_spec(name, app_id)]

        list when is_list(list) or is_tuple(list) ->
          Logger.debug("#{app_id} starting these: #{inspect(list)}")
          Enum.map(list, &service_spec(&1, app_id))
      end

    default_children ++ service_tuples
  end

  def handle_info(:DOWN, _, _, worker_pid, reason) do
    Logger.alert(
      "Process #{inspect(worker_pid, pretty: true)} crashed, reason: #{inspect(reason, pretty: true)}"
    )
  end
end
