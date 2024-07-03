defmodule Stampede.Application do
  @compile [:bin_opt_info, :recv_opt_info]
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
      # installed_foreign_plugins: [
      #   type: {:or, [{:in, [[]]}, {:list, {:in, Map.values(S.services())}}]},
      #   required: true,
      #   doc: "Foreign Plugin sources installed as part of the mix project. Passed in from mix.exs"
      # ],
      services: [
        type: {:or, [{:in, [:all]}, {:list, {:in, Map.keys(S.services())}}]},
        default: :all,
        doc: "what will actually be started by Stampede"
      ],
      config_dir: [
        type: :string,
        default: "./Sites",
        doc: "Will be read from :stampede/:config_dir if unset"
      ],
      log_to_file: [
        type: :boolean,
        default: true,
        doc: "enable file logging"
      ],
      log_post_serious_errors: [
        type: :boolean,
        default: true,
        doc: "enable posting serious errors to the channel specified in :error_log_destination"
      ],
      clear_state: [
        type: :boolean,
        default: false,
        doc: "clear tables associated with this compilation environment"
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
        dir <> "_#{Stampede.compilation_environment()}"
      end)
      # ensure our transformation went correctly
      |> NimbleOptions.validate!(startup_schema())

    if startup_args[:log_to_file], do: :ok = Logger.add_handlers(:stampede)

    :ok = S.Tables.init(startup_args)

    _ =
      if startup_args[:log_post_serious_errors] do
        case Application.get_env(:stampede, :error_log_destination, :unset) do
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

    # TODO: move activation into service modules themselves

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

  def all_services(installed) do
    installed |> Enum.map(&service_spec(&1))
  end

  def make_children(startup_args) do
    default_children = [
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Stampede.QuickTaskSupers},
      # NOTE: call with Stampede.quick_task_via()
      {Stampede.CfgTable, config_dir: Keyword.fetch!(startup_args, :config_dir)},
      Stampede.Scheduler
    ]

    service_tuples =
      case Keyword.fetch!(startup_args, :services) do
        :all ->
          installed = Keyword.fetch!(startup_args, :installed_services)
          Logger.debug("Stampede starting all services: #{inspect(installed)}")
          all_services(installed)

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
