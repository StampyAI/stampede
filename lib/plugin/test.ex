defmodule Plugin.Test do
  require Logger
  use TypeCheck
  alias Stampede, as: S
  require S.Response
  use Plugin

  @spec! process_msg(any(), S.Msg.t()) :: nil | S.Response.t()
  @impl Plugin
  def process_msg(_cfg, msg) do
    case msg.body do
      "!ping" ->
        S.Response.new(
          confidence: 10,
          text: "pong!",
          why: ["They pinged so I ponged!"]
        )

      "!callback" ->
        num = :rand.uniform(10)

        S.Response.new(
          confidence: 10,
          text: nil,
          why: ["They want to test callbacks."],
          callback: {__MODULE__, :callback_example, [num]}
        )

      "!timeout" ->
        :timer.seconds(11) |> Process.sleep()
        raise "This job should be killed before here"

      "!raise" ->
        raise SillyError

      "!throw" ->
        throw(SillyThrow)

      _ ->
        nil
    end
  end

  def callback_example(_cfg, num) when is_number(num) do
    S.Response.new(
      confidence: 10,
      text: "Called back with number #{num}"
    )
  end
end

defmodule SillyError do
  defexception message: "Intentional exception raised"
end

defmodule SillyThrow do
  defexception message: "Intentional throw made"
end
