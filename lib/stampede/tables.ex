defmodule Stampede.Tables do
  # Manage various Mnesia tables. Generally avoiding keeping business logic here
  @moduledoc false
  @compile [:bin_opt_info, :recv_opt_info]
  require Logger
  use TypeCheck
  alias Stampede, as: S
  alias S.Tables.{Ids, Interactions, ChannelLocks}

  @mnesia_tables [Ids, Interactions, ChannelLocks]
  def mnesia_tables(), do: @mnesia_tables

  def init(args) do
    clear_state = Keyword.fetch!(args, :clear_state)
    Logger.debug("Tables: starting")

    # NOTE: issue #23: this should be done with Memento.stop() and Memento.start()
    # However, Memento.start() hands back control before Mnesia is done starting.
    # Will submit a fix to Memento
    _ = Application.stop(:mnesia)
    :ok = ensure_schema_exists(S.nodes())
    {:ok, _} = Application.ensure_all_started(:mnesia)
    # # DEBUG
    # Memento.info()
    # Memento.Schema.info()
    :ok = ensure_tables_exist(@mnesia_tables)

    if clear_state do
      :ok = clear_all_tables()
    end

    :ok
  end

  @spec! transaction!((... -> any())) :: any()
  def transaction!(f) do
    Memento.Transaction.execute!(f, 10)
  end

  @spec! transaction_sync!((... -> any())) :: any()
  def transaction_sync!(f) do
    Memento.Transaction.execute_sync!(f, 10)
  end

  def clear_all_tables() do
    Logger.info("Tables: clearing all tables for #{Stampede.compilation_environment()}")

    @mnesia_tables
    |> Enum.each(fn t ->
      case Memento.Table.clear(t) do
        :ok -> :ok
        e = {:error, _reason} -> raise e
      end
    end)

    :ok
  end

  def ensure_schema_exists(nodes) when is_list(nodes) and nodes != [] do
    # NOTE: failing with multi-node list only returns the first node in error
    n1 = hd(nodes)

    case Memento.Schema.create(nodes) do
      {:error, {^n1, {:already_exists, ^n1}}} ->
        :ok

      :ok ->
        :ok

      other ->
        raise "Memento schema creation error: #{S.pp(other)}"
    end
  end

  @spec! ensure_tables_exist(nonempty_list(atom())) :: :ok
  def ensure_tables_exist(ll) do
    do_ensure_tables_exist(ll, [])
  end

  defp do_ensure_tables_exist([], done) do
    :ok =
      Memento.wait(
        done,
        :timer.seconds(5)
      )
  end

  defp do_ensure_tables_exist(ll = [t | rest], done) do
    case Memento.Table.create(t) do
      :ok ->
        :ok

      {:error, {:already_exists, ^t}} ->
        :ok

      {:error, {:node_not_running, _}} ->
        :retry

      {:error, :mmesia_stopped} ->
        :mnesia_stopped

      other ->
        raise "Memento table creation error: #{S.pp(other)}"
    end
    |> case do
      :ok ->
        # DEBUG
        Memento.Table.info(t)

        do_ensure_tables_exist(rest, [t | done])

      :retry ->
        do_ensure_tables_exist(ll, done)
    end
  end
end
