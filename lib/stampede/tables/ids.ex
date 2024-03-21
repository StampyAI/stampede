defmodule Stampede.Tables.Ids do
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

  require Logger

  def reserve_id(table_name) do
    :mnesia.dirty_update_counter(__MODULE__, table_name, 1)
  end
end
