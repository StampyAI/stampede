defmodule Stampede.Tables.Interactions do
  @moduledoc false
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  alias Stampede.Events.MsgReceived
  alias Stampede.Events.ResponseToPost
  alias Stampede, as: S

  use Memento.Table,
    attributes: [
      :id,
      :datetime,
      :plugin,
      :posted_msg_id,
      :msg,
      :response,
      :traceback,
      :channel_lock
    ],
    type: :set,
    disc_copies: S.nodes(),
    access_mode: :read_write,
    index: [:datetime, :posted_msg_id],
    storage_properties: [
      ets: [
        :compressed,
        write_concurrency: :auto,
        read_concurrency: true,
        decentralized_counters: true
      ]
    ]

  @spec! validate!(%__MODULE__{}) :: %__MODULE__{}
  def validate!(record) when is_struct(record, __MODULE__) do
    if S.Interact.id_exists?(record.id), do: raise("Interaction already recorded??")

    if S.enable_typechecking?() do
      record
      |> TypeCheck.conforms!(%__MODULE__{
        id: S.interaction_id(),
        datetime: S.timestamp(),
        plugin: module(),
        # This can't be set until the service has posted the message
        posted_msg_id: nil | S.msg_id(),
        msg: MsgReceived.t(),
        response: ResponseToPost.t(),
        traceback: S.Traceback.t(),
        channel_lock: S.channel_lock_action()
      })
    else
      record
    end
  end

  def validate!(record) when not is_struct(record, __MODULE__),
    do: raise("Not a #{__MODULE__} instance.\n" <> S.pp(record))
end
