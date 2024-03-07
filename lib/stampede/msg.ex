defmodule Stampede.Msg do
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    id: _ :: S.msg_id(),
    body: _ :: String.t(),
    channel_id: _ :: S.channel_id(),
    author_id: _ :: S.user_id(),
    server_id: _ :: S.server_id(),
    referenced_msg_id: nil :: S.msg_id(),
    service: _ :: module()
  )

  defmacro new(keys) do
    quote do
      struct!(
        unquote(__MODULE__),
        unquote(keys)
        |> Keyword.put_new(:service, __MODULE__)
      )
    end
  end
end
