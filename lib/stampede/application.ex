defmodule Stampede.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger
  use TypeCheck

  use Application
  @services %{discord: Service.Discord}

  def all_services(app_id), do: Map.keys(@services) |> Enum.map(&service_name(&1, app_id))
  def service_name(atom, app_id) when is_atom(atom) do
    @services
    |> Map.fetch!(atom)
    |> then(fn name -> {name, app_id: app_id} end)
  end
  def make_children(services, app_id) do
    default_children = [
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Module.concat(app_id, "QuickTaskSupers")},
      # NOTE: call with {:via, PartitionSupervisor, {app_id.QuickTaskSupers, self()}}
      # See Stampede.quick_task_via(app_id)
      {Registry, keys: :duplicate, name: Module.concat(app_id, "Registry"), partitions: System.schedulers_online()}
    ]
    service_tuples = case services do
      nil -> all_services(app_id)
      [] -> []
      name when is_atom(name) ->
        [ service_name(name, app_id) ]
      list when is_list(list) or is_tuple(list) ->
        Enum.map(list, &service_name(&1, app_id))
    end
    default_children ++ service_tuples
  end
  @impl Application
  def start(_type, override_args \\ []) do
    defaults = [app_id: "Stampede", services: []]
    args = Keyword.merge(defaults, override_args)
    app_id = Module.concat([Keyword.get(args, :app_id)])
    :ok = Logger.add_handlers(:stampede)
    
    children = Keyword.get(args, :services)
      |> make_children(app_id)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Module.concat(app_id, "Supervisor")]
    Supervisor.start_link(children, opts)
  end
  def handle_info(:'DOWN', _, _, worker_pid, reason) do
    Logger.alert("Process #{inspect(worker_pid, pretty: true)} crashed, reason: #{inspect(reason, pretty: true)}")
  end
end
