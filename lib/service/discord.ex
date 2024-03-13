defmodule Service.Discord do
  alias Stampede, as: S
  alias S.{Msg}
  require Msg
  use TypeCheck
  use Supervisor, restart: :permanent
  require Logger

  use Service

  @moduledoc """
  Connect to one or more Discord servers.
  Config options:
  #{NimbleOptions.docs(@site_config_schema, nest_level: 1)}
  """

  @type! discord_channel_id :: non_neg_integer()
  @type! discord_guild_id :: non_neg_integer()
  @type! discord_author_id :: non_neg_integer()
  @type! discord_msg_id :: non_neg_integer()

  @character_limit 1999
  @consecutive_msg_limit 10

  @impl Service
  def into_msg(msg) do
    Msg.new(
      id: msg.id,
      body: msg.content,
      channel_id: msg.channel_id,
      author_id: msg.author.id,
      server_id: msg.guild_id || {:dm, __MODULE__},
      referenced_msg_id: Map.get(msg, :referenced_msg, nil)
    )
  end

  @impl Service
  def send_msg(channel_id, msg, opts \\ [])

  def send_msg(channel_id, msg, opts) when is_list(msg),
    do: send_msg(channel_id, msg |> IO.iodata_to_binary(), opts)

  def send_msg(channel_id, msg, _opts) when is_binary(msg) do
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
            [
              "send_msg: discord message send failure ##",
              try,
              ", error ",
              e |> S.pp(),
              ". Trying again..."
            ]
          )

          :ok = Process.sleep(500)

          do_send_msg(channel_id, msg, try + 1)
        else
          IO.puts(:stderr, "send_msg: gave up trying to send message. Nothing else to do.")
          {:error, e}
        end
    end
  end

  @impl Service
  def format_plugin_fail(
        _cfg,
        msg = %{service: Service.Discord},
        %PluginCrashInfo{plugin: p, type: t, error: e, stacktrace: st}
      ) do
    error_type =
      case t do
        :error ->
          "an error"

        :throw ->
          "a throw"
      end

    [
      "Message from ",
      msg.author_id |> Nostrum.Api.get_user!() |> Nostrum.Struct.User.full_name() |> inspect(),
      " lead to ",
      error_type,
      " in plugin ",
      inspect(p),
      ":\n\n",
      {:source_block, [S.pp(e), "\n", S.pp(st)]}
    ]
  end

  @impl Service
  def log_plugin_error(cfg, msg, error_info) do
    channel_id = SiteConfig.fetch!(cfg, :error_channel_id)
    formatted = format_plugin_fail(cfg, msg, error_info)

    _ =
      spawn(fn ->
        _ =
          send_msg(
            channel_id,
            formatted
          )
      end)

    {:ok, formatted}
  end

  @impl Service
  def log_serious_error(log_msg = {level, _gl, {Logger, message, _timestamp, _metadata}}) do
    try do
      # TODO: disable if Discord not connected/working
      IO.puts(["log_serious_error recieved:\n", inspect(log_msg, pretty: true)])
      channel_id = Application.fetch_env!(:stampede, :serious_error_channel_id)

      log = [
        "Erlang-level error ",
        inspect(level),
        "\n",
        message
        |> TxtBlock.to_str_list(Service.Discord)
        |> Service.Discord.txt_format(:source_block)
      ]

      _ = send_msg(channel_id, log)
    catch
      t, e ->
        IO.puts([
          """
          ERROR: Logging serious error to Discord failed. We have no option, and resending would probably cause an infinite loop.

          Here's the error:
          """,
          S.pp({t, e})
        ])
    end

    :ok
  end

  @impl Service
  def reload_configs() do
    GenServer.call(__MODULE__.Handler, :reload_configs)
  end

  @impl Service
  def author_is_privileged(server_id, author_id) do
    GenServer.call(__MODULE__.Handler, {:author_is_privileged, server_id, author_id})
  end

  @impl Service
  def txt_format(blk, kind),
    do: TxtBlock.Md.format(blk, kind)

  def is_dm(msg), do: msg.guild_id == nil

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
      {__MODULE__.Handler, args},
      __MODULE__.Consumer
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
  alias Service.Discord

  @typep! vips :: S.CfgTable.vips()

  defstruct!(
    guild_ids: _ :: %MapSet{},
    vip_ids: _ :: vips()
  )

  @spec! is_vip_in_this_context(vips(), Discord.discord_guild_id(), Discord.discord_author_id()) ::
           boolean()
  def is_vip_in_this_context(vips, server_id, author_id),
    do: S.is_vip_in_this_context(vips, server_id, author_id)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    new_state = update_state()

    {:ok, new_state}
  end

  @spec! update_state() :: %__MODULE__{}
  defp update_state() do
    struct!(
      __MODULE__,
      guild_ids: S.CfgTable.servers_configured(Discord),
      vip_ids: S.CfgTable.vips_configured(Discord)
    )
  end

  @spec! update_state(%__MODULE__{}) :: %__MODULE__{}
  defp update_state(state) do
    state
    |> Map.put(:guild_ids, S.CfgTable.servers_configured(Discord))
    |> Map.put(:vip_ids, S.CfgTable.vips_configured(Discord))
  end

  @impl GenServer
  def handle_call(:reload_configs, _, state) do
    # TODO: harden this
    new_state = update_state(state)

    {:reply, :ok, new_state}
  end

  def handle_call({:author_is_privileged, server_id, author_id}, _from, state) do
    {
      :reply,
      is_vip_in_this_context(state.vip_ids, server_id, author_id),
      state
    }
  end

  @impl GenServer
  @spec! handle_cast({:MESSAGE_CREATE, %Nostrum.Struct.Message{}}, %__MODULE__{}) ::
           {:noreply, any()}
  def handle_cast({:MESSAGE_CREATE, discord_msg}, state) do
    case Nostrum.Cache.Me.get() do
      author when discord_msg.author.id == author.id ->
        # This is our own message, do nothing
        nil

      nil ->
        raise "We don't know our own identity. This should never happen"

      _ ->
        # Message from somebody else
        cond do
          discord_msg.guild_id in state.guild_ids ->
            do_msg_create(discord_msg)

          Discord.is_dm(discord_msg) ->
            if is_vip_in_this_context(state.vip_ids, discord_msg.guild_id, discord_msg.author.id) do
              do_msg_create(discord_msg)
            else
              Logger.warning(fn ->
                [
                  "User wanted to DM but is not in vip_ids. \\\n",
                  "Username: ",
                  discord_msg.author |> Nostrum.Struct.User.full_name() |> inspect(),
                  " \\\n",
                  "Message:\n",
                  {:quote_block, discord_msg.content} |> TxtBlock.to_str_list(Service.Discord)
                ]
              end)
            end

          true ->
            Logger.error(fn ->
              [
                "guild ",
                discord_msg.guild_id |> inspect(),
                " NOT found in ",
                inspect(state.guild_ids)
              ]
            end)
        end
    end

    {:noreply, state}
  end

  defp do_msg_create(discord_msg) do
    our_msg =
      Discord.into_msg(discord_msg)

    our_cfg = S.CfgTable.get_cfg!(Discord, our_msg.server_id)

    case Plugin.get_top_response(our_cfg, our_msg) do
      %Response{text: r_text} when r_text != nil ->
        Api.create_message(our_msg.channel_id, r_text)

      nil ->
        :do_nothing
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

  # TODO: turn into service-generic Stampede.Logger

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
