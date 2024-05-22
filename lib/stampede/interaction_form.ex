defmodule Stampede.InteractionForm do
  @compile [:bin_opt_info, :recv_opt_info]
  alias Stampede, as: S
  alias S.{Msg, Response}
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(
    # TODO: rename to "chosen_plugin"
    plugin: _ :: any(),
    service: _ :: atom(),
    msg: _ :: Msg.t(),
    response: _ :: Response.t(),
    traceback: [] :: TxtBlock.t(),
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
