defmodule Stampede.Events.InteractionWanted do
  @moduledoc """
  A proposal for an interaction to be given to `Stampede.Interact`, before all details are fleshed out.
  """
  @compile [:bin_opt_info, :recv_opt_info]
  alias Stampede, as: S
  alias S.Events.{MsgReceived, ResponseToPost}
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(
    plugin: _ :: any(),
    service: _ :: atom(),
    msg: _ :: MsgReceived.t(),
    response: _ :: ResponseToPost.t(),
    traceback: _ :: S.Traceback.t(),
    channel_lock: false :: S.channel_lock_action()
  )

  defmacro new(kwargs) do
    quote do
      struct!(
        unquote(__MODULE__),
        unquote(kwargs)
      )
    end
  end
end
