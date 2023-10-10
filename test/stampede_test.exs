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
    app_id: "Test01"
  }
  setup context do
    if context[:dummy] do
      id = context[:test]

      with {:ok, app_pid} <-
             Stampede.Application.start(:normal,
               app_id: id,
               installed_services: [],
               services: :none,
               log_to_file: false
             ),
           {:ok, dummy_pid} <-
             D.start_link(plugs: MapSet.new([Plugin.Test, Plugin.Sentience]), app_id: id) do
        Map.new(app_pid: app_pid, dummy_pid: dummy_pid)
      end
    else
      Map.new()
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
      kw2 = [a: 1, b: 2, c: 3]

      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:a, false)
      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:b, 4)
      assert kw2 == kw1 |> S.keyword_put_new_if_not_falsy(:c, 3) |> Enum.sort()
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
    @describetag :dummy
    test "ping", s do
      assert nil == D.send_msg(s.dummy_pid, :t1, :u1, "no response")
      assert "pong!" == D.send_msg(s.dummy_pid, :t1, :u1, "!ping") |> Map.fetch!(:text)

      assert D.channel_history(s.dummy_pid, :t1) ==
               {{:u1, "no response"}, {:u1, "!ping"}, {:server, "pong!"}}
    end

    test "ignores messages from other servers", s do
      nil = D.send_msg(s.dummy_pid, :t1, :nope, "nada")
      nil = D.send_msg(s.dummy_pid, :t1, :abc, "def")
      assert "pong!" == D.send_msg(s.dummy_pid, :t1, :u1, "!ping") |> Map.fetch!(:text)
      assert nil == D.send_msg(s.dummy_pid, :t1, :u1, "!ping", :another_server)

      assert D.channel_history(s.dummy_pid, :t1) ==
               {{:nope, "nada"}, {:abc, "def"}, {:u1, "!ping"}, {:server, "pong!"}}
    end

    test "throwing", s do
      {result, log} = with_log(fn -> D.send_msg(s.dummy_pid, :t1, :u1, "!raise") end)
      assert match?(%{text: "*confused beeping*"}, result), "message return still functional"
      assert String.contains?(log, "SillyError"), "SillyError thrown"

      assert %{t1: {{:u1, "!raise"}, {:server, "*confused beeping*"}}} ==
               D.channel_dump(s.dummy_pid)

      assert D.channel_history(s.dummy_pid, :t1) ==
               {{:u1, "!raise"}, {:server, "*confused beeping*"}}
    end
  end

  describe "dummy server channels" do
    @describetag :dummy
    test "one message", s do
      D.send_msg(s.dummy_pid, :t1, :u1, "lol")
      assert D.channel_history(s.dummy_pid, :t1) == {{:u1, "lol"}}
    end

    test "many messages", s do
      dummy_messages =
        0..9
        |> Enum.map(fn x ->
          {:t1, :u1, "#{x}"}
        end)
        |> Enum.map(fn {a, u, m} ->
          D.send_msg(s.dummy_pid, a, u, m)
          {u, m}
        end)

      assert D.channel_history(s.dummy_pid, :t1) == List.to_tuple(dummy_messages)
    end
  end
end
