defmodule Plugin.Why do
  use TypeCheck
  require Stampede.Response
  alias Plugin.Why.Debugging
  alias TypeCheck.Internals.UserTypes.Stampede.Response
  alias Stampede, as: S
  alias S.{Msg, Response, Interaction}
  require Interaction

  use Plugin

  def msg_fail(), do: "Couldn't find an interaction for that message."

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
                origin_msg_id: msg.id,
                why: ["User didn't reference any message."]
              )

            ref ->
              # Ok, let's return a traceback.
              case S.Interact.get_traceback(ref) do
                {:ok, traceback} ->
                  Response.new(
                    confidence: valid_confidence,
                    text: traceback,
                    origin_msg_id: msg.id,
                    why: ["User asked why I said something, so I told them."]
                  )

                other ->
                  Response.new(
                    confidence: valid_confidence,
                    text: msg_fail(),
                    origin_msg_id: msg.id,
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

  defmodule Debugging do
    def probably_a_traceback(str) when is_binary(str),
      do: String.match?(str, ~r/We asked/)
  end
end
