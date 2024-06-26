defmodule Plugins.Test do
  @moduledoc false
  require Logger
  use TypeCheck
  alias Stampede, as: S
  alias S.Events.{ResponseToPost, MsgReceived}
  require ResponseToPost
  use Plugin

  # TODO: make all except ping only respond to admins

  @impl Plugin
  def usage() do
    [
      {"ping", "pong!"},
      {"callback", "(shows callback replies work)"},
      {"callback fail", "(shows callbacks can give up)"},
      {"a", "(shows channel locks work)"},
      {"timeout", "(shows that plugins which time out won't disrupt other plugins)"},
      {"raise", "(raises an error which should be reported)"},
      {"throw", "(causes a throw which should be reported)"},
      {"formatting", "(tests plugin text formatting)"}
    ]
  end

  @impl Plugin
  def description() do
    "A set of functions for testing Stampede functionality."
  end

  @impl Plugin
  @spec! respond(SiteConfig.t(), MsgReceived.t()) :: nil | ResponseToPost.t()
  def respond(_cfg, msg) when not Plugin.is_bot_invoked(msg), do: nil

  def respond(_cfg, msg) when Plugin.is_bot_invoked(msg) do
    case msg.body do
      "ping" ->
        ResponseToPost.new(
          confidence: 10,
          text: "pong!",
          origin_msg_id: msg.id,
          why: ["They pinged so I ponged!"]
        )

      "callback" ->
        num = :rand.uniform(10)

        ResponseToPost.new(
          confidence: 10,
          text: nil,
          origin_msg_id: msg.id,
          why: ["They want to test callbacks."],
          callback: {__MODULE__, :callback_example, [num, msg.id]}
        )

      "callback fail" ->
        ResponseToPost.new(
          confidence: 10,
          text: nil,
          origin_msg_id: msg.id,
          why: ["They want to test callback fails."],
          callback: {__MODULE__, :callback_example, [:fail, msg.id]}
        )

      # test channel locks
      "a" ->
        ResponseToPost.new(
          confidence: 10,
          text: "locked in on #{msg.author_id} awaiting b",
          why: ["Channel lock stage 1"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:lock, msg.channel_id, {__MODULE__, :lock_callback, [:b]}}
        )

      "timeout" ->
        :timer.seconds(11) |> Process.sleep()
        raise "This job should be killed before here"

      "raise" ->
        raise SillyError

      "throw" ->
        throw(SillyThrow)

      _ ->
        nil
    end
  end

  def callback_example(:fail, msg_id) do
    ResponseToPost.new(
      confidence: 0,
      origin_msg_id: msg_id,
      text: "THIS SHOULDNT BE SHOWN",
      why: "Testing callbacks that fail"
    )
  end

  def callback_example(num, msg_id) when is_number(num) do
    ResponseToPost.new(
      confidence: 10,
      origin_msg_id: msg_id,
      text: "Called back with number #{num}",
      why: "Testing callbacks"
    )
  end

  def lock_callback(msg, :b) do
    case msg.body do
      "b" ->
        ResponseToPost.new(
          confidence: 10,
          text: "b response. awaiting c",
          why: ["Channel lock stage 1"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:lock, msg.channel_id, {__MODULE__, :lock_callback, [:c]}}
        )

      other ->
        ResponseToPost.new(
          confidence: 10,
          text: "lock broken by #{msg.author_id}",
          why: ["Unmatched message, #{other |> S.pp()}"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )
    end
  end

  def lock_callback(msg, :c) do
    case msg.body do
      "c" ->
        ResponseToPost.new(
          confidence: 10,
          text: "c response. interaction done!",
          why: ["Channel lock test done"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )

      other ->
        ResponseToPost.new(
          confidence: 10,
          text: "lock broken by #{msg.author_id}",
          why: ["Unmatched message, #{other}"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )
    end
  end
end

defmodule SillyError do
  @moduledoc false
  defexception message: "Intentional exception raised"
end

defmodule SillyThrow do
  @moduledoc false
  defexception message: "Intentional throw made"
end
