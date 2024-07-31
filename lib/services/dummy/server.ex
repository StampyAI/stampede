defmodule Services.Dummy.Server do
  use TypeCheck
  use GenServer
  require Aja

  alias Stampede, as: S
  alias Services.Dummy, as: D

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

  def debug_start_self(server_id) do
    {:ok, _} = DynamicSupervisor.start_child(D.DynSup, {__MODULE__, server_id: server_id})
    :ok
  end

  def start_link(server_id: server_id) do
    GenServer.start_link(__MODULE__, %{server_id: server_id}, name: via(server_id))
  end

  def init(%{server_id: server_id}) do
    {:ok, %{server_id: server_id, channels: %{}}}
  end

  def ping(server_id) do
    :pong = GenServer.call(via(server_id), :ping)

    :pong
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
    |> case do
      {:error, :noproc} ->
        raise("Server not registered")

      channels ->
        Map.new(channels, fn {cid, hist} ->
          {cid, Aja.Enum.with_index(hist, fn val, i -> {i, val} end)}
        end)
    end
  end

  def handle_call({:add_msg, tup = {channel, user, formatted_text, ref}}, _from, state) do
    %{new_state: s2} = do_add_new_msg(tup, state)

    {:reply, nil, s2}
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

    id = Aja.Vector.size(Map.fetch!(c2, channel_id))

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
end
