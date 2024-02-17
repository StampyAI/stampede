defmodule Service.Dummy do
  require Logger
  use GenServer
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S
  require S
  alias S.{Msg, Response}

  use Service

  # Imaginary server types
  @opaque! dummy_user_id :: atom()
  @opaque! dummy_channel_id :: atom() | nil
  @opaque! dummy_server_id :: identifier() | atom()
  @opaque! dummy_msg_index :: integer()
  @type! dummy_msg_id ::
           {dummy_server_id(), dummy_channel_id(), dummy_user_id(), dummy_msg_index()}
  # "one channel"
  @typep! msg_content :: String.t() | nil
  @typep! msg_reference :: nil | dummy_msg_id()
  # internal representation of messages
  @typep! msg_tuple :: {user :: dummy_user_id(), body :: msg_content(), ref :: msg_reference()}
  @typedoc """
  Tuple format for adding new messages
  """
  @type! msg_tuple_incoming ::
           {server_id :: dummy_server_id(), channel :: dummy_channel_id(),
            user :: dummy_user_id(), body :: msg_content(), ref :: msg_reference()}
  @typep! channel :: {dummy_msg_index(), list(msg_tuple())}
  # multiple channels
  @typep! channel_buffers :: %{dummy_channel_id() => channel()} | %{}
  @typep! dummy_servers :: %{dummy_server_id() => {SiteConfig.t(), channel_buffers()}}

  defstruct!(
    servers: _ :: dummy_servers(),
    vip_ids: _ :: S.CfgTable.vips()
  )

  @system_user :server

  @schema NimbleOptions.new!(
            SiteConfig.merge_custom_schema(
              service: [
                default: Service.Dummy,
                type: {:in, [Service.Dummy]}
              ],
              server_id: [
                required: true,
                type: :atom
              ],
              error_channel_id: [
                default: :error,
                type: :atom
              ],
              prefix: [
                default: "!",
                type: S.ntc(Regex.t() | String.t())
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

  @impl Service
  def send_msg({server_id, channel, user}, text, opts \\ []),
    do: send_msg(server_id, channel, user, text, opts)

  # BUG: why does Dialyzer not acknowledge unwrapped nil and Response?
  @spec! send_msg(
           dummy_server_id(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content(),
           keyword()
         ) ::
           %{response: nil | Response.t(), posted_msg_id: dummy_msg_id()} | nil | Response.t()
  def send_msg(server_id, channel, user, text, opts \\ []) do
    GenServer.call(__MODULE__, {:add_msg, {server_id, channel, user, text}, opts})
  end

  @impl Service
  def log_plugin_error(cfg, log) do
    _ =
      send_msg(
        SiteConfig.fetch!(cfg, :server_id),
        SiteConfig.fetch!(cfg, :error_channel_id),
        @system_user,
        log
      )

    :ok
  end

  # TODO
  @impl Service
  def log_serious_error(_), do: :ok

  @impl Service
  def into_msg({msg_id = {server_id, channel, user, _id}, text, ref}) do
    Msg.new(
      id: msg_id,
      body: text,
      channel_id: channel,
      author_id: user,
      server_id: server_id,
      referenced_msg_id: ref
    )
  end

  @impl Service
  def reload_configs() do
    GenServer.call(__MODULE__, :reload_configs)
  end

  @impl Service
  def author_is_privileged(server_id, author_id) do
    GenServer.call(__MODULE__, {:author_is_privileged, server_id, author_id})
  end

  @impl Service
  def txt_source_block(txt) when is_binary(txt), do: S.markdown_source(txt)

  @impl Service
  def txt_quote_block(txt) when is_binary(txt), do: S.markdown_quote(txt)

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

  # PLUMBING

  @spec! update_state() :: %__MODULE__{}
  defp update_state() do
    struct!(
      __MODULE__,
      servers:
        S.CfgTable.servers_configured(__MODULE__)
        |> Map.new(fn server_id -> {server_id, %{}} end),
      vip_ids: S.CfgTable.vips_configured(__MODULE__)
    )
  end

  @spec! update_state(%__MODULE__{}) :: %__MODULE__{}
  defp update_state(state) do
    newservers = S.CfgTable.servers_configured(__MODULE__)
    vips = S.CfgTable.vips_configured(__MODULE__)

    state
    |> Map.put(:vip_ids, vips)
    |> Map.put(
      :servers,
      for server_id <- newservers do
        Map.get(state.servers, server_id, %{})
      end
      |> Map.new()
    )
  end

  @impl GenServer
  @spec! init(Keyword.t()) :: {:ok, %__MODULE__{}}
  def init(_) do
    # Service.register_logger(registry, __MODULE__, self())
    {:ok, update_state()}
  end

  @impl GenServer
  def handle_call(
        {:add_msg, msg_tuple = {server_id, channel, _user, _text}, opts},
        _from,
        state
      ) do
    ref = opts[:ref]

    if not Map.has_key?(state.servers, server_id) do
      # ignore unconfigured server
      {:reply, nil, state}
    else
      %{
        msg_id: incoming_msg_id,
        msg_object: incoming_msg,
        new_state: new_state_1
      } = do_add_new_msg(msg_tuple |> Tuple.append(ref), state.servers)

      cfg = Map.fetch!(state.servers, server_id) |> elem(0)
      response = Plugin.get_top_response(cfg, incoming_msg)

      result =
        case response do
          response when is_struct(response, Response) ->
            %{new_state: new_state_2} =
              do_post_response({server_id, channel}, response, new_state_1)

            {:reply, %{response: response, posted_msg_id: incoming_msg_id}, new_state_2}

          nil ->
            {:reply, %{response: nil, posted_msg_id: incoming_msg_id}, new_state_1}
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
    {:reply, Map.fetch!(state.servers, server_id) |> elem(1) |> Map.fetch!(channel), state}
  end

  def handle_call({:server_dump, server_id}, _from, state) do
    {:reply, Map.fetch!(state.servers, server_id) |> elem(1), state}
  end

  def handle_call({:author_is_privileged, _server_id, author_id}, _from, state) do
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
       when is_struct(response, Response) do
    {server_id, channel, @system_user, response.text, response.origin_msg_id}
    |> do_add_new_msg(state.servers)
  end

  @spec! do_add_new_msg(tuple(), %__MODULE__{}) :: %{
           msg_id: dummy_msg_id(),
           msg_object: %Msg{},
           new_state: %__MODULE__{}
         }
  defp do_add_new_msg({server_id, channel, user, text, ref}, state) do
    buf_updated =
      Map.fetch!(state.servers, server_id)
      |> elem(1)
      |> Map.update(channel, {0, [{user, text, ref}]}, fn {last_id, lst} ->
        {last_id + 1, [{user, text, ref} | lst]}
      end)

    msg_id = {server_id, channel, user, buf_updated |> Map.fetch!(channel) |> elem(1)}

    msg_object = into_msg({msg_id, text, ref})

    new_state =
      Map.update!(state.servers, server_id, fn {cfg, _} ->
        {cfg, buf_updated}
      end)

    %{
      msg_id: msg_id,
      msg_object: msg_object,
      new_state: new_state
    }
  end
end
