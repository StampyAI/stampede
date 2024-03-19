defmodule Stampede.TableIds do
  alias Stampede, as: S
  use TypeCheck

  use Memento.Table,
    attributes: [:table_name, :last_id],
    type: :set,
    disc_copies: S.nodes(),
    access_mode: :read_write,
    storage_properties: [
      ets: [
        write_concurrency: true,
        read_concurrency: true,
        decentralized_counters: true
      ]
    ]

  use GenServer
  require Logger

  @typep! mod_state :: nil | []

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(any()) :: {:ok, mod_state()}
  @impl GenServer
  def init(_args \\ []) do
    Logger.debug("TableIds: starting")
    _ = Memento.stop()
    :ok = S.ensure_schema_exists(S.nodes())
    :ok = Memento.start()
    # # DEBUG
    # Memento.info()
    # Memento.Schema.info()
    :ok = S.ensure_tables_exist([__MODULE__])

    {:ok, nil}
  end

  def reserve_id(table_name) do
    :mnesia.dirty_update_counter(__MODULE__, table_name, 1)
  end
end
