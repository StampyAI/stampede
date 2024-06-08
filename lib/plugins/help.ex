defmodule Plugins.Help do
  @moduledoc false
  require Logger
  use TypeCheck
  alias Stampede, as: S
  require S.ResponseToPost
  use Plugin

  # TODO: make all except ping only respond to admins

  @impl Plugin
  def usage() do
    [
      {"help", "(main help)"},
      {"help [plugin]", "(describes plugin)"}
    ]
  end

  @impl Plugin
  def description() do
    "Describes how the bot can be used. You're using it right now!"
  end

  @impl Plugin
  @spec! respond(SiteConfig.t(), S.MsgReceived.t()) :: nil | S.ResponseToPost.t()
  def respond(_cfg, msg) when not Plugin.is_bot_invoked(msg), do: nil

  def respond(cfg, msg) when Plugin.is_bot_invoked(msg) do
    case msg.body do
      "help" ->
        txt =
          [
            "Here are the available plugins! Learn about any of them with ",
            {:source, "help [plugin]"},
            "\n\n",
            {{:list, :dotted},
             cfg.plugs
             |> Enum.map(fn
               plug ->
                 s = SiteConfig.trim_plugin_name(plug)

                 [
                   {:bold, s},
                   ":  ",
                   plug.description()
                 ]
                 |> List.flatten()
             end)}
          ]

        S.ResponseToPost.new(
          confidence: 10,
          text: txt,
          origin_msg_id: msg.id,
          why: ["They pinged so I ponged!"]
        )

      _ ->
        nil
    end
  end
end
