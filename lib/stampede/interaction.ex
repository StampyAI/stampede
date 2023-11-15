defmodule Stampede.Interaction do
  alias Stampede, as: S
  alias S.{Msg, Response}
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(
    plugin: _ :: any(),
    msg: _ :: Msg,
    response: _ :: Response,
    traceback: [] :: iodata() | String.t(),
    channel_lock: false :: S.channel_lock_action()
  )

  defmacro new(kwargs) do
    quote do
      struct!(
        unquote(__MODULE__),
        if unquote(kwargs[:plugin]) do
          unquote(kwargs)
        else
          [{:plugin, __MODULE__} | unquote(kwargs)]
        end
      )
    end
  end
end
