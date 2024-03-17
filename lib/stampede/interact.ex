defmodule Stampede.Interact.IntTable do
  use TypeCheck
  alias Stampede.Msg
  alias Stampede.Response
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:id, :datetime, :plugin, :msg_id, :msg, :response, :traceback, :channel_lock],
    type: :ordered_set,
    disc_copies: S.nodes(),
    access_mode: :read_write,
    autoincrement: true,
    index: [:datetime, :msg_id],
    storage_properties: [ets: [:compressed]]

  def validate!(record) when is_struct(record, __MODULE__) do
    TypeCheck.conforms!(record, %__MODULE__{
      id: nil | integer(),
      datetime: S.timestamp(),
      plugin: module(),
      msg_id: S.msg_id(),
      msg: %Msg{},
      response: %Response{},
      traceback: TxtBlock.t(),
      channel_lock: S.channel_lock_action()
    })
  end

  def validate!(record) when not is_struct(record, __MODULE__),
    do: raise("Invalid #{__MODULE__} instance.\n" <> S.pp(record))
end

defmodule Stampede.Interact.ChannelLockTable do
  use TypeCheck
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:channel_id, :datetime, :lock_status, :callback, :interaction_id],
    type: :set,
    autoincrement: false,
    disc_copies: S.nodes(),
    access_mode: :read_write

  def validate!(record) when is_struct(record, __MODULE__) do
    TypeCheck.conforms!(record, %__MODULE__{
      channel_id: S.channel_id(),
      datetime: S.timestamp(),
      lock_status: boolean(),
      callback: nil | S.module_function_args(),
      interaction_id: integer()
    })
  end
end

