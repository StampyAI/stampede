defmodule StampedeTest do
  use ExUnit.Case, async: false
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
      - Why
  """
  @dummy_cfg_verified %{
    service: Service.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test, Plugin.Sentience, Plugin.Why])
  }
  setup_all do
    return = %{
      app_pid:
        Stampede.Application.start(
          :normal,
          installed_services: [:dummy],
          services: [:dummy],
          log_to_file: false,
          serious_error_channel_service: :disabled,
          clear_state: true
        )
    }

    {
      :sys.get_state(Service.Dummy)
    }
    |> IO.inspect(pretty: true)

    return
  end

  setup context do
    id = context.test

    if Map.get(context, :dummy, false) do
      :ok = D.new_server(id, MapSet.new([Plugin.Test, Plugin.Sentience, Plugin.Why]))
    end

    {
      :sys.get_state(Service.Dummy)
    }
    |> IO.inspect(pretty: true)

    %{id: id}
  end

  describe "dummy server" do
    @describetag :dummy
    test "ping", s do
      assert nil == D.send_msg(s.id, :t1, :u1, "no response")
      assert "pong!" == D.send_msg(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)

      assert match?(
               [
                 {_, {:u1, "no response", nil}},
                 {cause_id, {:u1, "!ping", nil}},
                 {_, {:server, "pong!", cause_id}}
               ],
               D.channel_history(s.id, :t1)
             )
    end

    test "ignores messages from other servers", s do
      nil = D.send_msg(s.id, :t1, :nope, "nada")
      nil = D.send_msg(s.id, :t1, :abc, "def")
      assert "pong!" == D.send_msg(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)
      assert nil == D.send_msg(:shouldnt_exist, :t1, :u1, "!ping")

      assert match?(
               [
                 {_, {:nope, "nada", nil}},
                 {_, {:abc, "def", nil}},
                 {cause_id, {:u1, "!ping", nil}},
                 {_, {:server, "pong!", cause_id}}
               ],
               D.channel_history(s.id, :t1)
             )
    end

    test "plugin raising", s do
      {result, log} = with_log(fn -> D.send_msg(s.id, :t1, :u1, "!raise") end)
      assert match?(%{text: @confused_response}, result)
      assert String.contains?(log, "SillyError"), "SillyError not thrown"

      assert D.channel_history(s.id, :error)
             |> inspect()
             |> String.contains?("SillyError"),
             "error not being logged"

      assert match?(
               [{cause_id, {:u1, "!raise", nil}}, {_, {:server, @confused_response, cause_id}}],
               D.channel_history(s.id, :t1)
             )
    end

    test "plugin throwing", s do
      {result, log} = with_log(fn -> D.send_msg(s.id, :t1, :u1, "!throw") end)
      assert result.text == @confused_response
      assert String.contains?(log, "SillyThrow"), "SillyThrow not thrown"

      assert D.channel_history(s.id, :error)
             |> inspect()
             |> String.contains?("SillyThrow"),
             "error not being logged"

      assert match?(
               [{cause_id, {:u1, "!throw", nil}}, {_, {:server, @confused_response, cause_id}}],
               D.channel_history(s.id, :t1)
             )
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
      uname = :admin

      assert "locked in on #{uname} awaiting b" ==
               D.send_msg(s.id, :t1, uname, "!a") |> Map.fetch!(:text)

      assert "b response. awaiting c" == D.send_msg(s.id, :t1, uname, "!b") |> Map.fetch!(:text)

      assert "c response. interaction done!" ==
               D.send_msg(s.id, :t1, uname, "!c") |> Map.fetch!(:text)

      assert "locked in on #{uname} awaiting b" ==
               D.send_msg(s.id, :t1, uname, "!a") |> Map.fetch!(:text)

      assert "lock broken by admin" ==
               D.send_msg(s.id, :t1, uname, "!interrupt") |> Map.fetch!(:text)
    end
  end

  describe "dummy server channels" do
    @describetag :dummy
    test "one message", s do
      D.send_msg(s.id, :t1, :u1, "lol")

      assert match?(
               [{_, {:u1, "lol", nil}}],
               D.channel_history(s.id, :t1)
             )
    end

    test "many messages", s do
      dummy_messages =
        0..9
        |> Enum.map(fn x ->
          {:t1, :u1, "#{x}"}
        end)
        |> Enum.reduce({[], 0}, fn {a, u, m}, lst ->
          D.send_msg(s.id, a, u, m)
          [{:_, {u, m, nil}} | lst]
        end)

      assert match?(
               dummy_messages,
               D.channel_history(s.id, :t1)
             )
    end
  end

  describe "SiteConfig" do
    @tag :tmp_dir
    test "load_all", s do
      ids = Atom.to_string(s.id)

      this_cfg =
        @dummy_cfg
        |> String.replace("server_id: testing", "server_id: foobar")

      Path.join([s.tmp_dir, ids <> ".yml"])
      |> File.write!(this_cfg)

      newtable =
        SiteConfig.load_all(s.tmp_dir)
        |> Map.fetch!(Service.Dummy)
        |> Map.fetch!(:foobar)

      assert "!" == newtable.prefix
      assert :foobar == newtable.server_id
    end
  end

  describe "interaction logging" do
    @describetag :dummy
    test "interaction is logged", s do
      %{posted_msg_id: posted_msg_id} = D.send_msg(s.id, :t1, :u1, "!ping", return_id: true)
      :timer.sleep(100)
      # check interaction was logged, without Why plugin
      slug = S.Interact.get(posted_msg_id)
      assert match?({:ok, %S.Interact.IntTable{}}, slug)
    end

    test "Why plugin returns trace", s do
      %{posted_msg_id: posted_msg_id} = D.send_msg(s.id, :t1, :u1, "!ping", return_id: true)
      :timer.sleep(100)

      D.send_msg(s.id, :t1, :u1, "!Why did you say that, specifically?", ref: posted_msg_id)
      |> Map.fetch!(:text)
      |> Plugin.Why.Debugging.probably_a_traceback()
      |> assert("couldn't find traceback, maybe regex needs update?")
    end

    test "Why plugin returns error on bad ID", s do
      D.send_msg(s.id, :t1, :u1, "!Why did you say that, specifically?",
        ref: {s.id, :t1, :system, 9999}
      )
      |> Map.fetch!(:text)
      |> String.match?(Regex.compile!(Plugin.Why.msg_fail()))
      |> assert()
    end
  end
end
