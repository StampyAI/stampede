defmodule Plugins.Sentience do
  @moduledoc false
  use TypeCheck
  alias Stampede, as: S
  alias S.Events.{ResponseToPost, MsgReceived}
  require ResponseToPost

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
  @spec! respond(SiteConfig.t(), MsgReceived.t()) :: nil | ResponseToPost.t()
  def respond(_cfg, msg) when not Plugin.is_bot_invoked(msg), do: nil

  def respond(_cfg, msg = %MsgReceived{id: msg_id}) when Plugin.is_bot_invoked(msg) do
    ResponseToPost.new(
      confidence: 1,
      text: S.confused_response(),
      origin_msg_id: msg_id,
      why: ["I didn't have any better ideas."]
    )
  end
end
