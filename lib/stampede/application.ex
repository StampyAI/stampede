defmodule Stampede.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger
  use TypeCheck

  use Application
  @services %{discord: Service.Discord, dummy: Service.Dummy}

  def all_services(), do: Map.values(@services)
  def service_name(atom) when is_atom(atom) do
    @services
    |> Map.get(atom)
  end
  @impl Application
  def start(_type, args) do
    :ok = Logger.add_handlers(:stampede)
    default_children = [
      {Task.Supervisor, name: Stampede.TaskSupervisor},
      # TODO: partition task supervisors: https://hexdocs.pm/elixir/1.15/Task.Supervisor.html
      {Registry, keys: :duplicate, name: Stampede.Registry, partitions: System.schedulers_online()}
    ]
    children = case Keyword.get(args, :services) do
      nil -> all_services()
      [] -> []
      name when is_atom(name) ->
        [ service_name(name) ]
      list when is_list(list) or is_tuple(list) ->
        Enum.map(list, &service_name/1)
    end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Stampede.Supervisor]
    Supervisor.start_link(default_children ++ children, opts)
  end
  def handle_info(:'DOWN', _, _, worker_pid, reason) do
    Logger.alert("Process #{worker_pid} crashed, reason: #{reason}")
  end
end
