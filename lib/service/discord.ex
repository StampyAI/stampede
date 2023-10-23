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

  @doc """
  For communication between Handler (which knows configured guilds), and Consumer (which knows only what messages it gets)
  """
  def via(guild_id) when is_integer(guild_id) do
    String.to_atom("Discord_" <> Integer.to_string(guild_id))
  end

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
  def init(args) do
    Logger.metadata(stampede_component: :discord)

    children = [
      Nostrum.Application,
      Service.Discord.Consumer,
      {Service.Discord.Handler, args}
    ]

    # {:ok, _} = LoggerBackends.add(Service.Discord.Logger)

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Service.Discord.Handler do
  use TypeCheck
  use TypeCheck.Defstruct
  use GenServer
  require Logger
  alias Nostrum.Api
  alias Stampede, as: S

  defstruct!(
    app_id: _ :: any(),
    guild_ids: _ :: %MapSet{}
  )

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    app_id = Keyword.fetch!(args, :app_id)

    settings =
      struct!(
        __MODULE__,
        Keyword.put_new(args, :guild_ids, S.CfgTable.servers_configured(app_id, Service.Discord))
      )

    for id <- settings.guild_ids do
      Process.register(self(), Service.Discord.via(id))
    end

    {:ok, settings}
  end

  @impl GenServer
  @spec! handle_cast({:MESSAGE_CREATE, %Nostrum.Struct.Message{}}, %__MODULE__{}) ::
           {:noreply, any()}
  def handle_cast({:MESSAGE_CREATE, msg}, state) do
    if msg.guild_id in state.guild_ids do
      case msg.content do
        "!ping" ->
          Api.create_message(msg.channel_id, content: "pong!")
          {:noreply, state}

        "!throw" ->
          raise "intentional fail!"

        _ ->
          {:noreply, state}
      end
    else
      Logger.error("guild #{msg.guild_id} NOT found in #{inspect(state.guild_ids)}")
      {:noreply, state}
    end
  end
end

defmodule Service.Discord.Consumer do
  @moduledoc """
  Handles Nostrum's business while passing off jobs to Handler
  """
  # NOTE: can Consumer and Handler be merged? I don't see how to get around Nostrum's exclusive state.
  use Nostrum.Consumer
  use TypeCheck

  @impl GenServer
  def handle_info({:event, event}, state) do
    case event do
      {:MESSAGE_CREATE, msg, _ws_state} ->
        GenServer.cast(Service.Discord.via(msg.guild_id), {:MESSAGE_CREATE, msg})

      other ->
        Task.start_link(__MODULE__, :handle_event, [other])
    end

    {:noreply, state}
  end

  # Default event handler, if you don't include this, your consumer WILL crash if
  # you don't have a method definition for each event type.
  def handle_event(_event), do: :noop
end

defmodule Service.Discord.Logger do
  @doc """
  Listens for global errors raised from Erlang's logger system. If an error gets thrown in this module or children it would cause an infinite loop.
  """
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
    if Application.fetch_env!(:stampede, :error_channel_service) == :discord do
      _ =
        case Logger.compare_levels(level, state[:level]) do
          :lt ->
            nil

          _ ->
            channel_id = Application.fetch_env!(:stampede, :error_channel_id)

            try do
              Service.Discord.log_error(channel_id, log_msg)
            catch
              _type, _error ->
                # NOTE: give up. what are we gonna do, throw another error?
                :nothing
            end
        end
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
