defmodule Services.Dummy.Server do
  use TypeCheck
  use GenServer
  require Aja

  alias Stampede, as: S
  alias Services.Dummy, as: D
  alias S.Events.{MsgReceived, ResponseToPost}

  @type! t :: map(channel_id :: any(), msgs :: %Aja.Vector{})

  def via(server_id), do: {:via, Registry, {D.Registry, server_id}}

  def debug_start_own_parents() do
    {:ok, _} = DynamicSupervisor.start_link(name: D.DynSup)

    {:ok, _} =
      Registry.start_link(
        name: D.Registry,
        keys: :unique,
        partitions: System.schedulers_online()
      )

    :ok
  end

  def new_server(cfg_kwlist) when is_list(cfg_kwlist) do
    cfg =
      cfg_kwlist
      |> Keyword.put(:service, :dummy)
      |> SiteConfig.validate!(D.site_config_schema())

    :ok = S.CfgTable.insert_cfg(cfg)

    id = cfg.server_id

    {:ok, _} = DynamicSupervisor.start_child(D.DynSup, {__MODULE__, server_id: id})

    unless :pong == GenServer.call(via(id), :ping),
      do: raise("Starting server #{inspect(id)} failed")

    :ok
  end

  def start_link(server_id: server_id) do
    GenServer.start_link(__MODULE__, %{server_id: server_id}, name: via(server_id))
  end

  @spec! ask_bot(
           D.dummy_server_id(),
           D.dummy_channel_id(),
           D.dummy_user_id(),
           D.msg_content() | TxtBlock.t(),
           keyword()
         ) ::
           nil
           | %{
               response: nil | ResponseToPost.t(),
               posted_msg_id: D.dummy_msg_id(),
               bot_response_msg_id: nil | D.dummy_msg_id()
             }
           | ResponseToPost.t()
  def ask_bot(server_id, channel, user, text, opts \\ []) do
    formatted_text =
      TxtBlock.to_binary(text, D)

    try do
      GenServer.call(
        via(server_id),
        {:ask_bot, {channel, user, formatted_text, opts[:ref]}, opts}
      )
    catch
      :exit, {:noproc, _} ->
        # ignore unconfigured servers
        nil
    end
  end

  def init(%{server_id: server_id}) do
    {:ok, %{server_id: server_id, channels: %{}}}
  end

  def ping(server_id) do
    :pong = GenServer.call(via(server_id), :ping)
  end

  def add_msg({server_id, channel, user, formatted_text, ref}) do
    GenServer.call(via(server_id), {:add_msg, {channel, user, formatted_text, ref}})
    |> case do
      {:error, :noproc} ->
        raise("Server not registered")

      nil ->
        :ok
    end
  end

  def channel_history(server_id, channel) do
    GenServer.call(via(server_id), {:channel_history, channel})
    |> case do
      {:error, :noproc} ->
        raise("Server not registered")

      hist ->
        Aja.Enum.with_index(hist, fn val, i -> {i, val} end)
    end
  end

  def server_dump(server_id) do
    GenServer.call(via(server_id), :server_dump)
    |> Map.new(fn {cid, hist} ->
      {cid, Aja.Enum.with_index(hist, fn val, i -> {i, val} end)}
    end)
  end

  def handle_call({:add_msg, tup}, _from, state) do
    %{new_state: s2} = do_add_new_msg(tup, state)

    {:reply, nil, s2}
  end

  def handle_call(
        {:ask_bot, msg_tuple = {channel, _user, _text, _ref}, opts},
        _from,
        state = %{server_id: server_id}
      ) do
    %{
      posted_msg_id: inciting_msg_id,
      posted_msg_object: inciting_msg,
      new_state: new_state_1
    } = do_add_new_msg(msg_tuple, state)

    cfg = S.CfgTable.get_cfg!(D, server_id)

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

  def handle_call(:ping, _, state) do
    {:reply, :pong, state}
  end

  def handle_call({:channel_history, channel_id}, _from, state) do
    channel =
      Map.fetch!(state.channels, channel_id)

    {:reply, channel, state}
  end

  def handle_call(:server_dump, _from, state) do
    {:reply, state.channels, state}
  end

  # @spec! do_add_new_msg(server_id :: Services.Dummy.dummy_server_id(), tuple(), D.Server.t()) :: %{
  #          posted_msg_id: D.dummy_msg_id(),
  #          posted_msg_object: %S.Events.MsgReceived{},
  #          new_state: D.Server.t()
  #        }
  defp do_add_new_msg(
         msg_tup = {channel_id, user, text, ref},
         state = %{server_id: server_id, channels: c1}
       ) do
    new_msg = {user, text, ref}

    c2 =
      Map.update(c1, channel_id, Aja.vec([new_msg]), &Aja.Vector.append(&1, new_msg))

    id =
      c2
      |> Map.fetch!(channel_id)
      |> Aja.Vector.size()
      |> Kernel.-(1)

    %{
      posted_msg_id: id,
      posted_msg_object:
        D.into_msg(
          msg_tup
          |> Tuple.insert_at(0, server_id)
          |> Tuple.insert_at(0, id)
        ),
      new_state: %{state | channels: c2}
    }
  end

  defp do_post_response({_server_id, channel}, response, state)
       when is_struct(response, ResponseToPost) do
    {channel, D.bot_user(), response.text, response.origin_msg_id}
    |> do_add_new_msg(state)
  end
end
