defmodule StampedeStatelessTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  require Plugin
  alias Stampede, as: S
  alias S.Events.{MsgReceived}
  require MsgReceived
  import AssertValue
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
    service: Services.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugins.Test, Plugins.Sentience]),
    vip_ids: MapSet.new([:server]),
    dm_handler: true,
    bot_is_loud: false
  }

  setup_all do
    unless Application.get_env(:stampede, :test_loaded, false),
      do: raise("Test config not loaded")

    :ok
  end

  describe "stateless functions" do
    test "split_prefix text" do
      assert_value S.split_prefix("!ping", "!") == {"!", "ping"}
      assert_value S.split_prefix("ping", "!") == {false, "ping"}
      assert_value S.split_prefix("!", "!") == {false, "!"}
    end

    test "split_prefix binary list test" do
      bl = ["S, ", "S ", "s, ", "s "]

      assert_value S.split_prefix("S, ping", bl) == {"S, ", "ping"}
      assert_value S.split_prefix("S ping", bl) == {"S ", "ping"}
      assert_value S.split_prefix("s, ping", bl) == {"s, ", "ping"}
      assert_value S.split_prefix("s,, ping", bl) == {false, "s,, ping"}
      assert_value S.split_prefix("ping", bl) == {false, "ping"}
      assert_value S.split_prefix("s, ", bl) == {false, "s, "}
    end

    test "split_prefix conflict check" do
      bl = ["a", "b", "c", "ab", "d"]
      assert_value SiteConfig.check_prefixes_for_conflicts(bl) == {:conflict, "ab", "a", "b"}

      bl = ["a", "b", "c", "d"]
      assert_value SiteConfig.check_prefixes_for_conflicts(bl) == :no_conflict
    end

    test "cfg prefix conflict sorting" do
      rev = ["a", "b", "c", "aa", "ab", "ba", "bc", "aaa", "aba", "bbc", "cac", "aaaa", "ddddd"]

      {result, log} =
        with_log(fn ->
          SiteConfig.maybe_sort_prefixes([prefix: rev], nil)
        end)

      assert_value result[:prefix] == [
                     "ddddd",
                     "aaaa",
                     "aaa",
                     "aba",
                     "bbc",
                     "cac",
                     "aa",
                     "ab",
                     "ba",
                     "bc",
                     "a",
                     "b",
                     "c"
                   ]

      assert String.contains?(log, "sorted")
    end

    test "sort_by_str_len" do
      rev = ["a", "b", "c", "aa", "ab", "ba", "bc", "aaa", "aba", "bbc", "cac", "aaaa", "ddddd"]

      answer = [
        "ddddd",
        "aaaa",
        "aaa",
        "aba",
        "bbc",
        "cac",
        "aa",
        "ab",
        "ba",
        "bc",
        "a",
        "b",
        "c"
      ]

      assert S.sort_rev_str_len(rev) == answer
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
          [%{}, %{prefix: {"!", "ping"}}]
        ]
        |> Enum.map(fn
          [cfg_overrides, msg_overrides] ->
            [
              Map.merge(cfg_defaults, cfg_overrides),
              Map.merge(msg_defaults, msg_overrides)
            ]
        end)

      assert not Plugin.is_bot_invoked(msg_defaults)

      for [_cfg, msg] <- inputs do
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
        MsgReceived.new(
          id: 0,
          body: "!ping",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> MsgReceived.add_context(dummy_cfg)

      r = Plugins.Test.respond(dummy_cfg, msg)
      assert r.text == "pong!"

      msg =
        MsgReceived.new(
          id: 0,
          body: "!raise",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> MsgReceived.add_context(dummy_cfg)

      assert_raise SillyError, fn ->
        _ = Plugins.Test.respond(dummy_cfg, msg)
      end

      msg =
        MsgReceived.new(
          id: 0,
          body: "!throw",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> MsgReceived.add_context(dummy_cfg)

      try do
        _ = Plugins.Test.respond(dummy_cfg, msg)
      catch
        _t, e ->
          assert e == SillyThrow
      end

      msg =
        MsgReceived.new(
          id: 0,
          body: "!callback",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> MsgReceived.add_context(dummy_cfg)

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
          Services.Dummy => %{
            foo: %{
              server_id: :foo,
              vip_ids: MapSet.new([:bar, :baz])
            }
          }
        }
        |> S.CfgTable.do_vips_configured(Services.Dummy)

      assert result == %{foo: MapSet.new([:bar, :baz])}
    end
  end

  describe "text formatting" do
    test "flattens lists" do
      input = [[[], []], [["f"], ["o", "o"]], ["b", ["a"], "r"]]
      wanted = ["f", "o", "o", "b", "a", "r"]

      assert wanted == TxtBlock.to_str_list(input, Services.Dummy)
      assert "lol" == TxtBlock.to_str_list([[[[[], [[[["lol"], []]]]]]]], Services.Dummy)
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
          Services.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:source_block, [["f"], [], "o", [["o"], "\n"]]},
          Services.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "source ticks" do
      correct = "`foo`"

      one =
        TxtBlock.to_binary(
          {:source, "foo"},
          Services.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:source, [["f"], [], "o", [["o"]]]},
          Services.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "quote block" do
      correct = "> foo\n> bar\n"

      one =
        TxtBlock.to_binary(
          {:quote_block, "foo\nbar"},
          Services.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:quote_block, [["f"], [], "o", [["o"]], ["\n", "bar"]]},
          Services.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "indent block" do
      correct = "  foo\n  bar\n"

      one =
        TxtBlock.to_binary(
          {{:indent, "  "}, "foo\nbar"},
          Services.Dummy
        )

      two =
        TxtBlock.to_binary(
          {{:indent, 2}, [["f"], [], "o", [["o"]], ["\n", "bar"]]},
          Services.Dummy
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

      assert correct == TxtBlock.to_binary(one, Services.Dummy)
    end

    test "Markdown" do
      processed =
        TxtBlock.Debugging.all_formats_example()
        |> TxtBlock.to_binary(Services.Dummy)

      assert_value processed == """
                   Testing formats.

                   *Italicized* and **bolded**

                   Quoted
                   > Quoted line 1
                   > Quoted line 2

                   ```
                   source(1)
                   source(2)
                   ```

                   Inline source quote `foobar`

                   ><> school
                   ><> of
                   ><> fishies

                   Dotted list
                   - Item 1
                   - Item 2
                   - Item 3

                   Numbered list
                   1. Item 1
                   2. *Nested Italics Item 2*
                   3. Item 3
                   """
    end

    test "cut blank space and replace with newline" do
      assert "a\n" == S.end_with_newline("a     ")
      assert "a   b\n" == S.end_with_newline("a   b  ")
      assert_value S.end_with_newline("a\n") == "a\n"
    end
  end

  describe "Response picking and tracebacks" do
    test "no response" do
      tlist =
        [{Plugins.Test, {:job_ok, nil}}]

      assert_value Plugin.resolve_responses(tlist) |> inspect(pretty: true) ==
                     "%{r: nil, tb: vec([declined_to_answer: Plugins.Test])}"
    end

    test "default response" do
      tlist =
        [
          {Plugins.Sentience,
           {:job_ok,
            %Stampede.Events.ResponseToPost{
              confidence: 1,
              text: {:italics, "confused beeping"},
              origin_plug: Plugins.Sentience,
              origin_msg_id: 49,
              why: ["I didn't have any better ideas."],
              callback: nil,
              channel_lock: false
            }}}
        ]

      assert_value Plugin.resolve_responses(tlist) |> inspect(pretty: true) == """
                   %{
                     r: %Stampede.Events.ResponseToPost{
                       confidence: 1,
                       text: {:italics, \"confused beeping\"},
                       origin_plug: Plugins.Sentience,
                       origin_msg_id: 49,
                       why: [\"I didn't have any better ideas.\"],
                       callback: nil,
                       channel_lock: false
                     },
                     tb: vec([
                       response_was_chosen: {:replied_with_text, Plugins.Sentience, 1,
                        {:italics, \"confused beeping\"}, [\"I didn't have any better ideas.\"]}
                     ])
                   }<NOEOL>
                   """
    end
  end
end
