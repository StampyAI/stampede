defmodule StampedeTest do
  use ExUnit.Case
  alias Stampede, as: S
  doctest Stampede

  @dummy_cfg """
    service: dummy
    server_id: testing
    error_channel_id: error
    prefix: "!"
    plugs:
      - Test
  """
  @dummy_cfg_parsed %{
    __struct__: SiteConfig,
    service: :dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test])
  }

  test "basic test plugin" do
    msg = S.Msg.new(
      body: "!ping", channel_id: :t1, author_id: :u1, server_id: :none
    )
    r = Plugin.Test.process_msg(nil, msg)
    assert r.text == "pong!"
  end
  test "SiteConfig load" do
    parsed = SiteConfig.load_from_string(@dummy_cfg)
    assert parsed == @dummy_cfg_parsed
  end
end
