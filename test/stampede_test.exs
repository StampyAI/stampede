defmodule StampedeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Stampede, as: S
  alias Service.Dummy, as: D
  doctest Stampede

  @confused_response S.confused_response()

  @dummy_cfg """
    service: dummy
    server_id: testing
    error_channel_id: error
    prefix: "!"
    plugs:
      - Test
      - Sentience
  """
  @dummy_cfg_verified %{
    service: Service.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test, Plugin.Sentience])
  }
  setup_all do
    %{
      app_pid:
        Stampede.Application.start(:normal,
          installed_services: [:dummy],
          services: [:dummy],
          log_to_file: false,
          serious_error_channel_service: :disabled
        )
    }
  end

  setup context do
    id = context.test

    if Map.get(context, :dummy, false) do
      :ok = D.new_server(id, MapSet.new([Plugin.Test, Plugin.Sentience]))
    end

    %{id: id}
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
      catch
        _t, e ->
          assert is_struct(e, SillyError)
      end

      msg =
        S.Msg.new(
          body: "!throw",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      try do
        Plugin.Test.process_msg(nil, msg)
      catch
        _t, e ->
          assert e == SillyThrow
      end

      msg =
        S.Msg.new(
          body: "!callback",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      %{callback: {m, f, a}} = Plugin.Test.process_msg(nil, msg)

      cbr = apply(m, f, [nil | a])
      assert String.starts_with?(cbr.text, "Called back with")
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
      verified = SiteConfig.load_from_string(@dummy_cfg)
      assert verified == @dummy_cfg_verified
    end

    test "msg splitting functions" do
      split_size = 100
      max_pieces = 10

      correctly_split_msg =
        1..max_pieces
        |> Enum.map(fn _ -> S.random_string_weak(split_size) end)

      large_msg = Enum.join(correctly_split_msg) <> S.random_string_weak(div(split_size, 5))

      smol_msg = "lol"

      assert correctly_split_msg == S.text_chunk(large_msg, split_size, max_pieces)
      assert [smol_msg] == S.text_chunk(smol_msg, split_size, max_pieces)
    end
  end

  describe "dummy server" do
    @describetag :dummy
    test "ping", s do
      assert nil == D.send_msg(s.id, :t1, :u1, "no response")
      assert "pong!" == D.send_msg(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)

      assert D.channel_history(s.id, :t1) ==
               {{:u1, "no response"}, {:u1, "!ping"}, {:server, "pong!"}}
    end

    test "ignores messages from other servers", s do
      nil = D.send_msg(s.id, :t1, :nope, "nada")
      nil = D.send_msg(s.id, :t1, :abc, "def")
      assert "pong!" == D.send_msg(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)
      assert nil == D.send_msg(:shouldnt_exist, :t1, :u1, "!ping")

      assert D.channel_history(s.id, :t1) ==
               {{:nope, "nada"}, {:abc, "def"}, {:u1, "!ping"}, {:server, "pong!"}}
    end

    test "plugin raising", s do
      {result, log} = with_log(fn -> D.send_msg(s.id, :t1, :u1, "!raise") end)
      assert match?(%{text: @confused_response}, result), "message return not functional"
      assert String.contains?(log, "SillyError"), "SillyError not thrown"

      assert D.channel_history(s.id, :error)
             |> inspect()
             |> String.contains?("SillyError"),
             "error not being logged"

      assert D.channel_history(s.id, :t1) ==
               {{:u1, "!raise"}, {:server, @confused_response}}
    end

    test "plugin throwing", s do
      {result, log} = with_log(fn -> D.send_msg(s.id, :t1, :u1, "!throw") end)
      assert match?(%{text: @confused_response}, result), "message return not functional"
      assert String.contains?(log, "SillyThrow"), "SillyThrow not thrown"

      assert D.channel_history(s.id, :error)
             |> inspect()
             |> String.contains?("SillyThrow"),
             "error not being logged"

      assert D.channel_history(s.id, :t1) ==
               {{:u1, "!throw"}, {:server, @confused_response}}
    end

    test "plugin with callback", s do
      r = D.send_msg(s.id, :t1, :u1, "!callback")
      assert String.starts_with?(r.text, "Called back with")
    end

    test "plugin timeout", s do
      r = D.send_msg(s.id, :t1, :u1, "!timeout")
      assert r.text == @confused_response
    end

    test "sustained interaction", s do
      assert "locked in on admin awaiting b" ==
               D.send_msg(s.id, :t1, :admin, "!a") |> Map.fetch!(:text)

      assert "b response. awaiting c" == D.send_msg(s.id, :t1, :admin, "!b") |> Map.fetch!(:text)
      assert nil == D.send_msg(s.id, :t2, :admin, "unrelated chatter") |> Map.fetch!(:text)

      assert "b response. interaction done!" ==
               D.send_msg(s.id, :t1, :admin, "!c") |> Map.fetch!(:text)

      assert "a response. awaiting b" == D.send_msg(s.id, :t1, :admin, "!a") |> Map.fetch!(:text)
      assert "abandoning query" == D.send_msg(s.id, :t1, :admin, "interrupt") |> Map.fetch!(:text)

      assert "a response. awaiting b" == D.send_msg(s.id, :t1, :admin, "!a") |> Map.fetch!(:text)
      assert nil == D.send_msg(s.id, :t1, :some_other_shmuck, "!b") |> Map.fetch!(:text)
    end
  end

  describe "dummy server channels" do
    @describetag :dummy
    test "one message", s do
      D.send_msg(s.id, :t1, :u1, "lol")
      assert D.channel_history(s.id, :t1) == {{:u1, "lol"}}
    end

    test "many messages", s do
      dummy_messages =
        0..9
        |> Enum.map(fn x ->
          {:t1, :u1, "#{x}"}
        end)
        |> Enum.map(fn {a, u, m} ->
          D.send_msg(s.id, a, u, m)
          {u, m}
        end)

      assert D.channel_history(s.id, :t1) == List.to_tuple(dummy_messages)
    end
  end

  describe "cfg_table" do
    @tag :tmp_dir
    test "make_table_contents", s do
      ids = Atom.to_string(s.id)

      this_cfg =
        @dummy_cfg
        |> String.replace("server_id: testing", "server_id: foobar")

      Path.join([s.tmp_dir, ids <> ".yml"])
      |> File.write!(this_cfg)

      newtable =
        SiteConfig.load_all(s.tmp_dir)
        |> S.CfgTable.make_table_contents()
        |> Map.new(fn {{_srv, k}, v} -> {k, v} end)

      assert "!" == newtable.prefix
      assert :foobar == newtable.server_id
    end
  end
end
