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
    plugs =
      SiteConfig.get_plugs(cfg)

    case summon_type(msg.body) do
      :list_plugins ->
        txt =
          [
            "Here are the available plugins! Learn about any of them with ",
            {:source, "help [plugin]"},
            "\n\n",
            {{:list, :dotted},
              plugs
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

      {:specific, requested_name} ->
        downcase = requested_name |> String.downcase()

        Enum.find(plugs, nil, fn full_atom ->
          downcase == full_atom |> SiteConfig.trim_plugin_name() |> String.downcase()
        end)
        |> case do
          nil ->
            S.ResponseToPost.new(
              confidence: 10,
              text: [
                "Couldn't find a module named #{requested_name}. Possible modules: ",
                Enum.map(Plugin.ls(), &inspect/1) |> Enum.intersperse(", ")
              ],
              origin_msg_id: msg.id,
              why: ["They asked for a module that didn't exist."]
            )

          found ->
            S.ResponseToPost.new(
              confidence: 10,
              text: [
                found.description_long(),
                "\n\nUsage:\n",
                Plugin.decorate_usage(cfg, found)
              ],
              origin_msg_id: msg.id,
              why: ["They asked for help with a module."]
            )
        end

      nil ->
        nil
    end
  end

  def summon_type(body) do
    if Regex.match?(~r/^(help$|list plugin(s)?)/, body) do
      :list_plugins
    else
      case Regex.run(~r/^help (\w+)/, body, capture: :all_but_first) do
        [plug] ->
          {:specific, plug}

        nil ->
          nil
      end
    end
  end
end
