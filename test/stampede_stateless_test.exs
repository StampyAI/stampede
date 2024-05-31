defmodule StampedeStatelessTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  require Plugin
  alias Stampede, as: S
  require S.MsgReceived
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
    plugs: MapSet.new([Plugins.Test, Plugins.Sentience]),
    vip_ids: MapSet.new([:server]),
    dm_handler: true,
    bot_is_loud: false
  }

  describe "stateless functions" do
    test "split_prefix text" do
      assert {"!", "ping"} == S.split_prefix("!ping", "!")
      assert {false, "ping"} == S.split_prefix("ping", "!")
    end

    test "SiteConfig.make_regex() test" do
      r_binary = "~r/[Ss]\(,\)? "
      [prefix: rex] = SiteConfig.make_regex([prefix: r_binary], nil)
      assert Regex.source(rex) == String.slice(r_binary, 3, String.length(r_binary) - 3)
      assert {"S, ", "ping"} == S.split_prefix("S, ping", rex)
      assert {"S ", "ping"} == S.split_prefix("S ping", rex)
      assert {"s, ", "ping"} == S.split_prefix("s, ping", rex)
      assert {false, "s,, ping"} == S.split_prefix("s,, ping", rex)
      assert {false, "ping"} == S.split_prefix("ping", rex)
    end

    test "Plugin.is_bot_invoked?" do
      cfg_defaults = %{bot_is_loud: false}

      msg_defaults = %{
        at_bot?: false,
        dm?: false,
        prefix: false
      }

      inputs =
        [
          [%{}, %{at_bot?: true}],
          [%{}, %{dm?: true}],
          [%{}, %{prefix: "something"}]
        ]
        |> Enum.map(fn
          [cfg_overrides, msg_overrides] ->
            [
              Map.merge(cfg_defaults, cfg_overrides),
              Map.merge(msg_defaults, msg_overrides)
            ]
        end)

      assert not Plugin.is_bot_invoked(msg_defaults)

      for [cfg, msg] <- inputs do
        assert Plugin.is_bot_invoked(msg)
      end
    end

    test "S.keyword_put_new_if_not_falsy" do
      kw1 = [a: 1, b: 2]
      kw2 = [a: 1, b: 2, c: 3]

      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:a, false)
      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:b, 4)
      assert kw2 == kw1 |> S.keyword_put_new_if_not_falsy(:c, 3) |> Enum.sort()
    end

    test "basic test plugin" do
      dummy_cfg = @dummy_cfg_verified

      msg =
        S.MsgReceived.new(
          id: 0,
          body: "!ping",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> S.MsgReceived.add_context(dummy_cfg)

      r = Plugins.Test.respond(dummy_cfg, msg)
      assert r.text == "pong!"

      msg =
        S.MsgReceived.new(
          id: 0,
          body: "!raise",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> S.MsgReceived.add_context(dummy_cfg)

      assert_raise SillyError, fn ->
        _ = Plugins.Test.respond(dummy_cfg, msg)
      end

      msg =
        S.MsgReceived.new(
          id: 0,
          body: "!throw",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> S.MsgReceived.add_context(dummy_cfg)

      try do
        _ = Plugins.Test.respond(dummy_cfg, msg)
      catch
        _t, e ->
          assert e == SillyThrow
      end

      msg =
        S.MsgReceived.new(
          id: 0,
          body: "!callback",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> S.MsgReceived.add_context(dummy_cfg)

      %{callback: {m, f, a}} = Plugins.Test.respond(dummy_cfg, msg)

      cbr = apply(m, f, a)
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

      key = S.make_dm_tuple(cfg.service)

      assert key ==
               Map.fetch!(svmap, cfg.service)
               |> Map.fetch!(S.make_dm_tuple(cfg.service))
               |> Map.fetch!(:server_id)
    end

    test "vip check" do
      vips = %{some_server: MapSet.new([:admin])}

      assert S.vip_in_this_context?(
               vips,
               :some_server,
               :admin
             )

      assert S.vip_in_this_context?(
               vips,
               :all,
               :admin
             )

      assert false ==
               S.vip_in_this_context?(
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

    test "typechecking enabled during tests" do
      assert_raise TypeCheck.TypeError, fn -> S.Debugging.always_fails_typecheck() end
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
    test "flattens lists" do
      input = [[[], []], [["f"], ["o", "o"]], ["b", ["a"], "r"]]
      wanted = ["f", "o", "o", "b", "a", "r"]

      assert wanted == TxtBlock.to_str_list(input, Service.Dummy)
      assert "lol" == TxtBlock.to_str_list([[[[[], [[[["lol"], []]]]]]]], Service.Dummy)
    end

    test "source block" do
      correct =
        """
        ```
        foo
        ```
        """

      one =
        TxtBlock.to_binary(
          {:source_block, "foo\n"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:source_block, [["f"], [], "o", [["o"], "\n"]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "source ticks" do
      correct = "`foo`"

      one =
        TxtBlock.to_binary(
          {:source, "foo"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:source, [["f"], [], "o", [["o"]]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "quote block" do
      correct = "> foo\n> bar\n"

      one =
        TxtBlock.to_binary(
          {:quote_block, "foo\nbar"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:quote_block, [["f"], [], "o", [["o"]], ["\n", "bar"]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "indent block" do
      correct = "  foo\n  bar\n"

      one =
        TxtBlock.to_binary(
          {{:indent, "  "}, "foo\nbar"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {{:indent, 2}, [["f"], [], "o", [["o"]], ["\n", "bar"]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "list with italics" do
      one = {{:list, :numbered}, ["1", ["2", " ", "foo"], ["3 ", {:italics, "bar"}]]}

      correct =
        """
        1. 1
        2. 2 foo
        3. 3 *bar*
        """

      assert correct == TxtBlock.to_binary(one, Service.Dummy)
    end

    test "Markdown" do
      processed =
        TxtBlock.Debugging.all_formats_example()
        |> TxtBlock.to_binary(Service.Dummy)

      assert processed == TxtBlock.Md.Debugging.all_formats_processed()
    end
  end

  describe "Response picking and tracebacks" do
    test "no response" do
      tlist =
        [{Plugins.Test, {:job_ok, nil}}]

      assert match?(%{r: nil, tb: _}, Plugin.resolve_responses(tlist))
    end

    test "default response" do
      tlist =
        [
          {Plugins.Sentience,
           {:job_ok,
            %Stampede.ResponseToPost{
              confidence: 1,
              text: {:italics, "confused beeping"},
              origin_plug: Plugins.Sentience,
              origin_msg_id: 49,
              why: ["I didn't have any better ideas."],
              callback: nil,
              channel_lock: false
            }}}
        ]

      result = Plugin.resolve_responses(tlist)

      assert match?(%{r: %Stampede.ResponseToPost{}, tb: _}, Plugin.resolve_responses(tlist)) &&
               result.r.confidence == 1 &&
               result.r.origin_plug == Plugins.Sentience
    end
  end
end
