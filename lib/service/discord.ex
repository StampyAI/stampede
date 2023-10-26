defmodule Service.Discord do
  alias Stampede, as: S
  use TypeCheck
  use Supervisor, restart: :permanent
  require Logger
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

  @character_limit 1999
  @consecutive_msg_limit 10

  def send_msg(channel_id, msg) when is_bitstring(msg) do
    for chunk <-
          S.text_split(msg, @character_limit, @consecutive_msg_limit) do
      do_send_msg(channel_id, chunk)
    end
  end

  def do_send_msg(channel_id, msg, try \\ 0) do
    case Nostrum.Api.create_message(
           channel_id,
           content: msg
         ) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        if try < 5 do
          IO.puts(
            :stderr,
            "send_msg: discord message send failure ##{try}, error #{inspect(e, pretty: true)}. Trying again..."
          )

          do_send_msg(channel_id, msg, try + 1)
        else
          IO.puts(:stderr, "send_msg: gave up trying to send message. Nothing else to do.")
        end
    end
  end

  def log_serious_error(log_msg = {level, _gl, {Logger, message, _timestamp, _metadata}}) do
    # TODO: disable if Discord not connected/working
    IO.puts("log_serious_error recieved:\n#{inspect(log_msg, pretty: true)}")
    channel_id = Application.fetch_env!(:stampede, :serious_error_channel_id)

    send_msg(
      channel_id,
      "Erlang-level error #{inspect(level)}:\n#{inspect(message, pretty: true)}"
    )
  end

  def log_plugin_error(cfg, log) do
    channel_id = SiteConfig.fetch!(cfg, :error_channel_id)

    _ =
      Nostrum.Api.create_message(
        channel_id,
        content: log
      )

    :ok
  end

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    Logger.metadata(stampede_component: :discord)

    children = [
      Nostrum.Application,
      {Service.Discord.Handler, args},
      Service.Discord.Consumer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Service.Discord.Handler do
  use TypeCheck
  use TypeCheck.Defstruct
  use GenServer
  require Logger
  alias Stampede, as: S
  alias S.{Response, Msg}
  require Msg
  alias Nostrum.Api

  defstruct!(guild_ids: _ :: %MapSet{})

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(args) do
    settings =
      struct!(
        __MODULE__,
        Keyword.put_new(args, :guild_ids, S.CfgTable.servers_configured(Service.Discord))
      )

    {:ok, settings}
  end

  @impl GenServer
  @spec! handle_cast({:MESSAGE_CREATE, %Nostrum.Struct.Message{}}, %__MODULE__{}) ::
           {:noreply, any()}
  def handle_cast({:MESSAGE_CREATE, msg}, state) do
    if msg.guild_id in state.guild_ids do
      our_msg =
        Msg.new(
          body: msg.content,
          channel_id: msg.channel_id,
          author_id: msg.author.id,
          server_id: msg.guild_id
        )

      case Plugin.get_top_response(msg.guild_id, our_msg) do
        %Response{text: r_text} when r_text != nil ->
          Api.create_message(msg.channel_id, r_text)

        nil ->
          :do_nothing
      end

      {:noreply, state}
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
    _ =
      case event do
        {:MESSAGE_CREATE, msg, _ws_state} ->
          if msg.content == "!int" do
            raise "aw nah"
          end

          GenServer.cast(Service.Discord.Handler, {:MESSAGE_CREATE, msg})

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
    backend_env = [level: Application.get_env(:logger, __MODULE__, :warning)]
    {:ok, backend_env}
  end

  @impl :gen_event
  @spec! handle_event(any(), logger_state()) :: {:ok, logger_state()}
  def handle_event(log_msg = {level, gl, {Logger, _message, _timestamp, _metadata}}, state)
      when node(gl) == node() do
    IO.puts("Event level #{inspect(level)}, state level #{inspect(state[:level])}")

    _ =
      case Logger.compare_levels(level, state[:level]) do
        :lt ->
          IO.puts("#{inspect(level)} < #{inspect(state[:level])}")
          nil

        _ ->
          IO.puts("#{inspect(level)} >= #{inspect(state[:level])}")

          try do
            Service.Discord.log_serious_error(log_msg)
          catch
            _type, _error ->
              # NOTE: give up. what are we gonna do, throw another error?
              :nothing
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
