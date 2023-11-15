defmodule Stampede.Interact do
  require Logger
  alias Stampede, as: S
  alias S.{Msg, Response}
  use TypeCheck
  use TypeCheck.Defstruct

  use GenServer

  defstruct!(
    interactions_table: _ :: any(),
    channellock_table: _ :: any(),
    counters_table: _ :: any()
  )

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(keyword()) :: {:ok, map()}
  @impl GenServer
  def init(_args) do
    :mnesia.create_schema(S.nodes())
    :mnesia.start()

    interactions_id =
      make_or_get_table!(
        :interactions,
        attributes: [:id, :datetime, :plugin, :msg, :response, :traceback, :channel_lock],
        type: :ordered_set,
        disc_copies: S.nodes(),
        access_mode: :read_write,
        index: [:datetime],
        storage_properties: [ets: [:compressed]]
      )

    channellock_id =
      make_or_get_table!(
        :channellocks,
        attributes: [:channel_id, :datetime, :lock_status, :callback, :interaction_id],
        type: :set,
        disc_copies: S.nodes(),
        access_mode: :read_write
      )

    counters_id =
      make_or_get_table!(
        :counters_table,
        attributes: [:table_name, :count],
        type: :set,
        access_mode: :read_write
      )

    :ok =
      :mnesia.wait_for_tables(
        [interactions_id, channellock_id, counters_id],
        :timer.seconds(5)
      )

    {:ok,
     struct!(
       __MODULE__,
       interactions_table: interactions_id,
       channellock_table: channellock_id,
       counters_table: counters_id
     )}
  end

  @spec! channel_locked?(S.channel_id()) :: S.channel_lock_action()
  def channel_locked?(channel_id) do
    :mnesia.dirty_match_object({
      :channellocks,
      channel_id,
      :_,
      :"$1",
      :"$2",
      :"$3"
    })
    |> case do
      [{status, mfa, iid}] when is_boolean(status) ->
        status && {:lock, mfa, iid}

      [] ->
        false
    end
  end

  def record_interaction!(int) when int.__struct__ == Stampede.Interaction do
    :mnesia.transaction(fn ->
      datetime = DateTime.utc_now() |> DateTime.to_iso8601()
      t_id = :mnesia.dirty_update_counter(:counters_table, :interactions, 1)

      trace =
        (is_list(int.traceback) &&
           IO.iodata_to_binary(int.traceback)) ||
          int.traceback

      plugin = int.plugin
      msg = int.msg
      response = int.response
      channel_lock = int.channel_lock

      do_channel_lock!(int, datetime, t_id)

      :mnesia.write(
        :interactions,
        {t_id, datetime, plugin, msg, response, trace, channel_lock},
        :write
      )
    end)

    :ok
  end

  def do_channel_lock!(int, datetime, int_id) do
    case int.channel_lock do
      {:lock, channel_id, mfa} ->
        case channel_locked?(channel_id) do
          false ->
            false

          {:unlock, _iid} ->
            false

          {:lock, plug, _iid} when is_atom(plug) ->
            raise(
              "plugin #{int.plugin} trying to lock an already-locked channel owned by #{plug}"
            )
        end

        :mnesia.write(
          :channellocks,
          {channel_id, datetime, :lock, mfa, int_id},
          :write
        )

        :ok

      {:unlock, channel_id} ->
        case channel_locked?(channel_id) do
          false ->
            Logger.error("plugin #{int.plugin} trying to unlock an already-unlocked channel")

          plug when plug == int.plugin ->
            :mnesia.write(
              :channellocks,
              {channel_id, datetime, :unlock, nil, int_id},
              :write
            )

            :ok

          plug when plug != int.plugin ->
            raise "plugin #{int.plugin} trying to take a lock from #{plug}"
        end

      nil ->
        # do nothing
        :ok
    end
  end

  @impl GenServer
  def terminate(reason, _state) do
    # DEBUG
    IO.puts("Interact exiting, reason: #{inspect(reason, pretty: true)}")

    :mnesia.stop()

    :ok
  end

  defp make_or_get_table!(name, opts) do
    case :mnesia.create_table(name, opts) do
      {:atomic, id} ->
        id

      {:aborted, {:already_exists, id}} ->
        id
    end
  end
end
