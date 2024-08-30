defmodule Services.Dummy do
  @compile [:bin_opt_info, :recv_opt_info]
  require Logger
  use TypeCheck
  use TypeCheck.Defstruct
  require Ex2ms
  alias Stampede.Tables
  alias __MODULE__.Channel
  alias Stampede, as: S
  require S
  alias S.Events.{MsgReceived, ResponseToPost}
  require MsgReceived

  use Service
  use Supervisor

  # Imaginary server types
  @type! dummy_user_id :: atom()
  @type! dummy_channel_id :: atom() | nil
  @type! dummy_server_id :: identifier() | atom() | {:dm, __MODULE__}
  @type! dummy_msg_id :: integer()
  # "one channel"
  @type! msg_content :: String.t()
  @type! msg_reference :: nil | dummy_msg_id()
  @type! incoming_msg_tuple ::
           {server_id :: dummy_server_id(), channel :: dummy_channel_id(),
            user :: dummy_user_id(), formatted_text :: msg_content(), ref :: msg_reference()}
  @type! retrieved_msg_tuple ::
           {id :: dummy_msg_id(),
            {user :: dummy_user_id(), text :: msg_content(), ref :: msg_reference()}}
  @type! channel_log :: list(retrieved_msg_tuple())
  @type! server_log :: map(dummy_channel_id(), channel_log())

  @system_user :server
  @bot_user :stampede

  def system_user, do: @system_user
  def bot_user, do: @bot_user

  @schema NimbleOptions.new!(
            SiteConfig.merge_custom_schema(
              service: [
                default: __MODULE__,
                type: {:in, [__MODULE__]}
              ],
              server_id: [
                required: true,
                type: {:or, [:atom, {:in, ["DM", {:dm, __MODULE__}]}]}
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

  The database of messages is all in one table, channels are made syncronous by one GenServer per channel doing all writing.

  SiteConfig/startup args:
  #{NimbleOptions.docs(@schema)}
  """
  def site_config_schema(), do: @schema

  @impl Service
  def start_link([]) do
    Supervisor.start_link(__MODULE__, name: __MODULE__.Supervisor)
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
         ) :: {:ok, dummy_msg_id()}
  def send_msg(server_id, channel, user, text, opts \\ []) do
    formatted_text =
      TxtBlock.to_binary(text, __MODULE__)

    Channel.add_msg({server_id, channel, user, formatted_text, opts[:ref]})
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
  def ask_bot(server_id, channel, user, unformatted_text, opts \\ []) do
    return_id = Keyword.get(opts, :return_id, false)

    text =
      TxtBlock.to_binary(unformatted_text, __MODULE__)

    {:ok, inciting_msg_id} = send_msg(server_id, channel, user, text, opts)

    case Stampede.CfgTable.get_cfg(__MODULE__, server_id) do
      {:error, :server_notfound} ->
        Logger.debug("Dummy ignoring unconfigured server #{server_id |> inspect()}")
        nil

      {:ok, cfg} ->
        inciting_msg_with_context =
          inciting_msg_id
          |> get_msg_object()
          |> MsgReceived.add_context(cfg)

        case Plugin.get_top_response(cfg, inciting_msg_with_context) do
          {response = %ResponseToPost{}, iid} when is_struct(response, ResponseToPost) ->
            binary_response =
              response
              |> Map.update!(:text, fn blk ->
                TxtBlock.to_binary(blk, __MODULE__)
              end)

            {:ok, bot_response_msg_id} =
              send_msg(server_id, channel, @bot_user, binary_response.text,
                ref: response.origin_msg_id
              )

            S.Interact.finalize_interaction(iid, bot_response_msg_id)

            if return_id do
              %{
                response: binary_response,
                posted_msg_id: inciting_msg_id,
                bot_response_msg_id: bot_response_msg_id
              }
            else
              binary_response
            end

          nil ->
            nil
        end

      _ ->
        raise "Unexpected result from get_cfg"
    end
  end

  def default_server(),
    do: {:dm, __MODULE__}

  def default_channel(),
    do: :default_channel

  def ask_bot(unformatted_text) do
    default_config = [
      server_id: "DM",
      prefix: "!",
      plugs: :all,
      dm_handler: true,
      bot_is_loud: true
    ]

    # Register default server if it isn't already
    _ =
      case Stampede.CfgTable.get_cfg(__MODULE__, default_server()) do
        {:error, :server_notfound} ->
          default_config
          |> new_server()

        {:ok, _} ->
          :ok
      end

    ask_bot(default_server(), default_channel(), @system_user, unformatted_text)
  end

  def new_server(cfg_kwlist) when is_list(cfg_kwlist) do
    cfg_kwlist
    |> Keyword.put(:service, :dummy)
    |> SiteConfig.validate!(site_config_schema(), [&hack_dummy_dm_handler/2])
    |> S.CfgTable.insert_cfg()

    # Just to be safe
    Process.sleep(100)

    :ok
  end

  @impl Service
  def reload_configs() do
    :ok
  end

  @spec! get_msg_object(dummy_msg_id()) :: MsgReceived.t()
  def get_msg_object(id) do
    Tables.transaction!(fn ->
      Memento.Query.read(Tables.DummyMsgs, id)
    end)
    |> into_msg()
  end

  def into_msg(%Tables.DummyMsgs{
        id: id,
        server_id: server_id,
        channel: channel,
        user: user,
        body: body,
        referenced_msg_id: ref
      }) do
    MsgReceived.new(
      id: id,
      body: body,
      channel_id: channel,
      author_id: user,
      server_id: server_id,
      referenced_msg_id: ref
    )
  end

  def via(server_id, channel_id) do
    tag = :erlang.phash2({server_id, channel_id})
    {:via, Registry, {__MODULE__.ChannelRegistry, tag}}
  end

  @impl Service
  def format_plugin_fail(
        _cfg = %{service: __MODULE__},
        msg = %{service: __MODULE__},
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
      |> TxtBlock.to_binary(__MODULE__)

    _ =
      send_msg(
        SiteConfig.fetch!(cfg, :server_id),
        SiteConfig.fetch!(cfg, :error_channel_id),
        @bot_user,
        formatted
      )

    {:ok, formatted}
  end

  @impl Service
  @spec! dm?(MsgReceived.t()) :: boolean()
  def dm?(%MsgReceived{server_id: {:dm, __MODULE__}}),
    do: true

  def dm?(%MsgReceived{}), do: false

  @impl Service
  def author_privileged?(server_id, author_id) do
    S.CfgTable.vips_configured(__MODULE__)
    |> Map.get(server_id, MapSet.new())
    |> MapSet.member?(author_id)
  end

  @impl Service
  def at_bot?(_cfg, %{referenced_msg_id: ref}) do
    (ref || false) &&
      Tables.transaction!(fn ->
        Memento.Query.read(Tables.DummyMsgs, ref)
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

  @spec! channel_history(dummy_server_id(), dummy_channel_id()) :: channel_log()
  def channel_history(server_id, channel) do
    Tables.transaction!(fn ->
      Memento.Query.select(
        Tables.DummyMsgs,
        {:and, {:==, :server_id, server_id}, {:==, :channel, channel}}
        # Ex2ms.fun do
        #   {id, _datetime, sid, cid, user, body, ref}
        #   when sid == ^server_id and cid == ^channel ->
        #     {id, {user, body, ref}}
        # end
      )
      |> Enum.map(fn
        item = %Tables.DummyMsgs{} ->
          {item.id, {item.user, item.body, item.referenced_msg_id}}
      end)
    end)
  end

  @spec! server_dump(dummy_server_id()) :: server_log()
  def server_dump(server_id) do
    Tables.transaction!(fn ->
      Memento.Query.select(
        Tables.DummyMsgs,
        {:==, :server_id, server_id}
        # Ex2ms.fun do
        #   {id, _datetime, sid, cid, user, body, ref}
        #   when sid == ^server_id and cid == ^channel ->
        #     {id, {user, body, ref}}
        # end
      )
      |> Enum.reduce(%{}, fn
        item = %Tables.DummyMsgs{}, acc ->
          this_msg = {item.id, {item.user, item.body, item.referenced_msg_id}}

          Map.update(acc, item.channel, [this_msg], fn channel ->
            [this_msg | channel]
          end)
      end)
      |> Map.new(fn {cid, channel} ->
        {cid, Enum.reverse(channel)}
      end)
    end)
  end

  # Transform function for use in `SiteConfig.validate!/3`. This is a hack because it's dodging the duplicate checking done in `SiteConfig.make_configs_for_dm_handling/1`.
  defp hack_dummy_dm_handler(kwlist, _schema) do
    case kwlist[:server_id] do
      "DM" ->
        kwlist
        |> Keyword.put(:server_id, S.make_dm_tuple(Services.Dummy))
        |> Keyword.put(:dm_handler, true)

      _ ->
        kwlist
    end
  end

  @impl Supervisor
  def init(_ \\ []) do
    children = [
      {DynamicSupervisor, name: __MODULE__.ChannelSuper},
      {Registry, keys: :unique, name: __MODULE__.ChannelRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
