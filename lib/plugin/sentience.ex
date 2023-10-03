defmodule Plugin.Sentience do
  use TypeCheck
  alias Stampede, as: S
  require S.Response
  @spec! process_msg(SiteConfig.t(), S.Msg.t()) :: nil | S.Response.t()
  def process_msg(cfg, msg) do
    if S.strip_prefix(cfg.prefix, msg.body) do
      S.Response.new(confidence: 1, text: "*confused beeping*", why: ["I didn't have any better ideas."])
    else
      nil
    end
  end

end
