defmodule Service.Dummy do
  require Logger
  use GenServer
  use TypeCheck
  alias Stampede, as: S
  require S
  alias S.{Msg, Response}

  # Imaginary server types
  @opaque! dummy_user_id :: atom()
  @opaque! dummy_channel_id :: atom()
  @opaque! dummy_server_id :: identifier() | atom()
  @opaque! dummy_msg_index :: integer()
  @type! dummy_msg_id ::
           {dummy_server_id(), dummy_channel_id(), dummy_user_id(), dummy_msg_index()}
  # "one channel"
  @typep! msg_content :: String.t() | nil
  # one message, tagged with channel
  @typep! msg_tuple :: {dummy_channel_id(), dummy_user_id(), msg_content()}
  @typep! channel :: list({dummy_msg_index(), dummy_user_id(), msg_content()})
  # multiple channels
  @typep! channel_buffers :: %{dummy_channel_id() => channel()} | %{}
  @typep! dummy_servers :: %{dummy_server_id() => {SiteConfig.t(), channel_buffers()}}
  @typep! dummy_state :: dummy_servers() | %{}

  @system_user :server

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

  # PUBLIC API FUNCTIONS

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
           msg_content(),
           keyword()
         ) ::
           %{response: nil | Response.t(), posted_msg_id: dummy_msg_id()} | nil | Response.t()
  def send_msg(server_id, channel, user, text, opts \\ []) do
    GenServer.call(__MODULE__, {:msg_new, {server_id, channel, user, text}, opts})
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

  # PLUMBING

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

  # if opts has key :return_id, returns the id of posted message along with any response msg
  def handle_call({:msg_new, msg_tuple = {server_id, channel, user, _text}, opts}, _from, servers) do
    if not Map.has_key?(servers, server_id) do
      # ignore unconfigured server
      {:reply, nil, servers}
    else
      %{
        msg_id: incoming_msg_id,
        msg_object: incoming_msg,
        new_state: new_state_1
      } = do_add_new_msg(msg_tuple, servers)

      cfg = Map.fetch!(servers, server_id) |> elem(0)
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

      case Keyword.get(opts, :return_id, false) do
        true ->
          result

        false ->
          {status, %{response: response}, state} = result
          {status, response, state}
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
    Map.update(bufs, channel, [{0, user, msg}], fn lst = [{last_id, _, _} | _] ->
      [{last_id + 1, user, msg} | lst]
    end)
  end

  defp do_post_response({server_id, channel}, response, servers)
       when is_struct(response, Response) do
    {server_id, channel, @system_user, response.text}
    |> do_add_new_msg(servers)
  end

  @spec! do_add_new_msg(tuple(), dummy_state()) :: %{
           msg_id: dummy_msg_id(),
           msg_object: %Msg{},
           new_state: dummy_state()
         }
  defp do_add_new_msg({server_id, channel, user, text}, servers) do
    {_cfg, buf} = Map.fetch!(servers, server_id)

    buf_updated = channel_buffers_append(buf, {channel, user, text})

    msg_id = {server_id, channel, user, buf_updated |> Map.fetch!(channel) |> hd() |> elem(0)}

    msg_object =
      Msg.new(
        id: msg_id,
        body: text,
        channel_id: channel,
        author_id: user,
        server_id: server_id
      )

    new_state =
      Map.update!(servers, server_id, fn {cfg, _} ->
        {cfg, buf_updated}
      end)

    %{
      msg_id: msg_id,
      msg_object: msg_object,
      new_state: new_state
    }
  end
end
