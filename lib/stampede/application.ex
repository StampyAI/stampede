defmodule Stampede.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger
  use TypeCheck
  alias Stampede, as: S

  use Application

  def startup_schema() do
    NimbleOptions.new!(
      installed_services: [
        type: {:or, [{:in, [[]]}, {:list, {:in, Map.keys(S.services())}}]},
        required: true,
        doc: "Services installed as part of the mix project. Passed in from mix.exs"
      ],
      services: [
        type: {:or, [{:in, [:none, :all]}, {:list, {:in, Map.keys(S.services())}}]},
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
      ],
      serious_error_channel_service: [
        type: {:or, [:atom, nil]},
        default: nil,
        doc: "What service should handle serious errors?"
      ],
      node_name: [
        type: :atom,
        default: "stampede_#{Mix.env()}@#{:inet.gethostname() |> elem(1)}" |> String.to_atom(),
        doc: "erlang VM node name"
      ],
      clear_state: [
        type: :boolean,
        default: false,
        doc: "clear tables associated with this environment"
      ]
    )
  end

  @impl Application
  def start(_type, startup_override_args \\ []) do
    :ok = Logger.metadata(stampede_component: :application)

    # first validation fills defaults
    startup_args =
      NimbleOptions.validate!(startup_override_args, startup_schema())
      |> S.keyword_put_new_if_not_falsy(
        :services,
        Application.get_env(:stampede, :services, false)
      )
      |> S.keyword_put_new_if_not_falsy(
        :config_dir,
        Application.get_env(:stampede, :config_dir, false)
      )
      |> Keyword.update!(:config_dir, fn dir ->
        dir <> "_#{Application.fetch_env!(:stampede, :compile_env)}"
      end)
      |> Keyword.update!(
        :serious_error_channel_service,
        fn setting ->
          if setting == nil do
            Application.get_env(:stampede, :serious_error_channel_service, nil)
          else
            setting
          end
        end
      )
      # ensure our transformation went correctly
      |> NimbleOptions.validate!(startup_schema())

    if startup_args[:log_to_file], do: :ok = Logger.add_handlers(:stampede)

    ## changing node names after boot confuses Mnesia :(
    # {:ok, _} = if Node.self() == :nonode@nohost,
    #  do: Node.start(startup_args[:node_name])

    children = make_children(startup_args)

    _ =
      case startup_args[:serious_error_channel_service] do
        nil ->
          Logger.error("No :serious_error_channel_service configured")

        :disabled ->
          Logger.info(":serious_error_channel_service disabled")

        :discord ->
          Logger.info("Discord handling :serious_error_channel_service")
          {:ok, _} = LoggerBackends.add(Service.Discord.Logger)

        # :ok = :logger.add_handler(:error_man, Service.Discord.Logger, [])
        other ->
          Logger.error("Unknown :serious_error_channel_service #{inspect(other)}")
      end

    # TODO: move activation into service modules themselves

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Stampede.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def service_spec(atom) when is_atom(atom) do
    S.services()
    |> Map.fetch!(atom)
  end

  def all_services(installed) do
    installed |> Enum.map(&service_spec(&1))
  end

  def make_children(startup_args) do
    default_children = [
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Stampede.QuickTaskSupers},
      # NOTE: call with Stampede.quick_task_via()
      Stampede.TableIds,
      {Stampede.CfgTable, config_dir: Keyword.fetch!(startup_args, :config_dir)},
      {Stampede.Interact, wipe_tables: Keyword.fetch!(startup_args, :clear_state)}
    ]

    service_tuples =
      case Keyword.fetch!(startup_args, :services) do
        :all ->
          installed = Keyword.fetch!(startup_args, :installed_services)
          Logger.debug("Stampede starting all services: #{inspect(installed)}")
          all_services(installed)

        :none ->
          Logger.debug("Stampede starting no services")
          []

        name when is_atom(name) ->
          Logger.debug("Stampede starting only #{name}")
          [service_spec(name)]

        list when is_list(list) or is_tuple(list) ->
          Logger.debug("Stampede starting these: #{inspect(list)}")
          Enum.map(list, &service_spec(&1))
      end

    default_children ++ service_tuples
  end

  def handle_info(:DOWN, _, _, worker_pid, reason) do
    Logger.alert("Process #{worker_pid |> S.pp()} crashed, reason: #{reason |> S.pp()}")
  end
end
