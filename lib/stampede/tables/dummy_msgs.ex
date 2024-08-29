defmodule Stampede.Tables.DummyMsgs do
  @moduledoc false
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  alias Stampede, as: S

  use Memento.Table,
    attributes: [:id, :datetime, :server_id, :channel, :user, :body, :referenced_msg_id],
    type: :ordered_set,
    access_mode: :read_write,
    autoincrement: true,
    storage_properties: [
      ets: [
        write_concurrency: :auto,
        read_concurrency: true,
        decentralized_counters: true
      ]
    ]

  def new(id, {server_id, channel, user, formatted_text, ref}) do
    [
      id: id,
      datetime: S.time(),
      server_id: server_id,
      channel: channel,
      user: user,
      body: formatted_text,
      referenced_msg_id: ref
    ]
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  def validate!(record) when is_struct(record, __MODULE__) do
    if S.enable_typechecking?() do
      record
      |> TypeCheck.conforms!(%__MODULE__{
        id: non_neg_integer(),
        datetime: S.timestamp(),
        server_id: atom(),
        channel: atom(),
        user: atom(),
        body: any(),
        referenced_msg_id: nil | integer()
      })
    else
      record
    end
  end

  def validate!(record) when not is_struct(record, __MODULE__),
    do: raise("Not a #{__MODULE__} instance.\n" <> S.pp(record))
end
