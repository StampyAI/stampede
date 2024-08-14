defmodule Services.Dummy.Server do
  use TypeCheck
  use GenServer
  require Aja

  alias Stampede, as: S
  alias Services.Dummy, as: D
  alias S.Events.{MsgReceived, ResponseToPost}

  @type! t :: map(channel_id :: any(), msgs :: %Aja.Vector{})

  def via(server_id), do: {:via, Registry, {D.Registry, server_id}}

  def call_if_configured(server_id, msg) do
    try do
      GenServer.call(
        via(server_id),
        msg
      )
    catch
      :exit, {:noproc, _} ->
        # ignore unconfigured servers
        {:error, :unconfigured}

      otherwise ->
        {:ok, otherwise}
    end
  end

  def call(server_id, msg) do
    call_if_configured(server_id, msg)
    |> case do
      {:error, :unconfigured} ->
        raise __MODULE__.NotConfiguredError

      {:ok, otherwise} ->
        otherwise
    end
  end

  def start_link(server_id: server_id) do
    GenServer.start_link(__MODULE__, %{server_id: server_id}, name: via(server_id))
  end

  def init(%{server_id: server_id}) do
    t =
      ETS.Set.new!(
        name: __MODULE__.ChannelTable,
        protection: :protected,
        read_concurrency: true,
        write_concurrency: true
      )

    {:ok, %{server_id: server_id, channel_table: t}}
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

  def handle_call(:ping, _from, state) do
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

  def handle_call({:get_msg, channel_id, ref}, _from, state) do
    msg =
      Map.fetch!(state.channels, channel_id)
      |> Aja.Vector.at!(ref)

    {:reply, msg, state}
  end

  # @spec! do_add_new_msg(server_id :: Services.Dummy.dummy_server_id(), tuple(), D.Server.t()) :: %{
  #          posted_msg_id: D.dummy_msg_id(),
  #          posted_msg_object: %S.Events.MsgReceived{},
  #          new_state: D.Server.t()
  #        }
  defp do_add_new_msg(
         msg_tup = {channel_id, user, text, ref},
         state = %{server_id: server_id, channels: cs}
       ) do
    new_msg = {user, text, ref}

    channel =
      case Map.get(cs, channel_id) do
        nil ->
          ETS.Set.new!(
            protection: :public,
            ordered: true
          )

        c = %ETS.Set{} ->
          c
      end

    cs2 = Map.put_new(cs, channel_id, channel)

    next_id =
      case ETS.Set.last(channel) do
        {:ok, last} ->
          last + 1

        {:error, :empty_table} ->
          0
      end

    _ = ETS.Set.put!(channel, msg_tup |> Tuple.insert_at(0, next_id))

    %{
      posted_msg_id: next_id,
      posted_msg_object:
        D.into_msg(
          msg_tup
          |> Tuple.insert_at(0, server_id)
          |> Tuple.insert_at(0, next_id)
        ),
      new_state: %{state | channels: cs2}
    }
  end

  defp do_post_response({_server_id, channel}, response, state)
       when is_struct(response, ResponseToPost) do
    {channel, D.bot_user(), response.text, response.origin_msg_id}
    |> do_add_new_msg(state)
  end
end

defmodule Services.Dummy.Server.NotConfiguredError do
  defexception [:message]
end
