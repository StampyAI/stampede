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
    :ok = D.Server.debug_start_own_parents()

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
      assert :pong == D.Server.ping(s.id)
    end

    test "holds msg", s do
      c = :channel_a
      tup = {u, t, r} = {:user_a, "text a", nil}
      assert :ok == D.Server.add_msg({s.id, c, u, t, r})

      assert [{0, tup}] == D.Server.channel_history(s.id, c)
      assert %{c => [{0, tup}]} == D.Server.server_dump(s.id)
    end

    test "ping", s do
      assert nil == D.Server.ask_bot(s.id, :t1, :u1, "no response")
      assert "pong!" == D.Server.ask_bot(s.id, :t1, :u1, "!ping") |> Map.fetch!(:text)

      assert match?(
               [
                 {_, {:u1, "no response", nil}},
                 {cause_id, {:u1, "!ping", nil}},
                 {_, {:stampede, "pong!", cause_id}}
               ],
               D.Server.channel_history(s.id, :t1)
             )
    end
  end
end
