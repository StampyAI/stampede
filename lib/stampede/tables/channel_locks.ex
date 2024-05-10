defmodule Stampede.Tables.ChannelLocks do
  use TypeCheck
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:channel_id, :datetime, :lock_status, :callback, :interaction_id],
    index: [:interaction_id],
    type: :set,
    disc_copies: S.nodes(),
    access_mode: :read_write,
    storage_properties: [
      ets: [
        write_concurrency: :auto,
        read_concurrency: true,
        decentralized_counters: true
      ]
    ]

  @spec! validate!(%__MODULE__{}) :: %__MODULE__{}
  def validate!(record) when is_struct(record, __MODULE__) do
    record
    # |> TypeCheck.conforms!(%__MODULE__{
    #   channel_id: S.channel_id(),
    #   datetime: S.timestamp(),
    #   # TODO: remove
    #   lock_status: true,
    #   # TODO: add next/break options
    #   callback: nil | S.module_function_args(),
    #   interaction_id: S.interaction_id()
    # })
  end
end
