defmodule Plugin.Test do
  require Logger
  use TypeCheck
  alias Stampede, as: S
  require S.Response
  use Plugin

  # TODO: make all except ping only respond to admins

  @impl Plugin
  def usage() do
    [
      {"ping", "pong!"},
      {"callback", "(shows callback replies work)"},
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

  @spec! process_msg(any(), S.Msg.t()) :: nil | S.Response.t()
  @impl Plugin
  def process_msg(cfg, msg) do
    case is_at_module(cfg, msg) do
      {:cleaned, "ping"} ->
        S.Response.new(
          confidence: 10,
          text: "pong!",
          origin_msg_id: msg.id,
          why: ["They pinged so I ponged!"]
        )

      {:cleaned, "callback"} ->
        num = :rand.uniform(10)

        S.Response.new(
          confidence: 10,
          text: nil,
          origin_msg_id: msg.id,
          why: ["They want to test callbacks."],
          callback: {__MODULE__, :callback_example, [num, msg.id]}
        )

      # test channel locks
      {:cleaned, "a"} ->
        S.Response.new(
          confidence: 10,
          text: "locked in on #{msg.author_id} awaiting b",
          why: ["Channel lock stage 1"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:lock, msg.channel_id, {__MODULE__, :lock_callback, [:b]}}
        )

      {:cleaned, "timeout"} ->
        :timer.seconds(11) |> Process.sleep()
        raise "This job should be killed before here"

      {:cleaned, "raise"} ->
        raise SillyError

      {:cleaned, "throw"} ->
        throw(SillyThrow)

      _ ->
        nil
    end
  end

  def callback_example(_cfg, num, msg_id) when is_number(num) do
    S.Response.new(
      confidence: 10,
      origin_msg_id: msg_id,
      text: "Called back with number #{num}"
    )
  end

  def lock_callback(cfg, msg, :b) do
    case is_at_module(cfg, msg) do
      {:cleaned, "b"} ->
        S.Response.new(
          confidence: 10,
          text: "b response. awaiting c",
          why: ["Channel lock stage 1"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:lock, msg.channel_id, {__MODULE__, :lock_callback, [:c]}}
        )

      other ->
        S.Response.new(
          confidence: 10,
          text: "lock broken by #{msg.author_id}",
          why: ["Unmatched message, #{other |> S.pp()}"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )
    end
  end

  def lock_callback(cfg, msg, :c) do
    case is_at_module(cfg, msg) do
      {:cleaned, "c"} ->
        S.Response.new(
          confidence: 10,
          text: "c response. interaction done!",
          why: ["Channel lock test done"],
          origin_msg_id: msg.id,
          callback: nil,
          channel_lock: {:unlock, msg.channel_id}
        )

      other ->
        S.Response.new(
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
  defexception message: "Intentional exception raised"
end

defmodule SillyThrow do
  defexception message: "Intentional throw made"
end
