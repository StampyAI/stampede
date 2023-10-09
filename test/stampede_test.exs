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
           Stampede.Application.start(:normal,
             app_id: id,
             installed_services: [],
             services: :none,
             log_to_file: false
           ),
         {:ok, dummy_pid} <-
           D.start_link(plugs: MapSet.new([Plugin.Test, Plugin.Sentience]), app_id: id) do
      {:ok, Map.new(app_pid: app_pid, dummy_pid: dummy_pid)}
    end
  end

  describe "stateless functions" do
    test "strip_prefix text" do
      assert "ping" == S.strip_prefix("!", "!ping")
    end

    test "strip_prefix regex" do
      assert "ping" == S.strip_prefix(~r/(.*) me bro/, "ping me bro")
    end

    test "S.keyword_put_new_if_not_falsy" do
      kw1 = [a: 1, b: 2]
      kw2 = [a: 1, b: 4]
      kw3 = [a: 1, b: 2, c: 3]

      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:a, false)
      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:b, 4)
      assert kw3 == kw1 |> S.keyword_put_new_if_not_falsy(:c, 3) |> Enum.sort()
    end

    test "basic test plugin" do
      msg =
        S.Msg.new(
          body: "!ping",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      r = Plugin.Test.process_msg(nil, msg)
      assert r.text == "pong!"

      msg =
        S.Msg.new(
          body: "!raise",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      try do
        Plugin.Test.process_msg(nil, msg)
      rescue
        e ->
          assert is_struct(e, SillyError)
      end
    end

    test "dummy channel_buffers" do
      example_history = %{
        c1: {{:a1, "m1"}, {:a2, "m2"}},
        c2: {{:a3, "m3"}, {:a3, "m4"}}
      }

      assert D.channel_buffers_append(example_history, {:c2, :a4, "m5"}) == %{
               c1: {{:a1, "m1"}, {:a2, "m2"}},
               c2: {{:a3, "m3"}, {:a3, "m4"}, {:a4, "m5"}}
             }
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
      assert D.channel_history(s.dummy_pid, :t1) == {{:u1, "!ping"}, {:server, "pong!"}}
    end

    test "dummy ignores messages from other servers" do
      {:ok, s} = setup_dummy(Test03)
      nil = D.send_msg(s.dummy_pid, :t1, :nope, "nada")
      nil = D.send_msg(s.dummy_pid, :t1, :abc, "def")
      assert "pong!" == D.send_msg(s.dummy_pid, :t1, :u1, "!ping") |> Map.fetch!(:text)
      assert nil == D.send_msg(s.dummy_pid, :t1, :u1, "!ping", :another_server)

      assert D.channel_history(s.dummy_pid, :t1) ==
               {{:nope, "nada"}, {:abc, "def"}, {:u1, "!ping"}, {:server, "pong!"}}
    end

    test "dummy + throwing" do
      {:ok, s} = setup_dummy(Test02)
      ## BUG: when error is raised, dummy drops the first member of the channel history tuple.
      ## Can be more clearly seen by enabling this code:

      # nil = D.send_msg(s.dummy_pid, :t1, :nope, "nada")
      # nil = D.send_msg(s.dummy_pid, :t1, :abc, "def")
      {result, log} = with_log(fn -> D.send_msg(s.dummy_pid, :t1, :u1, "!raise") end)
      assert match?(%{text: "*confused beeping*"}, result), "message return still functional"
      assert String.contains?(log, "SillyError"), "SillyError thrown"

      assert %{t1: {{:u1, "!raise"}, {:server, "*confused beeping*"}}} ==
               D.channel_dump(s.dummy_pid)

      assert D.channel_history(s.dummy_pid, :t1) ==
               {{:u1, "!raise"}, {:server, "*confused beeping*"}}
    end
  end
end
