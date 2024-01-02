defmodule Plugin.Why do
  use TypeCheck
  require Stampede.Response
  alias Stampede, as: S
  alias S.{Msg, Response, Interaction}
  require Interaction

  use Plugin

  @spec! process_msg(SiteConfig.t(), S.Msg.t()) :: nil | S.Response.t()
  def process_msg(cfg, msg) do
    valid_confidence = 10

    at_module =
      ~r/"[Ww]h(?:(?:y did)|(?:at made)) you say th(?:(?:at)|(?:is))(?P<specific>,? specifically)?"/

    # Should we process the message?
    text = S.strip_prefix(SiteConfig.fetch!(cfg, :prefix), msg.body)

    cond do
      not text ->
        nil

      not Map.get(msg, msg.referenced_msg_id) ->
        Response.new(
          confidence: valid_confidence,
          text:
            "It looks like you're asking about one of my messages, but you didn't reference which one.",
          why: ["User didn't reference any message."]
        )

      true ->
        # Ok, let's return a traceback.
        {:ok, traceback} = S.Interact.get_traceback(msg.referenced_msg_id)

        cleaned =
          SiteConfig.fetch!(cfg, :service)
          |> apply(:source_block, [traceback])

        Response.new(
          confidence: valid_confidence,
          text: cleaned,
          why: ["User asked why I said something, so I told them."]
        )
    end
  end
end
