defmodule Stampede.Interact.IntTable do
  use TypeCheck
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:id, :datetime, :plugin, :msg, :response, :traceback, :channel_lock],
    type: :ordered_set,
    disc_copies: S.nodes(),
    access_mode: :read_write,
    autoincrement: true,
    index: [:datetime],
    storage_properties: [ets: [:compressed]]

  @type! t ::
           {integer(), S.timestamp(), atom(), %S.Msg{}, %S.Response{}, S.traceback(),
            S.channel_lock_action()}
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

  @type! t ::
           {S.channel_id(), S.timestamp(), boolean(), nil | S.module_function_args(), integer()}
end

defmodule Stampede.Interact do
  require Logger
  alias Stampede, as: S
  alias S.{Msg, Response}
  alias S.Interact.{IntTable, ChannelLockTable}
  use TypeCheck
  use TypeCheck.Defstruct

  use GenServer

  @type! timestamp :: String.t()
  @type! interaction_id :: integer()

  @type! channel_lock_status ::
           false | {S.module_function_args(), atom(), interaction_id()}
  @typep! mod_state :: nil | []

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(any()) :: {:ok, mod_state()}
  @impl GenServer
  def init(_args \\ %{}) do
    IO.puts("Interact: starting")
    :ok = S.ensure_schema_exists(S.nodes())
    :ok = Memento.start()
    # Memento.info() # DEBUG
    :ok = S.ensure_tables_exist([ChannelLockTable, IntTable])

    {:ok, nil}
  end

  @spec! channel_locked?(S.channel_id()) :: channel_lock_status()
  def channel_locked?(channel_id) do
    match =
      transaction(fn ->
        Memento.Query.read(ChannelLockTable, channel_id)
      end)

    case match do
      [{_, _, status, mfa, iid}] when is_boolean(status) ->
        if status do
          # get plugin
          plug =
            transaction(fn ->
              [%{plugin: plug}] = Memento.Query.match(IntTable, {iid, :_, :"$1", :_, :_, :_, :_})
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
        datetime: S.time(),
        traceback:
          (is_list(int.traceback) &&
             IO.iodata_to_binary(int.traceback)) ||
            int.traceback,
        plugin: int.plugin,
        msg: int.msg,
        response: int.response,
        channel_lock: int.channel_lock
      )

    _ =
      transaction(fn ->
        int_id = do_write_interaction!(new_row)
        :ok = do_channel_lock!(int, new_row.datetime, int_id)

        # IO.puts("Interact: writing interaction row:\n  #{new_row |> S.pp()}") # DEBUG
      end)

    :ok
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

                # IO.puts("Interact: writing channel lock:\n  #{new_row |> inspect(pretty: true)}") # DEBUG

                :ok
            end

          {:unlock, channel_id} ->
            case channel_locked?(channel_id) do
              false ->
                Logger.error("plugin #{int.plugin} trying to unlock an already-unlocked channel")
                :ok

              plug when plug == int.plugin ->
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
                raise "plugin #{int.plugin} trying to take a lock from #{plug}"

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
  def terminate(reason, _state) do
    # DEBUG
    IO.puts("Interact exiting, reason: #{inspect(reason, pretty: true)}")

    :ok = Memento.stop()

    :ok
  end

  @spec! do_write_channellock!(%ChannelLockTable{}) :: :ok
  defp do_write_channellock!(record) do
    _ =
      transaction(fn ->
        Memento.Query.write(record)
      end)

    :ok
  end

  @spec! do_write_interaction!(%IntTable{}) :: integer()
  defp do_write_interaction!(record) do
    %{id: new_id} =
      transaction(fn ->
        Memento.Query.write(record)
      end)

    new_id
  end

  defp transaction(f) do
    Memento.transaction!(f)
  end
end
