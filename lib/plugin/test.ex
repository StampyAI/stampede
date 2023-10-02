defmodule Plugin.Test do
  require Logger
  use TypeCheck
  alias Stampede, as: S
  require S.Response
  @spec! process_msg(any(), S.Msg.t()) :: nil | S.Response.t()
  def process_msg(_, msg) do
    case msg.body do
      "!ping" -> S.Response.new(confidence: 10, text: "pong!", why: ["They pinged so I ponged!"])
      _ -> nil
    end
  end
end
