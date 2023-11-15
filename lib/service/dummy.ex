defmodule Service.Dummy do
  require Logger
  use GenServer
  use TypeCheck
  alias Stampede, as: S
  require S
  alias S.{Msg, Response}

  # Imaginary server types
  @opaque! dummy_user_id :: atom()
  @system_user :server
  @opaque! dummy_channel_id :: atom()
  @opaque! dummy_server_id :: identifier() | atom()
  # "one channel"
  @typep! msg_content :: String.t() | nil
  # one message, tagged with channel
  @typep! msg_tuple :: {dummy_channel_id(), dummy_user_id(), msg_content()}
  @typep! channel :: tuple()
  # multiple channels
  @typep! channel_buffers :: %{dummy_channel_id() => channel()} | %{}
  @typep! dummy_servers :: %{dummy_server_id() => {SiteConfig.t(), channel_buffers()}}
  @typep! dummy_state :: dummy_servers() | %{}

  @schema NimbleOptions.new!(
            SiteConfig.merge_custom_schema(
              service: [
                default: Service.Dummy,
                type: {:in, [Service.Dummy]}
              ],
              server_id: [
                required: true,
                type: :any
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
              ]
            )
          )
  @moduledoc """
  This service can be used for testing and experimentation, by taking the role
  of a service relaying messages to Stampede.

  It expects one config per service instance, which is not how real services should work.

  SiteConfig/startup args:
  #{NimbleOptions.docs(@schema)}
  """
  def site_config_schema(), do: @schema

  def log_plugin_error(cfg, log) do
    send_msg(
      SiteConfig.fetch!(cfg, :server_id),
      SiteConfig.fetch!(cfg, :error_channel_id),
      @system_user,
      log
    )
  end

  @spec! send_msg(
           dummy_server_id(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content()
         ) ::
           nil | Response.t()
  def send_msg(server_id, channel, user, text) do
    GenServer.call(__MODULE__, {:msg_new, {server_id, channel, user, text}})
  end

  @spec! channel_history(dummy_server_id(), dummy_channel_id()) :: channel()
  def channel_history(server_id, channel) do
    GenServer.call(__MODULE__, {:channel_history, server_id, channel})
  end

  @spec! server_dump(dummy_server_id()) :: channel_buffers()
  def server_dump(server_id) do
    GenServer.call(__MODULE__, {:server_dump, server_id})
  end

  def new_server(new_server_id, plugs \\ nil) do
    GenServer.call(__MODULE__, {:new_server, new_server_id, plugs})
  end

  @spec! start_link(Keyword.t()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(cfg_overrides \\ []) do
    Logger.debug("starting Dummy GenServer, with cfg overrides: #{inspect(cfg_overrides)}")
    GenServer.start_link(__MODULE__, cfg_overrides, name: __MODULE__)
  end

  @impl GenServer
  @spec! init(Keyword.t()) :: {:ok, dummy_state()}
  def init(_) do
    Logger.metadata(stampede_component: :dummy)

    # Service.register_logger(registry, __MODULE__, self())
    {:ok, Map.new()}
  end

  @impl GenServer
  def handle_call({:new_server, id, plugs}, _from, servers) do
    Logger.debug("new Dummy server #{id}")

    if Map.get(servers, id, false) do
      {:reply, {:error, :already_exists}}
    else
      new_cfg =
        [
          service: :dummy,
          server_id: id
        ]
        |> S.keyword_put_new_if_not_falsy(:plugs, plugs)
        |> SiteConfig.validate!(site_config_schema())

      new_state = Map.put(servers, id, {new_cfg, Map.new()})
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:msg_new, {server_id, channel, user, text}}, _from, servers) do
    if not Map.has_key?(servers, server_id) do
      # ignore unconfigured server
      {:reply, nil, servers}
    else
      {cfg, buf} = Map.fetch!(servers, server_id)

      buf2 = channel_buffers_append(buf, {channel, user, text})

      our_msg =
        Msg.new(
          body: text,
          channel_id: channel,
          author_id: user,
          server_id: server_id
        )

      response = Plugin.get_top_response(cfg, our_msg)

      if response do
        buf3 = channel_buffers_append(buf2, {channel, @system_user, response.text})

        new_state =
          Map.update!(servers, server_id, fn {cfg, _} ->
            {cfg, buf3}
          end)

        {:reply, response, new_state}
      else
        new_state =
          Map.update!(servers, server_id, fn {cfg, _} ->
            {cfg, buf2}
          end)

        {:reply, response, new_state}
      end
    end
  end

  def handle_call({:channel_history, server_id, channel}, _from, servers) do
    {:reply, Map.fetch!(servers, server_id) |> elem(1) |> Map.fetch!(channel), servers}
  end

  def handle_call({:server_dump, server_id}, _from, servers) do
    {:reply, Map.fetch!(servers, server_id) |> elem(1), servers}
  end

  @spec! channel_buffers_append(channel_buffers(), msg_tuple()) :: channel_buffers()
  def channel_buffers_append(bufs, {channel, user, msg}) do
    Map.update(bufs, channel, {{user, msg}}, &Tuple.append(&1, {user, msg}))
  end
end
