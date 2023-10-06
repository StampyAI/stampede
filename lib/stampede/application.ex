defmodule Stampede.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger
  use TypeCheck

  use Application
  @services %{discord: Service.Discord}

  def app_config_schema() do
    NimbleOptions.new!([
      app_id: [
        type: :atom,
        default: Stampede
      ],
      installed_services: [
        type: {:or, [{:in, [[]]},
                     {:list, {:in, Map.keys(@services)}}]},
        required: true,
        doc: "Services installed as part of the mix project. Passed in from mix.exs"
      ],
      services: [
        type: {:or, [{:in, [:none, :all]},
                     {:list, {:in, [Map.keys(@services)]}}]},
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
    ])
  end

  def all_services(installed, app_id) do 
    installed |> Enum.map(&service_name(&1, app_id))
  end
  def service_name(atom, app_id) when is_atom(atom) do
    @services
    |> Map.fetch!(atom)
    |> then(fn name -> {name, app_id: app_id} end)
  end
  def make_children(args, app_id) do
    default_children = [
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Module.concat(app_id, "QuickTaskSupers")},
      # NOTE: call with {:via, PartitionSupervisor, {app_id.QuickTaskSupers, self()}}
      # See Stampede.quick_task_via(app_id)
      {Registry, keys: :duplicate, name: Module.concat(app_id, "Registry"), partitions: System.schedulers_online()},
      {Stampede.CfgTable, config_dir: Keyword.fetch!(args, :config_dir), app_id: app_id, name: Module.concat(app_id, "CfgTable")}
    ]
    service_tuples = case Keyword.fetch!(args, :services) do
      :all -> all_services(Keyword.fetch!(args, :installed_services), app_id)
      :none -> []
      name when is_atom(name) ->
        [ service_name(name, app_id) ]
      list when is_list(list) or is_tuple(list) ->
        Enum.map(list, &service_name(&1, app_id))
    end
    default_children ++ service_tuples
  end
  @spec! keyword_put_new_if_not_falsy(keyword(), atom(), any()) :: keyword()
  def keyword_put_new_if_not_falsy(kwlist, key, new_value) do
    if new_value not in [nil, false] do
      Keyword.put_new(kwlist, key, new_value)
    else
      kwlist
    end
  end
  @impl Application
  def start(_type, override_args \\ []) do
    Logger.metadata(stampede_component: :application)

    args = keyword_put_new_if_not_falsy(override_args, :services, Application.get_env(:stampede, :services, false))
      |> keyword_put_new_if_not_falsy(:config_dir, Application.get_env(:stampede, :config_dir, false))
      |> NimbleOptions.validate!(app_config_schema())

    app_id = Module.concat([Keyword.get(args, :app_id)])
    if args[:log_to_file], do: :ok = Logger.add_handlers(:stampede)
    
    children = make_children(args, app_id)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Module.concat(app_id, "Supervisor")]
    Supervisor.start_link(children, opts)
  end
  def handle_info(:'DOWN', _, _, worker_pid, reason) do
    Logger.alert("Process #{inspect(worker_pid, pretty: true)} crashed, reason: #{inspect(reason, pretty: true)}")
  end
end
