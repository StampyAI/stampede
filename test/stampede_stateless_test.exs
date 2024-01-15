defmodule StampedeStatelessTest do
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
  """
  @dummy_cfg_verified %{
    service: Service.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test, Plugin.Sentience])
  }

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
          id: 0,
          body: "!ping",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      dummy_cfg = %{
        __struct__: SiteConfig,
        prefix: "!"
      }

      r = Plugin.Test.process_msg(dummy_cfg, msg)
      assert r.text == "pong!"

      msg =
        S.Msg.new(
          id: 0,
          body: "!raise",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      try do
        Plugin.Test.process_msg(dummy_cfg, msg)
      catch
        _t, e ->
          assert is_struct(e, SillyError)
      end

      msg =
        S.Msg.new(
          id: 0,
          body: "!throw",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      try do
        Plugin.Test.process_msg(dummy_cfg, msg)
      catch
        _t, e ->
          assert e == SillyThrow
      end

      msg =
        S.Msg.new(
          id: 0,
          body: "!callback",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      %{callback: {m, f, a}} = Plugin.Test.process_msg(dummy_cfg, msg)

      cbr = apply(m, f, [dummy_cfg | a])
      assert String.starts_with?(cbr.text, "Called back with")
    end

    test "dummy channel_buffers" do
      example_history = %{
        c1: [{1, :a1, "m1"}, {0, :a2, "m2"}],
        c2: [{1, :a3, "m4"}, {0, :a3, "m3"}]
      }

      assert D.channel_buffers_append(example_history, {:c2, :a4, "m5"}) == %{
               c1: [{1, :a1, "m1"}, {0, :a2, "m2"}],
               c2: [{2, :a4, "m5"}, {1, :a3, "m4"}, {0, :a3, "m3"}]
             }
    end

    test "SiteConfig load" do
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

  test "Why reference get" do
    assert {:server, :channel, :user, 22} ==
             "test msg @Msg_22"
             |> Service.Dummy.get_reference({:server, :channel, :user})
  end
end
