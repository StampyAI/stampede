defmodule Stampede.Tables do
  require Logger
  use TypeCheck
  alias Stampede, as: S
  alias S.Tables.{Ids, Interactions, ChannelLocks}

  @mnesia_tables [Ids, Interactions, ChannelLocks]

  def init(args) do
    clear_state = Keyword.fetch!(args, :clear_state)
    Logger.debug("Tables: starting")
    _ = Memento.stop()
    :ok = ensure_schema_exists(S.nodes())
    :ok = Memento.start()
    # # DEBUG
    # Memento.info()
    # Memento.Schema.info()
    :ok = ensure_tables_exist(@mnesia_tables)

    if clear_state == true do
      :ok = clear_all_tables()
    end

    :ok
  end

  def clear_all_tables() do
    Logger.info("Tables: clearing all tables for #{Mix.env()}")

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

  @spec! ensure_tables_exist(list(atom())) :: :ok
  def ensure_tables_exist(tables) when is_list(tables) do
    Enum.each(tables, fn t ->
      case Memento.Table.create(t) do
        :ok ->
          :ok

        {:error, {:already_exists, ^t}} ->
          :ok

        other ->
          raise "Memento table creation error: #{S.pp(other)}"
      end

      # DEBUG
      Memento.Table.info(t)
    end)

    :ok =
      Memento.wait(
        tables,
        :timer.seconds(5)
      )
  end
end
