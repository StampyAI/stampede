defmodule StampedeDummyNewTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Stampede, as: S
  alias Services.Dummy, as: D
  import AssertValue

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

  describe "new dummy system" do
    setup context do
      id = context.test

      @dummy_cfg_verified
      |> Map.to_list()
      |> Keyword.put(:server_id, id)
      |> Keyword.put(:filename, id |> Atom.to_string())
      |> Keyword.merge(context[:cfg_overrides] || [])
      |> D.Server.new_server()

      %{id: id}
    end

    test "can start", s do
      assert :pong == D.ping(s.id)
    end

    test "holds msg", s do
      c = :channel_a
      tup = {u, t, r} = {:user_a, "text a", nil}
      assert :ok == D.Server.add_msg({s.id, c, u, t, r})

      assert [{0, tup}] == D.channel_history(s.id, c)
      assert %{c => [{0, tup}]} == D.server_dump(s.id)
    end

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

    describe "channels" do
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
  end
end
