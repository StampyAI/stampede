defmodule Services.Dummy.Table do
  @moduledoc false
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  alias Stampede.Events.MsgReceived
  alias Stampede.Events.ResponseToPost
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:id, :datetime, :server_id, :channel, :user, :body, :referenced_msg_id],
    type: :ordered_set,
    access_mode: :read_write,
    autoincrement: true,
    index: [:datetime]

  def new(record) when is_map(record) do
    record
    |> Map.put_new(:id, nil)
    |> Map.put_new(:datetime, S.time())
    |> then(&struct!(__MODULE__, &1 |> Map.to_list()))
  end

  def validate!(record) when is_struct(record, __MODULE__) do
    record
    # |> TypeCheck.conforms!(%__MODULE__{
    #   id: nil | integer(),
    #   datetime: S.timestamp(),
    #   server_id: atom(),
    #   channel: atom(),
    #   user: atom(),
    #   body: any(),
    #   referenced_msg_id: nil | integer()
    # })
  end
end

defmodule Services.Dummy do
  @compile [:bin_opt_info, :recv_opt_info]
  # TODO: this is not actually parallelized meaning it can't be used in benchmarks
  # Maybe it should be a supervisor with a process for each thread?
  require Logger
  use GenServer
  use TypeCheck
  use TypeCheck.Defstruct
  alias Services.Dummy
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

  defstruct!(
    servers: _ :: MapSet.t(atom()),
    vip_ids: _ :: S.CfgTable.vips()
  )

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
  def start_link(cfg_overrides \\ []) do
    Logger.debug("starting Dummy GenServer, with cfg overrides: #{inspect(cfg_overrides)}")
    GenServer.start_link(__MODULE__, cfg_overrides, name: __MODULE__)
  end

  @doc "dev-facing option for getting bot responses"
  @spec! ask_bot(
           dummy_server_id(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content() | TxtBlock.t(),
           keyword()
         ) ::
           %{
             response: nil | ResponseToPost.t(),
             posted_msg_id: dummy_msg_id(),
             bot_response_msg_id: nil | dummy_msg_id()
           }
           | nil
           | ResponseToPost.t()
  def ask_bot(server_id, channel, user, text, opts \\ []) do
    formatted_text =
      TxtBlock.to_binary(text, __MODULE__)

    GenServer.call(
      __MODULE__,
      {:ask_bot, {server_id, channel, user, formatted_text, opts[:ref]}, opts}
    )
  end

  @impl Service
  def send_msg({server_id, channel, user}, text, opts \\ []),
    do: send_msg(server_id, channel, user, text, opts)

  # BUG: why does Dialyzer not acknowledge unwrapped nil and ResponseToPost?
  @spec! send_msg(
           dummy_server_id(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content() | TxtBlock.t(),
           keyword()
         ) :: {:ok, nil}
  def send_msg(server_id, channel, user, text, opts \\ []) do
    formatted_text =
      TxtBlock.to_binary(text, __MODULE__)

    GenServer.call(
      __MODULE__,
      {:add_msg, {server_id, channel, user, formatted_text, opts[:ref]}}
    )
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
  def dm?({_id, _server_id = {:dm, __MODULE__}, _channel, _user, _body, _ref}),
    do: true

  def dm?(_other), do: false

  @impl Service
  def author_privileged?(server_id, author_id) do
    GenServer.call(__MODULE__, {:author_privileged?, server_id, author_id})
  end

  @impl Service
  def at_bot?(_cfg, %{referenced_msg_id: ref}) do
    (ref || false) &&
      transaction!(fn ->
        Memento.Query.read(__MODULE__.Table, ref)
        |> case do
          nil ->
            false

          found ->
            found.user |> bot_id?()
        end
      end)
  end

  @impl Service
  def bot_id?(id), do: id == @bot_user

  @impl Service
  def txt_format(blk, kind),
    do: TxtBlock.Md.format(blk, kind)

  @spec! channel_history(dummy_server_id(), dummy_channel_id()) :: channel()
  def channel_history(server_id, channel) do
    GenServer.call(__MODULE__, {:channel_history, server_id, channel})
  end

  @spec! server_dump(dummy_server_id()) :: channel_buffers()
  def server_dump(server_id) do
    GenServer.call(__MODULE__, {:server_dump, server_id})
  end

  def new_server(cfg_kwlist) when is_list(cfg_kwlist) do
    cfg_kwlist
    |> Keyword.put(:service, :dummy)
    |> SiteConfig.validate!(site_config_schema())
    |> S.CfgTable.insert_cfg()

    Process.sleep(100)

    :ok
  end

  def new_server(new_server_id, plugs \\ nil) when not is_list(new_server_id) do
    args =
      [
        server_id: new_server_id
      ] ++ if plugs, do: [plugs: plugs], else: []

    new_server(args)
  end

  @impl Service
  def reload_configs() do
    GenServer.call(__MODULE__, :reload_configs)
  end

  # PLUMBING

  @spec! update_state() :: %__MODULE__{}
  defp update_state() do
    struct!(
      __MODULE__,
      servers: S.CfgTable.servers_configured(__MODULE__),
      vip_ids: S.CfgTable.vips_configured(__MODULE__)
    )
  end

  @spec! update_state(%__MODULE__{}) :: %__MODULE__{}
  defp update_state(_ignored_state) do
    update_state()
  end

  @impl GenServer
  @spec! init(Keyword.t()) :: {:ok, %__MODULE__{}}
  def init(_) do
    # Service.register_logger(registry, __MODULE__, self())
    :ok = S.Tables.ensure_tables_exist([Services.Dummy.Table])
    {:ok, update_state()}
  end

  @impl GenServer
  def handle_call(
        {:add_msg, msg_tuple = {server_id, _channel, _user, _text, _ref}},
        _from,
        state
      ) do
    if server_id not in state.servers do
      # ignore unconfigured server
      {:reply, {:ok, nil}, state}
    else
      %{
        new_state: new_state_1
      } = do_add_new_msg(msg_tuple, state)

      {:reply, {:ok, nil}, new_state_1}
    end
  end

  def handle_call(
        {:ask_bot, msg_tuple = {server_id, channel, _user, _text, _ref}, opts},
        _from,
        state
      ) do
    if server_id not in state.servers do
      # ignore unconfigured server
      {:reply, nil, state}
    else
      %{
        posted_msg_id: inciting_msg_id,
        posted_msg_object: inciting_msg,
        new_state: new_state_1
      } = do_add_new_msg(msg_tuple, state)

      cfg = S.CfgTable.get_cfg!(__MODULE__, server_id)

      inciting_msg_with_context =
        inciting_msg
        |> MsgReceived.add_context(cfg)

      result =
        case Plugin.get_top_response(cfg, inciting_msg_with_context) do
          {response, iid} when is_struct(response, ResponseToPost) ->
            binary_response =
              response
              |> Map.update!(:text, fn blk ->
                TxtBlock.to_binary(blk, Services.Dummy)
              end)

            %{new_state: new_state_2, posted_msg_id: bot_response_msg_id} =
              do_post_response({server_id, channel}, binary_response, new_state_1)

            S.Interact.finalize_interaction(iid, bot_response_msg_id)

            {:reply,
             %{
               response: binary_response,
               posted_msg_id: inciting_msg_id,
               bot_response_msg_id: bot_response_msg_id
             }, new_state_2}

          nil ->
            {:reply, %{response: nil, posted_msg_id: inciting_msg_id}, new_state_1}
        end

      # if opts has key :return_id, returns the id of posted message along with any response msg
      case Keyword.get(opts, :return_id, false) do
        true ->
          result

        false ->
          {status, %{response: response}, state} = result

          {status, response, state}
      end
    end
  end

  def handle_call({:channel_history, server_id, channel}, _from, state) do
    if server_id not in state.servers, do: raise("Server not registered")

    history = do_get_channel_history(server_id, channel)

    {:reply, history, state}
  end

  def handle_call({:server_dump, server_id}, _from, state) do
    if server_id not in state.servers, do: raise("Server not registered")

    dump =
      transaction!(fn ->
        Memento.Query.select(
          __MODULE__.Table,
          {:==, :server, server_id}
        )
      end)

    {:reply, dump, state}
  end

  def handle_call({:author_privileged?, _server_id, author_id}, _from, state) do
    # TODO: make VIPs like Discord
    case author_id do
      @system_user ->
        {:reply, true, state}

      _other ->
        {:reply, false, state}
    end
  end

  def handle_call(:reload_configs, _from, state) do
    {
      :reply,
      :ok,
      update_state(state)
    }
  end

  defp do_post_response({server_id, channel}, response, state)
       when is_struct(response, ResponseToPost) do
    {server_id, channel, @bot_user, response.text, response.origin_msg_id}
    |> do_add_new_msg(state)
  end

  @spec! do_add_new_msg(tuple(), %__MODULE__{}) :: %{
           posted_msg_id: dummy_msg_id(),
           posted_msg_object: %MsgReceived{},
           new_state: %__MODULE__{}
         }
  defp do_add_new_msg(msg_tuple = {server_id, channel, user, text, ref}, state) do
    record =
      Dummy.Table.new(%{
        server_id: server_id,
        channel: channel,
        user: user,
        body: text,
        referenced_msg_id: ref
      })

    msg_id =
      transaction!(fn ->
        Memento.Query.write(record)
        |> Map.fetch!(:id)
      end)

    msg_object = into_msg(msg_tuple |> Tuple.insert_at(0, msg_id))

    %{
      posted_msg_id: msg_id,
      posted_msg_object: msg_object,
      new_state: state
    }
  end

  def do_get_channel_history(server_id, channel) do
    transaction!(fn ->
      Memento.Query.select(
        __MODULE__.Table,
        [
          {:==, :channel, channel},
          {:==, :server_id, server_id}
        ]
      )
      |> Enum.map(fn
        item ->
          {item.id, {item.user, item.body, item.referenced_msg_id}}
      end)
    end)
  end

  defp transaction!(f) do
    Memento.Transaction.execute!(f, 10)
  end
end
