defmodule Service.Discord do
  alias Stampede, as: S
  use TypeCheck
  use Supervisor
  @type! discord_channel_id :: non_neg_integer()
  @type! discord_guild_id :: non_neg_integer()
  @type! discord_user_id :: non_neg_integer()

  # @behaviour Service

  # @impl Service
  # def should_start(_config) do
  #  case Application.get_env(:nostrum, :token, nil) do
  #    nil -> false
  #    _ -> true
  #  end
  # end
  # @impl Service
  def log_error(
        discord_channel_id,
        _log_msg = {level, _gl, {Logger, message, _timestamp, _metadata}}
      ) do
    # TODO: disable if Discord not connected/working
    return =
      Nostrum.Api.create_message(
        discord_channel_id,
        content: "#{level}: #{message}"
      )

    return
  end

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(_args) do
    Logger.metadata(stampede_component: :discord)

    children = [
      Nostrum.Application,
      Service.Discord.Consumer
    ]

    {:ok, _} = LoggerBackends.add(Service.Discord.Logger)

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Service.Discord.Consumer do
  use TypeCheck
  use Nostrum.Consumer

  alias Nostrum.Api

  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    # TODO: use msg.guild_id to find config. If cfg.shy is enabled, prefix
    # check should be done before sending anything at all to other processes.
    # Also label :interaction_id logger metadata
    case msg.content do
      "!ping" ->
        {:ok, Api.create_message(msg.channel_id, content: "pong!")}

      "!throw" ->
        raise "intentional fail!"

      _ ->
        :ignore
    end
  end

  # Default event handler, if you don't include this, your consumer WILL crash if
  # you don't have a method definition for each event type.
  def handle_event(_event) do
    :noop
  end
end

defmodule Service.Discord.Logger do
  use TypeCheck
  @behaviour :gen_event
  # alias Stampede, as: S
  @type! logger_state :: Keyword.t()

  def start_link() do
    :gen_event.start_link({:local, __MODULE__})
  end

  @impl :gen_event
  @spec! init(any()) :: {:ok, logger_state()}
  def init(_) do
    backend_env = Application.get_env(:logger, __MODULE__, level: :warning)
    {:ok, backend_env}
  end

  @impl :gen_event
  @spec! handle_event(any(), logger_state()) :: {:ok, logger_state()}
  def handle_event(log_msg = {level, gl, {Logger, _message, _timestamp, _metadata}}, state)
      when node(gl) == node() do
    _ =
      cond do
        Logger.compare_levels(level, state[:level]) == :lt ->
          nil

        # HACK: hardcoded channel
        true ->
          Application.fetch_env!(:stampede, :error_channel_id)
          |> Service.Discord.log_error(log_msg)
      end

    {:ok, state}
  end

  # NOTE: mandatory default handler, removing will crash
  def handle_event({_, gl, {_, _, _, _}}, state)
      when node(gl) != node(),
      do: {:ok, state}

  def handle_event(_, state), do: {:ok, state}

  @impl :gen_event
  def handle_call({:configure, options}, state) do
    {:ok, :ok, Keyword.merge(state, options)}
  end
end
