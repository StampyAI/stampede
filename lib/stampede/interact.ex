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

  @type! timestamp :: String.t()
  @type! interaction_id :: integer()

  @typep! channellock_record ::
            {S.channel_id(), timestamp(), boolean(), nil | mfa(), interaction_id()}
  @typep! interaction_record ::
            {interaction_id(), timestamp(), atom(), Msg, Response, S.traceback(),
             S.channel_lock_action()}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(keyword()) :: {:ok, map()}
  @impl GenServer
  def init(_args) do
    IO.puts("Interact: starting")
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
    {:atomic, match} =
      :mnesia.transaction(fn ->
        :mnesia.read(:channellocks, channel_id)
      end)

    case match do
      [{_, _, status, mfa, iid}] when is_boolean(status) ->
        if status, do: {:lock, mfa, iid}, else: false

      [] ->
        false
    end
  end

  def record_interaction!(int) when int.__struct__ == Stampede.Interaction do
    {:atomic, _} =
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

        :ok = do_channel_lock!(int, datetime, t_id)

        new_row = {t_id, datetime, plugin, msg, response, trace, channel_lock}

        :ok = do_write_interaction!(new_row)

        IO.puts("Interact: writing interaction row:\n  #{new_row}")
      end)

    :ok
  end

  @spec! do_channel_lock!(%S.Interaction{}, String.t(), integer()) :: :ok
  def do_channel_lock!(int, datetime, int_id) do
    IO.puts(
      "Interact: checking channel lock: #{{int, datetime, int_id} |> inspect(pretty: true)}"
    )

    {:atomic, result} =
      :mnesia.transaction(fn ->
        case int.channel_lock do
          new_lock = {:lock, channel_id, mfa} ->
            case channel_locked?(channel_id) do
              false ->
                false

              {:lock, plug, _iid} when is_atom(plug) ->
                if plug == int.response.origin_plug do
                  new_lock
                else
                  raise(
                    "plugin #{int.plugin} trying to lock an already-locked channel owned by #{plug}"
                  )
                end
            end

            new_row =
              {channel_id, datetime, true, mfa, int_id}

            do_write_channellock!(new_row)
            IO.puts("Interact: writing channel lock:\n  #{new_row |> inspect(pretty: true)}")

            :ok

          {:unlock, channel_id} ->
            case channel_locked?(channel_id) do
              false ->
                Logger.error("plugin #{int.plugin} trying to unlock an already-unlocked channel")

              plug when plug == int.plugin ->
                new_row =
                  {channel_id, datetime, false, nil, int_id}

                do_write_channellock!(new_row)

                IO.puts("Interact: writing channel lock:\n  #{new_row |> inspect(pretty: true)}")
                :ok

              plug when plug != int.plugin ->
                raise "plugin #{int.plugin} trying to take a lock from #{plug}"
            end

          nil ->
            # do nothing
            IO.puts("Interact: channel lock noop")
            :ok
        end
      end)

    result
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

  @spec! do_write_channellock!(channellock_record()) :: :ok
  defp do_write_channellock!(record) do
    {:atomic, _} =
      :mnesia.transaction(fn ->
        :mnesia.write(
          :channellocks,
          record,
          :write
        )
      end)

    :ok
  end

  @spec! do_write_interaction!(interaction_record()) :: :ok
  defp do_write_interaction!(record) do
    {:atomic, _} =
      :mnesia.transaction(fn ->
        :mnesia.write(
          :interactions,
          record,
          :write
        )
      end)

    :ok
  end
end
