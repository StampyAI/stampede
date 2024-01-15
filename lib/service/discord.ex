defmodule Service.Discord do
  alias Stampede, as: S
  alias S.{Msg, Channel}
  use TypeCheck
  use Supervisor, restart: :permanent
  require Logger

  use Service

  @type! discord_channel_id :: non_neg_integer()
  @type! discord_guild_id :: non_neg_integer()
  @type! discord_user_id :: non_neg_integer()
  @type! discord_msg_id :: non_neg_integer()

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

  @impl Service
  def into_msg(msg) do
    Msg.new(
      id: msg.id,
      body: msg.content,
      channel_id: msg.channel_id,
      author_id: msg.author.id,
      server_id: msg.guild_id,
      referenced_msg_id: Map.get(msg, :referenced_msg, nil)
    )
  end

  @impl Service
  def send_msg(channel_id, msg, _opts \\ []) when is_bitstring(msg) do
    r = S.text_chunk_regex(@character_limit)

    for chunk <-
          S.text_chunk(msg, @character_limit, @consecutive_msg_limit, r) do
      do_send_msg(channel_id, chunk)
    end
    |> Enum.reduce(:all_good, fn
      _, s when s != :all_good ->
        s

      {:ok, _}, :all_good ->
        :all_good

      e = {:error, _}, :all_good ->
        e
    end)
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
          {:error, e}
        end
    end
  end

  @impl Service
  def log_serious_error(log_msg = {level, _gl, {Logger, message, _timestamp, _metadata}}) do
    try do
      # TODO: disable if Discord not connected/working
      IO.puts("log_serious_error recieved:\n#{inspect(log_msg, pretty: true)}")
      channel_id = Application.fetch_env!(:stampede, :serious_error_channel_id)

      log =
        """
        Erlang-level error #{inspect(level)}:
        #{message |> S.pp() |> txt_source_block()}
        """

      _ = send_msg(channel_id, log)
    catch
      t, e ->
        IO.puts("""
        ERROR: Logging serious error to Discord failed. We have no option, and resending would probably cause an infinite loop.

        Here's the error:
        #{S.pp({t, e})}
        """)
    end

    :ok
  end

  @impl Service
  def log_plugin_error(cfg, log) do
    channel_id = SiteConfig.fetch!(cfg, :error_channel_id)

    _ =
      Nostrum.Api.create_message(
        channel_id,
        content: log
      )

    :ok
  end

  @impl Service
  def txt_source_block(txt) when is_binary(txt) do
    """
    ```
    #{txt}
    ```
    """
  end

  @spec! get_referenced_msg(Msg.t()) :: {:ok, Msg.t()} | {:error, any()}
  def get_referenced_msg(msg) do
    get_msg({
      msg.channel_id,
      msg.referenced_msg_id
    })
  end

  @spec! get_msg({discord_channel_id(), discord_msg_id()}) :: {:ok, Msg.t()} | {:error, any()}
  def get_msg({channel_id, msg_id}) do
    case Nostrum.Api.get_channel_message(channel_id, msg_id) do
      {:ok, discord_msg} ->
        {:ok, into_msg(discord_msg)}

      other ->
        {:error, other}
    end
  end

  @impl Service
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

  @impl Service
  def reload_configs() do
    GenServer.call(Service.Discord.Handler, :reload_configs)
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
    new_state =
      struct!(
        __MODULE__,
        Keyword.put_new(args, :guild_ids, S.CfgTable.servers_configured(Service.Discord))
      )

    {:ok, new_state}
  end

  def handle_call(:reload_configs, state) do
    # TODO: harden this
    new_state =
      struct!(
        __MODULE__,
        Keyword.put_new(state, :guild_ids, S.CfgTable.servers_configured(Service.Discord))
      )

    {:reply, :ok, new_state}
  end

  @impl GenServer
  @spec! handle_cast({:MESSAGE_CREATE, %Nostrum.Struct.Message{}}, %__MODULE__{}) ::
           {:noreply, any()}
  def handle_cast({:MESSAGE_CREATE, msg}, state) do
    if msg.guild_id in state.guild_ids do
      our_cfg = S.CfgTable.get_server(Service.Discord, msg.guild_id)

      our_msg =
        Service.Discord.into_msg(msg)

      case Plugin.get_top_response(our_cfg, our_msg) do
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
    _ =
      case Logger.compare_levels(level, state[:level]) do
        :lt ->
          nil

        _ ->
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
