defmodule Stampede.Interaction do
  alias Stampede, as: S
  alias S.{Msg, Response}
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(
    msg_responses: _ :: list({Msg, Response}),
    traceback: [] :: iodata() | String.t(),
    channel_lock: nil :: nil | {S.channel_id(), S.module_function_args()}
  )
end

defmodule Stampede.Interact do
  alias Stampede, as: S
  alias S.{Msg, Response}
  use TypeCheck
  use TypeCheck.Defstruct

  use GenServer

  @table :interactions
  @table_options [:named_table]

  defstruct!(
    table_name: _ :: String.t(),
    table_id: _ :: any()
  )

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(keyword()) :: {:ok, map()}
  @impl GenServer
  def init(args) do
    table_name = Keyword.fetch!(args, :table_name)

    table_id =
      table_path(table_name)
      |> acquire_db!()

    {:ok, struct!(__MODULE__, table_id: table_id, table_name: table_id)}
  end

  @impl GenServer
  def terminate(reason, state) do
    count = :ets.info(state.table_id, :size)
    # DEBUG
    IO.puts("Interact exiting, reason: #{inspect(reason, pretty: true)}")

    IO.puts(
      "Interact: Gracefully saving interaction table #{state.table_name} (#{count} entries)"
    )

    path =
      table_path(state.table_name)
      |> String.to_charlist()

    :ok = :ets.tab2file(state.table_id, path, sync: true, extended_info: [:md5sum, :object_count])

    :ok
  end

  defp table_path(name) do
    Path.join("./db/", name <> ".dets")
  end

  def lock_path(name) do
    table_path(name) <> ".lock"
  end

  def acquire_db!(table_name) do
    db = table_path(table_name)
    lock = lock_path(table_name)

    cond do
      S.file_exists(db) and S.file_exists(lock) ->
        db_backup = db <> "_#{DateTime.utc_now() |> DateTime.to_unix()}"

        IO.puts(
          "Interact: old database was left locked, backing up to #{db_backup} and starting clean"
        )

        File.cp!(
          db,
          db_backup
        )

        File.rm!(db)
        File.touch!(lock)
        new_table()

      S.file_exists(db) and not S.file_exists(lock) ->
        IO.puts("Interact: loading old database from #{db}")
        load_table(db)

      not S.file_exists(db) and not S.file_exists(lock) ->
        IO.puts("Interact: no database found, starting a new one at #{db}")
        File.touch!(lock)
        new_table()
    end
  end

  def new_table(),
    do: :ets.new(@table, @table_options)

  def load_table(path) when is_binary(path) do
    {:ok, id} =
      String.to_charlist(path)
      |> :ets.file2tab(verify: true)

    id
  end
end
