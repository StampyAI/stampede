defmodule Stampede.Tables.ChannelLocks do
  use TypeCheck
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:channel_id, :datetime, :lock_status, :callback, :interaction_id],
    type: :set,
    disc_copies: S.nodes(),
    access_mode: :read_write

  @spec! validate!(%__MODULE__{}) :: %__MODULE__{}
  def validate!(record) when is_struct(record, __MODULE__) do
    TypeCheck.conforms!(record, %__MODULE__{
      channel_id: S.channel_id(),
      datetime: S.timestamp(),
      lock_status: boolean(),
      callback: nil | S.module_function_args(),
      interaction_id: S.interaction_id()
    })
  end
end
