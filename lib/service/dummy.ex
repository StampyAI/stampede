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
  @typep! dummy_state :: {SiteConfig.t(), channel_buffers()}

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
                default: ["Test"],
                type: {:custom, SiteConfig, :real_plugins, []}
              ],
              app_id: [
                default: Stampede,
                type: {:or, [:atom, :string]},
                doc: """
                Used for running multiple Stampede instances on the same BEAM. In queries to shared
                resources, such as Stampede.Registry, Stampede.QuickTaskSupers, etc.
                "Stampede" becomes something else. This isn't exactly a "site" config
                but it saves needing a lot of extra function args all over the place.
                """
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

  def log_error(cfg, {source_msg, error, stacktrace}) do
    send_msg(
      cfg.server_id,
      cfg.error_channel_id,
      @system_user,
      "#{inspect(source_msg, pretty: true)}\n#{Exception.format(:error, error, stacktrace)}"
    )
  end

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

    # convenience for relatively manual usage
    defaults = [
      service: :dummy,
      server_id: self()
    ]

    cfg =
      defaults
      |> Keyword.merge(cfg_overrides)
      |> SiteConfig.validate!(site_config_schema())

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
