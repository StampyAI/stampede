defmodule Service.Dummy do
  @moduledoc """
  This service can be used for testing and experimentation, by taking the role
  of a service relaying messages to Stampede.
  """
  use GenServer
  use TypeCheck
  alias Stampede, as: S
  alias S.{Msg, Response}

  # Imaginary server types
  @opaque! dummy_user_id :: atom()
  @system_user :server
  @opaque! dummy_channel_id :: atom()
  @opaque! dummy_server_id :: identifier()
  # "one channel"
  @typep! msg_content :: String.t() | nil
  # one message, tagged with channel
  @typep! msg_tuple :: {dummy_channel_id(), dummy_user_id(), msg_content()}
  @typep! channel :: tuple()
  # multiple channels
  @typep! channel_buffers :: %{dummy_channel_id() => channel()} | %{}
  @typep! dummy_state :: {SiteConfig.t(), channel_buffers()}

  @spec! channel_buffers_append(channel_buffers(), msg_tuple()) :: channel_buffers()
  def channel_buffers_append(bufs, {channel, author, msg}) do
    Map.update(bufs, channel, {}, &Tuple.append(&1, {author, msg}))
  end

  @spec! send_msg(identifier(), dummy_channel_id(), dummy_user_id(), msg_content()) :: nil | Response.t()
  def send_msg(instance, channel, author, text) do
    GenServer.call(instance, {:msg_new, {channel, author, text}})
  end

  @spec! channel_history(identifier(), dummy_channel_id()) :: channel()
  def channel_history(instance, channel) do
    GenServer.call(instance, {:channel_history, channel})
  end

  @spec! start_link(Keyword.t()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(cfg_overrides \\ []) do
    GenServer.start_link(__MODULE__, cfg_overrides)
  end
  @impl GenServer
  @spec! init(Keyword.t()) :: {:ok, dummy_state()}
  def init(cfg_overrides) do
    %{schema: schema} = NimbleOptions.new!(SiteConfig.schema_base())
    defaults = [service: :dummy, server_id: self(),
      error_channel_id: :error, prefix: "!",
      plugs: ["Test"]]
    cfg = Keyword.merge(defaults, cfg_overrides)
    |> SiteConfig.validate!(schema)
    
    #Service.register_logger(registry, __MODULE__, self())
    {:ok, {cfg, Map.new()}}
  end

  @impl GenServer
  def handle_call({:msg_new, {channel, user, msg}}, _from, orig_state = {cfg, buffers}) do
    our_msg = Msg.new(
      body: msg,
      channel_id: channel,
      author_id: user,
      server_id: self()
    )
    response = Plugin.get_top_response(cfg, our_msg)
    if response do
      buf2 = channel_buffers_append(buffers, {channel, user, msg})
            |> channel_buffers_append({channel, @system_user, response.text})
      {:reply, response, {cfg, buf2}}
    else
      {:reply, response, orig_state}
    end
  end
  def handle_call({:channel_history, channel}, _from, state = {_, history}) do
    {:reply, Map.fetch!(history, channel), state}
  end
end
