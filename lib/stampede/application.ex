defmodule Stampede.Application do
  @compile [:bin_opt_info, :recv_opt_info]
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger
  use TypeCheck
  alias Stampede, as: S

  use Application

  @impl Application
  def start(_type, _startup_override_args \\ []) do
    :ok = Logger.metadata(stampede_component: :application)

    startup_args =
      [
        :log_to_file,
        :log_post_serious_errors,
        :error_log_destination,
        :config_dir,
        :clear_state,
        :services_to_install
      ]
      |> Enum.map(fn key ->
        {key, Application.fetch_env!(:stampede, key)}
      end)

    if startup_args[:log_to_file], do: :ok = Logger.add_handlers(:stampede)

    :ok = S.Tables.init(startup_args)

    _ =
      if startup_args[:log_post_serious_errors] do
        case startup_args[:error_log_destination] do
          {error_service, channel_id} ->
            {:ok, _} = LoggerBackends.add(Stampede.Logger)

            Logger.debug(fn ->
              [
                "Errors will be logged to ",
                error_service |> inspect(),
                " at destination ",
                channel_id |> inspect()
              ]
            end)

          :unset ->
            Logger.error("No :error_log_destination configured")

          other ->
            raise "Unknown :error_log_destination  #{inspect(other, pretty: true)}"
        end
      else
        Logger.info(":error_log_destination is false, not posting errors to anywhere")
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    children = make_children(startup_args)
    opts = [strategy: :one_for_one, name: Stampede.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def service_spec(atom) when is_atom(atom) do
    S.services()
    |> Map.fetch!(atom)
  end

  def make_children(startup_args) do
    default_children = [
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Stampede.QuickTaskSupers},
      # NOTE: call with Stampede.quick_task_via()
      {Stampede.CfgTable, config_dir: Keyword.fetch!(startup_args, :config_dir)},
      Stampede.Scheduler
    ]

    service_tuples =
      case Keyword.fetch!(startup_args, :services_to_install) do
        :all ->
          installed = Keyword.fetch!(startup_args, :installed_services)
          Logger.debug("Stampede starting all services: #{inspect(installed)}")
          installed

        name when is_atom(name) ->
          Logger.debug("Stampede starting only #{name}")
          [name]

        list when is_list(list) or is_tuple(list) ->
          Logger.debug("Stampede starting these: #{inspect(list)}")
          list
      end

    default_children ++ service_tuples
  end

  def handle_info(:DOWN, _, _, worker_pid, reason) do
    Logger.alert("Process #{worker_pid |> S.pp()} crashed, reason: #{reason |> S.pp()}")
  end
end
