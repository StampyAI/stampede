defmodule Services.Dummy.Channel do
  use TypeCheck
  alias Stampede.Tables.Ids
  alias Stampede.Tables.DummyMsgs
  alias Stampede.Tables
  alias Services.Dummy

  use GenServer

  @type! t :: nil

  def start_link(via_spec) do
    GenServer.start_link(__MODULE__, [], name: via_spec)
  end

  @spec! add_msg(Dummy.incoming_msg_tuple()) :: {:ok, Dummy.dummy_msg_id()}
  def add_msg({server_id, channel, user, formatted_text, ref}) do
    via_spec = {:via, _, {reg, tag}} = Dummy.via(server_id, channel)

    _ =
      case Registry.lookup(reg, tag) do
        [_] ->
          :done

        [] ->
          {:ok, _} = DynamicSupervisor.start_child(Dummy.ChannelSuper, {__MODULE__, via_spec})
      end

    GenServer.call(via_spec, {:add_msg, {server_id, channel, user, formatted_text, ref}})
  end

  @spec! init([]) :: {:ok, t()}
  def init([]) do
    {:ok, nil}
  end

  @spec! handle_call(any(), any(), t()) :: tuple()
  def handle_call({:add_msg, msg}, _, state) do
    {:reply, {:ok, do_add_msg(msg)}, state}
  end

  @spec! do_add_msg(Dummy.incoming_msg_tuple()) :: Dummy.dummy_msg_id()
  def do_add_msg(msg = {_server_id, _channel, _user, _formatted_text, _ref}) do
    id = Ids.reserve_id(DummyMsgs)

    record = DummyMsgs.new(id, msg)

    Tables.transaction_sync!(fn ->
      %DummyMsgs{} = Memento.Query.write(record)

      :ok
    end)

    id
  end
end
