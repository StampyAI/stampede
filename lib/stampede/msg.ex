defmodule Stampede.Msg do
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    body: _ :: String.t(),
    channel_id: _ :: S.channel_id(),
    author_id: _ :: S.user_id(),
    server_id: _ :: S.server_id()
  )
  def new(keys), do: struct!(__MODULE__, keys)
end
