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

      # test channel locks
      "!a" ->
        S.Response.new(
          confidence: 10,
          text: "locked in on #{msg.author_id} awaiting b",
          why: ["Channel lock stage 1"],
          callback: nil,
          channel_lock: {:lock, msg.channel_id, {__MODULE__, :lock_callback, [:b]}}
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

  def lock_callback(_cfg, msg, :b) do
    case msg.content do
      "!b" ->
        S.Response.new(
          confidence: 10,
          text: "b response. awaiting c",
          why: ["Channel lock stage 1"],
          callback: nil,
          channel_lock: {:lock, msg.channel_id, {__MODULE__, :lock_callback, [:c]}}
        )

      other ->
        S.Response.new(
          confidence: 10,
          text: "lock broken by #{msg.author_id}",
          why: ["Unmatched message, #{other}"],
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )
    end
  end

  def lock_callback(_cfg, msg, :c) do
    case msg.content do
      "!c" ->
        S.Response.new(
          confidence: 10,
          text: "c response. interaction done!",
          why: ["Channel lock test done"],
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )

      other ->
        S.Response.new(
          confidence: 10,
          text: "lock broken by #{msg.author_id}",
          why: ["Unmatched message, #{other}"],
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )
    end
  end
end

defmodule SillyError do
  defexception message: "Intentional exception raised"
end

defmodule SillyThrow do
  defexception message: "Intentional throw made"
end
