defmodule StampedeTest do
  use ExUnit.Case, async: true
  alias Stampede, as: S
  alias Service.Dummy, as: D
  doctest Stampede

  @dummy_cfg """
    service: dummy
    server_id: testing
    error_channel_id: error
    prefix: "!"
    plugs:
      - Test
    app_id: "Test01"
  """
  @dummy_cfg_verified %{
    service: :dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test]),
    app_id: Test01
  }

  describe "stateless functions" do
    test "basic test plugin", _ do
      msg = S.Msg.new(
        body: "!ping", channel_id: :t1, author_id: :u1, server_id: :none
      )
      r = Plugin.Test.process_msg(nil, msg)
      assert r.text == "pong!"
    end
    test "SiteConfig load", _ do
      parsed = SiteConfig.load_from_string(@dummy_cfg)
      verified = SiteConfig.validate!(parsed, SiteConfig.schema_base())
      assert verified == @dummy_cfg_verified
    end
  end
  describe "dummy server" do
    setup %{} do
      id = Test01
      with {:ok, app_pid} <- 
        Stampede.Application.start(:normal, app_id: id),
      {:ok, dummy_pid} <- 
        D.start_link([plugs: MapSet.new([Plugin.Test]), app_id: id]) do
          {:ok, app_pid: app_pid, dummy_pid: dummy_pid}
        end
    end
    test "dummy + ping", s do
      assert nil == D.send_msg(s.dummy_pid, :t1, :u1, "no response")
      assert "pong!" == D.send_msg(s.dummy_pid, :t1, :u1, "!ping") |> Map.fetch!(:text)
    end
  end
end
