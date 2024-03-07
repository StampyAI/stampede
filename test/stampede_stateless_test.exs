defmodule StampedeStatelessTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Stampede, as: S
  require S.Msg
  alias Service.Dummy, as: D
  doctest Stampede

  @dummy_cfg """
    service: dummy
    server_id: testing
    error_channel_id: error
    prefix: "!"
    dm_handler: true
    plugs:
      - Test
      - Sentience
  """
  @dummy_cfg_verified %{
    service: Service.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test, Plugin.Sentience]),
    vip_ids: MapSet.new([:server]),
    dm_handler: true
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

      assert_raise SillyError, fn -> Plugin.Test.process_msg(dummy_cfg, msg) end

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

    test "SiteConfig load" do
      verified = SiteConfig.load_from_string(@dummy_cfg)
      assert verified == @dummy_cfg_verified
    end

    test "SiteConfig dm handler" do
      cfg = @dummy_cfg_verified

      svmap =
        %{cfg.service => %{cfg.server_id => cfg}}
        |> SiteConfig.make_configs_for_dm_handling()

      #  |> IO.inspect(pretty: true) # Debug

      key = {:dm, cfg.service}

      assert key ==
               Map.fetch!(svmap, cfg.service)
               |> Map.fetch!({:dm, cfg.service})
               |> Map.fetch!(:server_id)
    end

    test "vip check" do
      vips = %{some_server: :admin}

      assert S.is_vip_in_this_context(
               vips,
               :some_server,
               :admin
             )

      assert S.is_vip_in_this_context(
               vips,
               nil,
               :admin
             )

      assert false ==
               S.is_vip_in_this_context(
                 vips,
                 :some_server,
                 :non_admin
               )
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

  describe "cfg_table" do
    test "do_vips_configured" do
      result =
        %{
          Service.Dummy => %{
            foo: %{
              server_id: :foo,
              vip_ids: MapSet.new([:bar, :baz])
            }
          }
        }
        |> S.CfgTable.do_vips_configured(Service.Dummy)

      assert result == %{foo: MapSet.new([:bar, :baz])}
    end
  end

  describe "text formatting" do
    test "source block" do
      correct =
        """
        ```
        foo
        ```
        """

      one =
        TxtBlock.to_iolist(
          {:source_block, "foo"},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      two =
        TxtBlock.to_iolist(
          {:source_block, [["f"], [], "o", [["o"]]]},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      assert one == correct
      assert two == correct
    end

    test "source ticks" do
      correct = "`foo`"

      one =
        TxtBlock.to_iolist(
          {:source, "foo"},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      two =
        TxtBlock.to_iolist(
          {:source, [["f"], [], "o", [["o"]]]},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      assert one == correct
      assert two == correct
    end

    test "quote block" do
      correct = "> foo\n> bar\n"

      one =
        TxtBlock.to_iolist(
          {:quote_block, "foo\nbar"},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      two =
        TxtBlock.to_iolist(
          {:quote_block, [["f"], [], "o", [["o"]], ["\n" | "bar"]]},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      assert one == correct
      assert two == correct
    end

    test "indent block" do
      correct = "  foo\n  bar\n"

      one =
        TxtBlock.to_iolist(
          {{:indent, "  "}, "foo\nbar"},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      two =
        TxtBlock.to_iolist(
          {{:indent, 2}, [["f"], [], "o", [["o"]], ["\n" | "bar"]]},
          Service.Dummy
        )
        |> IO.iodata_to_binary()

      assert one == correct
      assert two == correct
    end

    test "Markdown" do
      processed =
        TxtBlock.Debugging.all_formats_example()
        |> TxtBlock.to_iolist(Service.Dummy)
        |> IO.iodata_to_binary()

      assert processed == TxtBlock.Md.Debugging.all_formats_processed()
    end
  end
end