defmodule Stampede.Interact do
  require Logger
  alias Stampede.Interaction
  alias Stampede, as: S
  alias S.Interact.{IntTable, ChannelLockTable}
  use TypeCheck
  use TypeCheck.Defstruct

  use GenServer

  @typep! mod_state :: nil | []

  @all_tables [ChannelLockTable, IntTable]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(any()) :: {:ok, mod_state()}
  @impl GenServer
  def init(args \\ []) do
    Logger.debug("Interact: starting")
    _ = Memento.stop()
    :ok = S.ensure_schema_exists(S.nodes())
    :ok = Memento.start()
    # # DEBUG
    # Memento.info()
    # Memento.Schema.info()
    :ok = S.ensure_tables_exist(@all_tables)

    if Keyword.get(args, :wipe_tables) == true do
      _ = clear_all_tables()
    end

    {:ok, nil}
  end

  @spec! get(S.msg_id()) :: {:ok, %IntTable{}} | {:error, any()}
  def get(msg_id_unsafe) do
    msg_id =
      case msg_id_unsafe do
        tup when is_tuple(tup) ->
          # BUG: :mnesia needs literal tuples to be wrapped in order to match correctly
          {tup}

        not_tup ->
          not_tup
      end

    transaction(fn ->
      Memento.Query.select(
        IntTable,
        {:==, :msg_id, msg_id}
      )
      |> case do
        [result] ->
          {:ok, result}

        [] ->
          {:error, :not_found}

        results when is_list(results) ->
          raise "multiple entries found for one msg_id"
      end
    end)
  end

  @spec! get_traceback(S.msg_id()) :: {:ok, S.traceback()} | {:error, any()}
  def get_traceback(msg_id) do
    transaction(fn ->
      get(msg_id)
      |> case do
        {:ok, record} ->
          {:ok, record.traceback}

        other ->
          other
      end
    end)
  end

  @spec! channel_locked?(S.channel_id()) :: S.channel_lock_status()
  def channel_locked?(channel_id) do
    match =
      transaction(fn ->
        Memento.Query.read(ChannelLockTable, channel_id)
      end)

    case match do
      %ChannelLockTable{lock_status: status, callback: mfa, interaction_id: iid} ->
        if status do
          # get plugin
          plug =
            transaction(fn ->
              [%{plugin: plug}] =
                Memento.Query.match(IntTable, {iid, :_, :"$1", :_, :_, :_, :_, :_})

              plug
            end)

          {mfa, plug, iid}
        else
          false
        end

      nil ->
        false
    end
  end

  @spec! record_interaction!(%S.Interaction{}) :: :ok
  def record_interaction!(int) when int.__struct__ == Stampede.Interaction do
    new_row =
      struct!(
        IntTable,
        id: nil,
        datetime: S.time(),
        plugin: int.plugin,
        msg_id: int.msg.id,
        msg: int.msg,
        response: int.response,
        traceback: int.traceback,
        channel_lock: int.channel_lock
      )
      |> IntTable.validate!()

    # IO.puts("Interact: new interaction:\n#{new_row |> S.pp()}") # DEBUG

    new_record =
      transaction(fn ->
        result = do_write_interaction!(new_row)
        :ok = do_channel_lock!(int, new_row.datetime, result.id)
        result
      end)

    :ok = announce_interaction(new_record)

    :ok
  end

  @spec! announce_interaction(%IntTable{}) :: :ok
  def announce_interaction(rec) do
    Logger.info(fn ->
      to_print = [
        server: rec.msg.server_id,
        responding_to: rec.msg.author_id,
        responding_plug: rec.response.origin_plug,
        response: rec.response.text,
        channel_lock:
          if rec.channel_lock do
            rec.channel_lock |> inspect()
          else
            false
          end
      ]

      [
        "NEW INTERACTION ",
        inspect(rec.id),
        "\n",
        to_print |> S.pp()
      ]
    end)
  end

  @spec! do_channel_lock!(%S.Interaction{}, String.t(), integer()) :: :ok
  def do_channel_lock!(int, datetime, int_id) do
    # IO.puts( # DEBUG
    #   "Interact: checking channel lock: #{{int, datetime, int_id} |> inspect(pretty: true)}"
    # )

    result =
      transaction(fn ->
        case int.channel_lock do
          {:lock, channel_id, mfa} ->
            case channel_locked?(channel_id) do
              false ->
                new_row =
                  struct!(
                    ChannelLockTable,
                    channel_id: channel_id,
                    datetime: datetime,
                    lock_status: true,
                    callback: mfa,
                    interaction_id: int_id
                  )

                :ok = do_write_channellock!(new_row)

                # IO.puts("Interact: writing new channel lock:\n  #{new_row |> inspect(pretty: true)}") # DEBUG

                :ok

              {_mfa, plug, _iid} when is_atom(plug) ->
                if plug != int.response.origin_plug do
                  raise(
                    "plugin #{int.plugin} trying to lock an already-locked channel owned by #{plug}"
                  )
                end

                new_row =
                  struct!(
                    ChannelLockTable,
                    channel_id: channel_id,
                    datetime: datetime,
                    lock_status: true,
                    callback: mfa,
                    interaction_id: int_id
                  )

                :ok = do_write_channellock!(new_row)

                # IO.puts("Interact: updating channel lock:\n  #{new_row |> inspect(pretty: true)}") # DEBUG

                :ok
            end

          {:unlock, channel_id} ->
            case channel_locked?(channel_id) do
              false ->
                Logger.error("plugin #{int.plugin} trying to unlock an already-unlocked channel")
                :ok

              {_, plug, _} when plug == int.plugin ->
                new_row =
                  struct!(
                    ChannelLockTable,
                    channel_id: channel_id,
                    datetime: datetime,
                    lock_status: false,
                    callback: nil,
                    interaction_id: int_id
                  )

                :ok = do_write_channellock!(new_row)

                # IO.puts("Interact: writing channel lock:\n  #{new_row |> inspect(pretty: true)}") # DEBUG
                :ok

              plug when plug != int.plugin ->
                raise "plugin #{int.plugin |> inspect()} trying to take a lock from #{plug |> inspect()}"

              other ->
                raise "bad channel_locked? return #{other |> inspect(pretty: true)}"
            end

          false ->
            # do nothing
            # IO.puts("Interact: channel lock noop") # DEBUG
            :ok

          other ->
            raise "Interact: bad lock #{other |> inspect(pretty: true)}"
        end
      end)

    result
  end

  @impl GenServer
  def terminate(_reason, _state) do
    # DEBUG
    # IO.puts("Interact exiting, reason: #{inspect(reason, pretty: true)}")

    :ok = Memento.stop()

    :ok
  end

  @spec! do_write_channellock!(%ChannelLockTable{}) :: :ok
  defp do_write_channellock!(record) do
    _ = ChannelLockTable.validate!(record)

    _ =
      transaction(fn ->
        Memento.Query.write(record)
      end)

    :ok
  end

  @spec! do_write_interaction!(%IntTable{}) :: %IntTable{}
  defp do_write_interaction!(record) do
    transaction(fn ->
      Memento.Query.write(record)
    end)
  end

  @spec! read_interaction!(any()) :: %Interaction{}
  def read_interaction!(msg_id) do
    do_read_interaction(msg_id)
    |> case do
      nil ->
        raise "Interact: couldn't find Interaction for #{msg_id |> inspect()}"

      other ->
        other
    end
  end

  defp do_read_interaction(msg_id) do
    transaction(fn ->
      Memento.Query.select(IntTable, {:==, :msg_id, msg_id})
    end)
  end

  defp transaction(f) do
    Memento.Transaction.execute!(f, 10)
  end

  def clear_all_tables() do
    Logger.info("Interact: clearing all tables for #{Mix.env()}")

    @all_tables
    |> Enum.each(fn t ->
      case Memento.Table.clear(t) do
        :ok -> :ok
        e = {:error, _reason} -> raise e
      end
    end)
  end
end
