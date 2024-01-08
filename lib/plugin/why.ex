defmodule Plugin.Why do
  use TypeCheck
  require Stampede.Response
  alias TypeCheck.Internals.UserTypes.Stampede.Response
  alias Stampede, as: S
  alias S.{Msg, Response, Interaction}
  require Interaction

  use Plugin

  @impl Plugin
  def is_at_module(cfg, msg) do
    # Should we process the message?
    text =
      SiteConfig.fetch!(cfg, :prefix)
      |> S.strip_prefix(msg.body)

    if text do
      {:cleaned, text}
    else
      false
    end
  end

  @spec! process_msg(SiteConfig.t(), S.Msg.t()) :: nil | S.Response.t()
  def process_msg(cfg, msg) do
    valid_confidence = 10

    at_module =
      ~r/[Ww]h(?:(?:y did)|(?:at made)) you say th(?:(?:at)|(?:is))(?P<specific>,? specifically)?/

    case is_at_module(cfg, msg) do
      false ->
        nil

      {:cleaned, text} when is_binary(text) ->
        if not Regex.match?(at_module, text) do
          nil
        else
          case Map.fetch!(msg, :referenced_msg_id) do
            nil ->
              Response.new(
                confidence: valid_confidence,
                text:
                  "It looks like you're asking about one of my messages, but you didn't reference which one.",
                why: ["User didn't reference any message."]
              )

            ref ->
              # Ok, let's return oa traceback.
              case S.Interact.get_traceback(ref) do
                {:ok, traceback} ->
                  Response.new(
                    confidence: valid_confidence,
                    text: traceback,
                    why: ["User asked why I said something, so I told them."]
                  )

                other ->
                  Response.new(
                    confidence: valid_confidence,
                    text: "Couldn't find an interaction for that message.",
                    why: [
                      "We checked for an interaction from message ",
                      S.pp(ref),
                      " but found nothing. The Interact database returned:\n",
                      S.pp(other)
                    ]
                  )
              end
          end
        end
    end
  end
end
