defmodule Plugin.Why do
  use TypeCheck
  require Stampede.Response
  alias Plugin.Why.Debugging
  alias Stampede, as: S
  alias S.{Response, InteractionForm}
  require InteractionForm

  use Plugin

  def msg_fail(msg), do: "Couldn't find an interaction for message #{inspect(msg)}."

  def at_module_regex(),
    do:
      ~r/[Ww]h(?:(?:y did)|(?:at made)) you say th(?:(?:at)|(?:is))(?P<specific>,? specifically)?/

  @impl Plugin
  def usage() do
    [
      "Magic phrase: `(why did/what made) you say (that/this)[, specifically][?]`",
      {"why did you say that? (tagging bot message)", "(reason for posting this message)"},
      {"what made you say that, specifically? (tagging bot message)",
       "(full traceback of the creation of this message)"},
      {"why did you say this (tagging unknown message)", msg_fail("some_msg_id")}
    ]
  end

  @impl Plugin
  def description() do
    """
    Explains the bot's reasoning for posting a particular message, if it remembers it. Summoned with "why did you say that?" for a short summary. Remember to identify the message you want; on Discord, this is the "reply" function. If you want a full traceback, ask with "specifically".

    Full regex: #{at_module_regex() |> Regex.source()}
    """
  end

  @impl Plugin
  @spec! respond(SiteConfig.t(), S.Msg.t()) :: nil | S.Response.t()
  def respond(_cfg, msg) when not Plugin.is_bot_invoked(msg), do: nil
  def respond(cfg, msg) when Plugin.is_bot_invoked(msg) do
    if Regex.match?(at_module_regex(), msg.body) do
      valid_confidence = 10

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
                text: traceback |> TxtBlock.to_str_list(cfg.service),
                origin_msg_id: msg.id,
                why: ["User asked why I said something, so I told them."]
              )

            other ->
              Response.new(
                confidence: valid_confidence,
                text: msg_fail(ref),
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
    else
      nil
    end
  end

  defmodule Debugging do
    def probably_a_traceback(str) when is_binary(str),
      do: String.contains?(str, "We asked")

    def probably_a_missing_interaction(str) when is_binary(str),
      do: String.contains?(str, "Couldn't find an interaction")
  end
end
