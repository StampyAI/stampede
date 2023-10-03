defmodule StampedeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
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
      - Sentience
    app_id: "Test01"
  """
  @dummy_cfg_verified %{
    service: :dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test, Plugin.Sentience]),
    app_id: Test01
  }
  def setup_dummy(id) do
    with {:ok, app_pid} <- 
      # BUG: probably application cant be run together
      Stampede.Application.start(:normal, app_id: id),
      {:ok, dummy_pid} <- 
        D.start_link([plugs: MapSet.new([Plugin.Test, Plugin.Sentience]), app_id: id]) do
      {:ok, Map.new(app_pid: app_pid, dummy_pid: dummy_pid)}
    end
  end

  describe "stateless functions" do
    test "strip_prefix text" do
      assert "ping" == S.strip_prefix("!", "!ping")
    end
    test "strip_prefix regex" do
      assert "ping" == S.strip_prefix(~r/^!(.*)/, "!ping")
    end
    test "basic test plugin", _ do
      msg = S.Msg.new(
        body: "!ping", channel_id: :t1, author_id: :u1, server_id: :none
      )
      r = Plugin.Test.process_msg(nil, msg)
      assert r.text == "pong!"
      msg = S.Msg.new(
        body: "!raise", channel_id: :t1, author_id: :u1, server_id: :none
      )
      try do
        Plugin.Test.process_msg(nil, msg)
      rescue
        e -> 
          assert is_struct(e, SillyError)
      end
    end
    test "SiteConfig load", _ do
      parsed = SiteConfig.load_from_string(@dummy_cfg)
      verified = SiteConfig.validate!(parsed, SiteConfig.schema_base())
      assert verified == @dummy_cfg_verified
    end
  end
  describe "dummy server" do
    test "dummy + ping" do
      {:ok, s} = setup_dummy(Test01)
      assert nil == D.send_msg(s.dummy_pid, :t1, :u1, "no response")
      assert "pong!" == D.send_msg(s.dummy_pid, :t1, :u1, "!ping") |> Map.fetch!(:text)
    end
    test "dummy + throwing" do
      {:ok, s} = setup_dummy(Test02)
      {result, log} = with_log(fn -> D.send_msg(s.dummy_pid, :t1, :u1, "!raise") end)
      assert match?(%{text: "*confused beeping*"}, result), "message return still functional"
      assert String.contains?(log, "SillyError"), "SillyError thrown"
    end
  end
end
