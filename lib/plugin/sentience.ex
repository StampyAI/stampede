defmodule Plugin.Sentience do
  use TypeCheck
  alias Stampede, as: S
  require S.Response

  use Plugin

  @impl Plugin
  def usage() do
    [
      {"gibjbjgfirifjg", S.confused_response()}
    ]
  end

  @impl Plugin
  def description() do
    "This plugin only responds when Stampede was specifically requested, but all other plugins failed."
  end

  @impl Plugin
  def query(cfg, msg), do: Plugin.default_predicate(cfg, msg, {:respond, msg.id})

  @impl Plugin
  @spec! respond(msg_id :: S.msg_id()) :: nil | S.Response.t()
  def respond(msg_id) do
    S.Response.new(
      confidence: 1,
      text: S.confused_response(),
      origin_msg_id: msg_id,
      why: ["I didn't have any better ideas."]
    )
  end
end
