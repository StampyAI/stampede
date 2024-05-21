defmodule Service.Discord do
  alias Stampede, as: S
  alias S.{Msg}
  alias Nostrum.Api
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

  def into_msg(svc_msg) do
    Msg.new(
      id: svc_msg.id,
      body: svc_msg.content,
      channel_id: svc_msg.channel_id,
      author_id: svc_msg.author.id,
      server_id: get_server_id(svc_msg),
      referenced_msg_id:
        svc_msg
        |> Map.get(:message_reference)
        |> then(&(&1 && Map.get(&1, :message_id)))
    )
  end

  defp get_server_id(svc_msg) do
    if dm?(svc_msg) do
      S.make_dm_tuple(__MODULE__)
    else
      svc_msg.guild_id
    end
  end

  @impl Service
  def at_bot?(_cfg, msg) do
    if msg.referenced_msg_id == nil do
      false
    else
      Api.get_channel_message(msg.channel_id, msg.referenced_msg_id)
      |> case do
        {:ok, service_msg} ->
          bot_id?(service_msg.author.id)

        other ->
          raise "Message at channel #{inspect(msg.channel_id)} id #{inspect(msg.id)} not found. Instead we got: #{S.pp(other)}"
      end
    end
  end

  @impl Service
  def bot_id?(id) do
    case Nostrum.Cache.Me.get() do
      %{id: bot_id} ->
        id == bot_id

      nil ->
        raise "We don't know our own identity. This should never happen"
    end
  end

  @impl Service
  def send_msg(channel_id, msg, opts \\ [])

  def send_msg(channel_id, msg, opts) when not is_binary(msg),
    do: send_msg(channel_id, msg |> TxtBlock.to_binary(__MODULE__), opts)

  def send_msg(channel_id, msg, _opts) when is_binary(msg) do
    r = S.text_chunk_regex(@character_limit)

    for chunk <-
          S.text_chunk(msg, @character_limit, @consecutive_msg_limit, r) do
      do_send_msg(channel_id, chunk)
    end
    |> Enum.reduce(nil, fn
      {:ok, id}, nil ->
        {:ok, first_id: id}

      {:ok, _new_id}, state = {:ok, _first_id} ->
        # Only return the first ID
        state

      e = {:error, _}, _ ->
        e
    end)
  end

  defp api_create_message(channel_id, opts) do
    case :persistent_term.get({__MODULE__, :mock_api}, nil) do
      nil ->
        Api.create_message(channel_id, opts)

      :fail ->
        {:error, :mock_forced_failure}

      other ->
        raise "Not implemented: #{other |> inspect()}"
    end
  end

  def do_send_msg(channel_id, msg),
    do: do_send_msg(channel_id, msg, 10, 0, DateTime.utc_now() |> DateTime.add(1, :second))

  def do_send_msg(channel_id, msg, max_tries, try, timeout) do
    if DateTime.after?(DateTime.utc_now(), timeout) do
      IO.puts(:stderr, "Discord do_send_msg: timeout")
      {:error, :timeout}
    else
      case api_create_message(
             channel_id,
             content: msg
           ) do
        {:ok, %{id: id}} ->
          {:ok, id}

        {:error, e} ->
          if try < max_tries do
            # exponential backoff
            time_to_wait = 10 * Integer.pow(2, try)

            IO.puts(
              :stderr,
              [
                "Discord do_send_msg: send failure #",
                try |> to_string(),
                ", error ",
                e |> S.pp(),
                ". Trying again in ",
                time_to_wait |> to_string(),
                "ms..."
              ]
            )

            :ok = Process.sleep(time_to_wait)

            do_send_msg(channel_id, msg, max_tries, try + 1, timeout)
          else
            IO.puts(
              :stderr,
              "Discord do_send_msg: gave up trying to send message. Nothing else to do."
            )

            {:error, e}
          end
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
      msg.author_id |> Api.get_user!() |> Nostrum.Struct.User.full_name() |> inspect(),
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
  def log_serious_error({level, _gl, {Logger, message, _timestamp, metadata}}) do
    if not metadata[:stampede_already_logged] do
      try do
        # TODO: disable if Discord not connected/working
        IO.puts("log_serious_error recieved by Discord")
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
    end

    :ok
  end

  @impl Service
  def reload_configs() do
    GenServer.call(__MODULE__.Handler, :reload_configs)
  end

  @impl Service
  def author_privileged?(server_id, author_id) do
    GenServer.call(__MODULE__.Handler, {:author_privileged?, server_id, author_id})
  end

  @impl Service
  def txt_format(blk, kind),
    do: TxtBlock.Md.format(blk, kind)

  @impl Service
  def dm?(%Nostrum.Struct.Message{guild_id: gid}), do: gid == nil
  def dm?(%S.Msg{server_id: {:dm, __MODULE__}}), do: true
  def dm?(%S.Msg{server_id: _}), do: false

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
  alias Service.Discord

  @typep! vips :: S.CfgTable.vips()

  defstruct!(
    guild_ids: _ :: %MapSet{},
    vip_ids: _ :: vips()
  )

  @spec! vip_in_this_context?(
           vips(),
           Discord.discord_guild_id() | nil,
           Discord.discord_author_id()
         ) ::
           boolean()
  def vip_in_this_context?(vips, nil, author_id),
    do: S.vip_in_this_context?(vips, S.make_dm_tuple(Service.Discord), author_id)

  def vip_in_this_context?(vips, server_id, author_id),
    do: S.vip_in_this_context?(vips, server_id, author_id)

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

  def handle_call({:author_privileged?, server_id, author_id}, _from, state) do
    {
      :reply,
      vip_in_this_context?(state.vip_ids, server_id, author_id),
      state
    }
  end

  @impl GenServer
  @spec! handle_cast({:MESSAGE_CREATE, %Nostrum.Struct.Message{}}, %__MODULE__{}) ::
           {:noreply, any()}
  def handle_cast({:MESSAGE_CREATE, discord_msg}, state) do
    if Discord.bot_id?(discord_msg.author.id) do
      # ignore our own messages
      nil
    else
      cond do
        discord_msg.guild_id in state.guild_ids ->
          :ok = do_msg_create(discord_msg)

        Discord.dm?(discord_msg) ->
          if vip_in_this_context?(state.vip_ids, discord_msg.guild_id, discord_msg.author.id) do
            :ok = do_msg_create(discord_msg)
          else
            Logger.warning(fn ->
              [
                "User wanted to DM but is not in vip_ids.\n",
                "Username: ",
                discord_msg.author |> Nostrum.Struct.User.full_name() |> inspect(),
                "\n",
                "Message:\n",
                {:quote_block, discord_msg.content} |> TxtBlock.to_str_list(Service.Discord)
              ]
            end)
          end

        true ->
          Logger.error(fn ->
            [
              "guild ",
              inspect(discord_msg.guild_id),
              " NOT found in ",
              inspect(state.guild_ids)
            ]
          end)
      end
    end

    {:noreply, state}
  end

  defp do_msg_create(discord_msg) do
    our_cfg =
      S.CfgTable.get_cfg!(Discord, discord_msg.guild_id || S.make_dm_tuple(Service.Discord))

    inciting_msg_with_context =
      discord_msg
      |> Discord.into_msg()
      |> S.Msg.add_context(our_cfg)

    case Plugin.get_top_response(our_cfg, inciting_msg_with_context) do
      {%Response{text: r_text}, iid} when r_text != nil ->
        {:ok, first_id: bot_response_msg_id} =
          Discord.send_msg(inciting_msg_with_context.channel_id, r_text)

        S.Interact.finalize_interaction(iid, bot_response_msg_id)

      nil ->
        :do_nothing
    end

    :ok
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
