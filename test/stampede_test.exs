defmodule StampedeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Stampede, as: S
  alias Services.Dummy, as: D
  import AssertValue
  doctest Stampede

  @confused_response S.confused_response() |> TxtBlock.to_binary(Services.Dummy)

  @dummy_cfg """
    service: dummy
    server_id: testing
    error_channel_id: error
    prefix: "!"
    plugs:
      - Sentience
      - Test
      - Why
      - Help
  """
  @dummy_cfg_verified %{
    service: Services.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugins.Test, Plugins.Sentience, Plugins.Why, Plugins.Help]),
    dm_handler: false,
    filename: "test SiteConfig load_all",
    vip_ids: MapSet.new([:server]),
    bot_is_loud: false
  }
  setup_all do
    %{
      app_pid:
        Stampede.Application.start(
          :normal,
          installed_services: [:dummy],
          services: [:dummy],
          log_to_file: false,
          log_post_serious_errors: false,
          clear_state: true
        )
    }
  end

  setup context do
    id = context.test

    if context[:dummy] do
      @dummy_cfg_verified
      |> Map.to_list()
      |> Keyword.put(:server_id, id)
      |> Keyword.put(:filename, id |> Atom.to_string())
      |> Keyword.merge(context[:cfg_overrides] || [])
      |> D.new_server()
    end

    %{id: id}
  end

  describe "dummy server" do
    @describetag :dummy
    test "ping", s do
      assert nil == D.ask_bot(s.id, :t1, :u1, "no response")
      assert "pong!" == D.ask_bot(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)

      assert match?(
               [
                 {_, {:u1, "no response", nil}},
                 {cause_id, {:u1, "!ping", nil}},
                 {_, {:stampede, "pong!", cause_id}}
               ],
               D.channel_history(s.id, :t1)
             )
    end

    test "ignores messages from other servers", s do
      nil = D.ask_bot(s.id, :t1, :nope, "nada")
      nil = D.ask_bot(s.id, :t1, :abc, "def")
      assert "pong!" == D.ask_bot(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)
      assert nil == D.ask_bot(:shouldnt_exist, :t1, :u1, "!ping")

      assert match?(
               [
                 {_, {:nope, "nada", nil}},
                 {_, {:abc, "def", nil}},
                 {cause_id, {:u1, "!ping", nil}},
                 {_, {:stampede, "pong!", cause_id}}
               ],
               D.channel_history(s.id, :t1)
             )
    end

    test "plugin raising", s do
      {result, log} =
        with_log(fn ->
          D.ask_bot(s.id, :t1, :u1, "!raise")
        end)

      assert match?(%{text: @confused_response}, result)
      assert String.contains?(log, "SillyError"), "SillyError not thrown"

      assert D.channel_history(s.id, :error)
             |> inspect()
             |> String.contains?("SillyError"),
             "error not being logged"

      assert match?(
               [{cause_id, {:u1, "!raise", nil}}, {_, {:stampede, @confused_response, cause_id}}],
               D.channel_history(s.id, :t1)
             )
    end

    test "plugin throwing", s do
      {result, log} = with_log(fn -> D.ask_bot(s.id, :t1, :u1, "!throw") end)
      assert result.text == @confused_response
      assert String.contains?(log, "SillyThrow"), "SillyThrow not thrown"

      assert D.channel_history(s.id, :error)
             |> inspect()
             |> String.contains?("SillyThrow"),
             "error not being logged"

      assert match?(
               [{cause_id, {:u1, "!throw", nil}}, {_, {:stampede, @confused_response, cause_id}}],
               D.channel_history(s.id, :t1)
             )
    end

    test "plugin with callback", s do
      r = D.ask_bot(s.id, :t1, :u1, "!callback")
      assert String.starts_with?(r.text, "Called back with")
    end

    test "plugin with failing callback", s do
      r = D.ask_bot(s.id, :t1, :u1, "!callback fail")
      assert String.starts_with?(r.text, @confused_response)
    end

    test "plugin timeout", s do
      r = D.ask_bot(s.id, :t1, :u1, "!timeout")
      assert r.text == @confused_response
    end

    test "sustained interaction", s do
      uname = :admin

      assert "locked in on #{uname} awaiting b" ==
               D.ask_bot(s.id, :t1, uname, "!a") |> Map.fetch!(:text)

      assert "b response. awaiting c" == D.ask_bot(s.id, :t1, uname, "b") |> Map.fetch!(:text)

      assert "c response. interaction done!" ==
               D.ask_bot(s.id, :t1, uname, "c") |> Map.fetch!(:text)

      assert "locked in on #{uname} awaiting b" ==
               D.ask_bot(s.id, :t1, uname, "!a") |> Map.fetch!(:text)

      assert "lock broken by admin" ==
               D.ask_bot(s.id, :t1, uname, "interrupt") |> Map.fetch!(:text)

      assert "locked in on #{uname} awaiting b" ==
               D.ask_bot(s.id, :t1, uname, "!a") |> Map.fetch!(:text)

      assert "lock broken by admin" ==
               D.ask_bot(s.id, :t1, uname, "!command_interrupt") |> Map.fetch!(:text)
    end

    test "at_bot?", s do
      %{response: r, posted_msg_id: non_bot_id} =
        D.ask_bot(s.id, :t1, :u1, "!ping", return_id: true)

      assert r.text == "pong!"

      {id, {:stampede, _, _}} =
        D.channel_history(s.id, :t1)
        |> Enum.at(-1)

      r2 = D.ask_bot(s.id, :t1, :u1, "ping", ref: id)
      assert r2 && r2.text == "pong!", "bot not responding to being tagged"

      r3 = D.ask_bot(s.id, :t1, :u1, "ping", ref: non_bot_id)
      assert r3 == nil, "bot responded to tag of someone else's message"
    end

    @tag cfg_overrides: [prefix: ["a ", "b "]]
    test "multi-prefixes", s do
      r = D.ask_bot(s.id, :t1, :u1, "a ping")

      assert r.text == "pong!"

      r = D.ask_bot(s.id, :t1, :u1, "b ping")

      assert r.text == "pong!"
    end
  end

  describe "dummy server channels" do
    @describetag :dummy
    test "one message", s do
      D.ask_bot(s.id, :t1, :u1, "lol")

      assert match?(
               [{_, {:u1, "lol", nil}}],
               D.channel_history(s.id, :t1)
             )
    end

    test "many messages", s do
      expected =
        0..9
        |> Enum.map(fn x ->
          {:t1, :u1, "#{x}"}
        end)
        |> Enum.reduce([], fn {a, u, m}, lst ->
          D.ask_bot(s.id, a, u, m)
          [{u, m, nil} | lst]
        end)
        |> Enum.reverse()

      published =
        D.channel_history(s.id, :t1)
        |> Enum.map(&elem(&1, 1))

      assert expected == published
    end
  end

  describe "SiteConfig" do
    @tag :tmp_dir
    test "load_all", s do
      ids = Atom.to_string(s.id)

      Path.join([s.tmp_dir, ids <> ".yml"])
      |> File.write!(@dummy_cfg)

      newtable =
        SiteConfig.load_all(s.tmp_dir)
        |> Map.fetch!(Services.Dummy)
        |> Map.fetch!(:testing)

      assert newtable == @dummy_cfg_verified
    end
  end

  describe "interaction logging" do
    @describetag :dummy
    test "interaction is logged (direct database check)", s do
      %{bot_response_msg_id: bot_response_msg_id} =
        D.ask_bot(s.id, :t1, :u1, "!ping", return_id: true)

      :timer.sleep(100)
      # check interaction was logged, without Why plugin
      slug = S.Interact.get(bot_response_msg_id)
      assert match?({:ok, %S.Tables.Interactions{}}, slug)
    end

    test "Why plugin returns trace from database", s do
      %{bot_response_msg_id: bot_response_msg_id} =
        D.ask_bot(s.id, :t1, :u1, "!ping", return_id: true)

      :timer.sleep(100)

      D.ask_bot(s.id, :t1, :u1, "!Why did you say that, specifically?", ref: bot_response_msg_id)
      |> Map.fetch!(:text)
      |> Plugins.Why.Debugging.probably_a_traceback()
      |> assert("couldn't find traceback, maybe regex needs update?")
    end

    test "Why plugin returns error on bad ID", s do
      D.ask_bot(s.id, :t1, :u1, "!Why did you say that, specifically?",
        ref: {s.id, :t1, :system, 9999}
      )
      |> Map.fetch!(:text)
      |> Plugins.Why.Debugging.probably_a_missing_interaction()
      |> assert()
    end

    test "Interactions can be cleaned" do
      old_int = %{
        id: 1234,
        msg: %{
          channel_id: :chan_a
        },
        datetime: DateTime.from_unix!(0),
        channel_lock: nil
      }

      new_int = %{
        id: 6789,
        msg: %{
          channel_id: :chan_b
        },
        datetime: DateTime.utc_now(),
        channel_lock: nil
      }

      decisions = S.Interact.clean_interactions_logic([old_int, new_int], :unused)

      old_id = old_int.id
      assert [{{:delete, old_id}, nil}] == decisions

      old_locked_int = %{
        id: 2468,
        msg: %{
          channel_id: :chan_c
        },
        datetime: DateTime.from_unix!(0),
        channel_lock: {:lock, :chan_c, nil}
      }

      dummy_get_lock = fn cid ->
        case cid do
          :chan_c ->
            %{
              datetime: DateTime.from_unix!(0),
              interaction_id: 2468
            }

          arg ->
            raise "This shouldnt happen. Args: #{arg |> S.pp()}"
        end
      end

      decisions = S.Interact.clean_interactions_logic([old_locked_int, new_int], dummy_get_lock)
      assert decisions == [{{:delete, 2468}, {:unset, :chan_c}}]
    end
  end

  describe "Help plugin" do
    @describetag :dummy
    test "parsing" do
      assert :list_plugins == Plugins.Help.summon_type("help")
      assert :list_plugins == Plugins.Help.summon_type("list plugin")
      assert :list_plugins == Plugins.Help.summon_type("list plugins")
      assert {:specific, "Why"} == Plugins.Help.summon_type("help Why")
    end

    test "responses", s do
      assert_value D.ask_bot(s.id, :t1, :u1, "!list plugins") |> Map.fetch!(:text) == """
                   Here are the available plugins! Learn about any of them with `help [plugin]`

                   - **Help**:  Describes how the bot can be used. You're using it right now!
                   - **Sentience**:  This plugin only responds when Stampede was specifically requested, but all other plugins failed.
                   - **Test**:  A set of functions for testing Stampede functionality.
                   - **Why**:  Explains the bot's reasoning for posting a particular message, if it remembers it. Summoned with \"why did you say that?\" for a short summary. Remember to identify the message you want; on Discord, this is the \"reply\" function. If you want a full traceback, ask with \"specifically\".

                   """

      assert_value D.ask_bot(s.id, :t1, :u1, "!help why") |> Map.fetch!(:text) == """
                   Explains the bot's reasoning for posting a particular message, if it remembers it. Summoned with \"why did you say that?\" for a short summary. Remember to identify the message you want; on Discord, this is the \"reply\" function. If you want a full traceback, ask with \"specifically\".
                   Full regex: `[Ww]h(?:(?:y did)|(?:at made)) you say th(?:(?:at)|(?:is))(?P<specific>,? specifically)?`

                   Usage:
                   - Magic phrase: `(why did/what made) you say (that/this)[, specifically][?]`
                   - `!why did you say that? (tagging bot message)` **<>** `(reason for posting this message)`
                   - `!what made you say that, specifically? (tagging bot message)` **<>** `(full traceback of the creation of this message)`
                   - `!why did you say this (tagging unknown message)` **<>** `Couldn't find an interaction for message \"some_msg_id\".`
                   """
    end
  end
end
