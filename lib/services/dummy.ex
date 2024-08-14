defmodule Services.Dummy do
  @compile [:bin_opt_info, :recv_opt_info]
  require Logger
  use Supervisor
  use TypeCheck
  use TypeCheck.Defstruct
  alias Services.Dummy, as: D
  alias Stampede, as: S
  require S
  alias S.Events.{MsgReceived, ResponseToPost}
  require MsgReceived

  use Service

  # Imaginary server types
  @type! dummy_user_id :: atom()
  @type! dummy_channel_id :: atom() | nil
  @type! dummy_server_id :: identifier() | atom()
  @type! dummy_msg_id :: integer()
  # "one channel"
  @type! msg_content :: String.t()
  @type! msg_reference :: nil | dummy_msg_id()
  # internal representation of messages
  @type! msg_tuple ::
           {id :: dummy_msg_id(),
            {user :: dummy_user_id(), body :: msg_content(), ref :: msg_reference()}}
  @typedoc """
  Tuple format for adding new messages
  """
  @type! msg_tuple_incoming ::
           {server_id :: dummy_server_id(), channel :: dummy_channel_id(),
            user :: dummy_user_id(), body :: msg_content(), ref :: msg_reference()}
  @type! channel :: list(msg_tuple())
  # multiple channels
  @type! channel_buffers :: %{dummy_channel_id() => channel()} | %{}

  @system_user :server
  @bot_user :stampede

  def system_user, do: @system_user
  def bot_user, do: @bot_user

  @schema NimbleOptions.new!(
            SiteConfig.merge_custom_schema(
              service: [
                default: Services.Dummy,
                type: {:in, [Services.Dummy]}
              ],
              server_id: [
                required: true,
                type: :atom
              ],
              error_channel_id: [
                default: :error,
                type: :atom
              ],
              plugs: [
                default: ["Test", "Sentience"],
                type: {:custom, SiteConfig, :real_plugins, []}
              ],
              vip_ids: [
                default: MapSet.new([@system_user])
              ]
            )
          )
  @moduledoc """
  This service can be used for testing and experimentation, by taking the role
  of a service relaying messages to Stampede.

  It expects one config per service instance, where real services expect one per server.

  SiteConfig/startup args:
  #{NimbleOptions.docs(@schema)}
  """
  def site_config_schema(), do: @schema

  # PUBLIC API FUNCTIONS

  @spec! start_link(Keyword.t()) :: :ignore | {:error, any} | {:ok, pid}
  @impl Service
  def start_link([]) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "dev-facing option for getting bot responses"
  @spec! ask_bot(
           dummy_server_id(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content() | TxtBlock.t(),
           keyword()
         ) ::
           nil
           | %{
               response: nil | ResponseToPost.t(),
               posted_msg_id: dummy_msg_id(),
               bot_response_msg_id: nil | dummy_msg_id()
             }
           | ResponseToPost.t()
  def ask_bot(server_id, channel, user, text, opts \\ []) do
    formatted_text =
      TxtBlock.to_binary(text, D)

    D.Server.ask_bot(server_id, {channel, user, formatted_text, opts[:ref]}, opts)
  end

  def ping(server_id) do
    :pong = D.Server.ping(server_id)
  end

  @impl Service
  def send_msg({server_id, channel, user}, text, opts \\ []),
    do: send_msg(server_id, channel, user, text, opts)

  @spec! send_msg(
           dummy_server_id(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content() | TxtBlock.t(),
           keyword()
         ) :: {:ok, nil}
  def send_msg(server_id, channel, user, formatted_text, opts \\ []) do
    D.Server.add_msg(server_id, {channel, user, formatted_text, opts[:ref]})
  end

  @impl Service
  def format_plugin_fail(
        _cfg = %{service: Services.Dummy},
        msg = %{service: Services.Dummy},
        %{plugin: p, type: t, error: e, stacktrace: st}
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
      inspect(msg.author_id),
      " lead to ",
      error_type,
      " in plugin ",
      inspect(p),
      ":\n\n",
      {:source_block, [Exception.format(t, e, st)]}
      # BUG: can't handle colored text like TypeCheck failures
    ]
  end

  @impl Service
  def log_plugin_error(cfg, msg, error_info) do
    formatted =
      format_plugin_fail(cfg, msg, error_info)

    # NOTE: as this function is generally being called inside a GenServer process, spawning a new thread is required.
    _ =
      Task.start_link(fn ->
        send_msg(
          SiteConfig.fetch!(cfg, :server_id),
          SiteConfig.fetch!(cfg, :error_channel_id),
          @bot_user,
          formatted
          |> TxtBlock.to_binary(__MODULE__)
        )
      end)

    {:ok, formatted}
  end

  def into_msg({id, server_id, channel, user, body, ref}) do
    MsgReceived.new(
      id: id,
      body: body,
      channel_id: channel,
      author_id: user,
      server_id: server_id,
      referenced_msg_id: ref
    )
  end

  @impl Service
  def dm?(_server_id = {:dm, __MODULE__}),
    do: true

  def dm?(%MsgReceived{server_id: {:dm, __MODULE__}}),
    do: true

  def dm?(_other), do: false

  @impl Service
  def author_privileged?(server_id, author_id) do
    D.Server.author_privileged?(server_id, author_id)
  end

  @impl Service
  def at_bot?(_cfg, %{server_id: server_id, channel_id: channel_id, referenced_msg_id: ref}) do
    ((ref || false) &&
       dm?(server_id)) ||
      D.Server.get_msg(server_id, channel_id, ref)
      |> case do
        nil ->
          false

        {user, _msg, _ref} ->
          user |> bot_id?()
      end
  end

  @impl Service
  def bot_id?(id), do: id == @bot_user

  @impl Service
  def txt_format(blk, kind),
    do: TxtBlock.Md.format(blk, kind)

  @spec! channel_history(dummy_server_id(), dummy_channel_id()) :: channel()
  def channel_history(server_id, channel) do
    D.Server.channel_history(server_id, channel)
  end

  @spec! server_dump(dummy_server_id()) :: channel_buffers()
  def server_dump(server_id) do
    D.Server.server_dump(server_id)
    |> Map.new(fn {cid, hist} ->
      {cid, Aja.Enum.with_index(hist, fn val, i -> {i, val} end)}
    end)
  end

  def new_server(cfg_kwlist) when is_list(cfg_kwlist) do
    cfg =
      cfg_kwlist
      |> Keyword.put(:service, :dummy)
      |> SiteConfig.validate!(D.site_config_schema())

    :ok = S.CfgTable.insert_cfg(cfg)

    id = cfg.server_id

    {:ok, _} = DynamicSupervisor.start_child(D.DynSup, {D.Server, server_id: id})

    unless :pong == D.Server.ping(id),
      do: raise("Starting server #{inspect(id)} failed")

    :ok
  end

  @impl Service
  def reload_configs() do
    # GenServer.call(__MODULE__, :reload_configs)
    :ok
  end

  # PLUMBING

  @impl Supervisor
  @spec! init(Keyword.t()) :: {:ok, nil}
  def init(opts) do
    children = [
      {DynamicSupervisor, name: D.DynSup},
      {Registry, name: D.Registry, keys: :unique, partitions: System.schedulers_online()}
    ]

    Supervisor.init(children, opts)
  end
end
