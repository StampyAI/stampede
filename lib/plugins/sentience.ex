defmodule Plugins.Sentience do
  use TypeCheck
  alias Stampede, as: S
  require S.ResponseToPost

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
  @spec! respond(SiteConfig.t(), S.MsgReceived.t()) :: nil | S.ResponseToPost.t()
  def respond(_cfg, msg) when not Plugin.is_bot_invoked(msg), do: nil

  def respond(_cfg, msg = %S.MsgReceived{id: msg_id}) when Plugin.is_bot_invoked(msg) do
    S.ResponseToPost.new(
      confidence: 1,
      text: S.confused_response(),
      origin_msg_id: msg_id,
      why: ["I didn't have any better ideas."]
    )
  end
end
