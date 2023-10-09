defmodule Service.Dummy do
  @moduledoc """
  This service can be used for testing and experimentation, by taking the role
  of a service relaying messages to Stampede.
  """
  require Logger
  use GenServer
  use TypeCheck
  alias Stampede, as: S
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
  @typep! dummy_state :: {SiteConfig.t(), channel_buffers()}

  @spec! channel_buffers_append(channel_buffers(), msg_tuple()) :: channel_buffers()
  def channel_buffers_append(bufs, {channel, user, msg}) do
    Map.update(bufs, channel, {{user, msg}}, &Tuple.append(&1, {user, msg}))
  end

  @spec! send_msg(
           identifier(),
           dummy_channel_id(),
           dummy_user_id(),
           msg_content(),
           dummy_server_id() | nil
         ) ::
           nil | Response.t()
  def send_msg(instance, channel, user, text, server_id \\ nil) do
    GenServer.call(instance, {:msg_new, {server_id || instance, channel, user, text}})
  end

  @spec! channel_history(identifier(), dummy_channel_id()) :: channel()
  def channel_history(instance, channel) do
    GenServer.call(instance, {:channel_history, channel})
  end

  def channel_dump(instance) do
    GenServer.call(instance, :channel_dump)
  end

  @spec! start_link(Keyword.t()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(cfg_overrides \\ []) do
    GenServer.start_link(__MODULE__, cfg_overrides)
  end

  @impl GenServer
  @spec! init(Keyword.t()) :: {:ok, dummy_state()}
  def init(cfg_overrides) do
    Logger.metadata(stampede_component: :dummy)
    %{schema: schema} = NimbleOptions.new!(SiteConfig.schema_base())

    defaults = [
      service: :dummy,
      server_id: self(),
      error_channel_id: :error,
      prefix: "!",
      plugs: ["Test"]
    ]

    cfg =
      Keyword.merge(defaults, cfg_overrides)
      |> SiteConfig.validate!(schema)

    # Service.register_logger(registry, __MODULE__, self())
    {:ok, {cfg, Map.new()}}
  end

  @impl GenServer
  def handle_call({:msg_new, {server, channel, user, text}}, _from, {cfg, buffers}) do
    if server != cfg.server_id do
      # ignore unconfigured server
      {:reply, nil, {cfg, buffers}}
    else
      buf2 = channel_buffers_append(buffers, {channel, user, text})

      our_msg =
        Msg.new(
          body: text,
          channel_id: channel,
          author_id: user,
          server_id: server || self()
        )

      response = Plugin.get_top_response(cfg, our_msg)

      if response do
        buf3 = channel_buffers_append(buf2, {channel, @system_user, response.text})
        {:reply, response, {cfg, buf3}}
      else
        {:reply, response, {cfg, buf2}}
      end
    end
  end

  def handle_call({:channel_history, channel}, _from, state = {_, history}) do
    {:reply, Map.fetch!(history, channel), state}
  end

  def handle_call(:channel_dump, _from, state = {_, history}) do
    {:reply, history, state}
  end
end
