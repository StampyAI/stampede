defmodule ForeignPluginsTest do
  use ExUnit.Case, async: true
  alias Services.Dummy, as: D
  alias Stampede, as: S
  import AssertValue
  require S.Events.MsgReceived

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

  describe "Python" do
    test "basic" do
      {:ok, _pid} = Stampede.External.Python.start_link()

      cfg =
        @dummy_cfg_verified
        |> Stampede.External.Python.dumb_down_elixir_term()

      msg =
        S.Events.MsgReceived.new(
          id: 0,
          body: "!ping python",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )
        |> S.Events.MsgReceived.add_context(@dummy_cfg_verified)
        |> Stampede.External.Python.dumb_down_elixir_term()

      assert_value Stampede.External.Python.Pool.command(:example, :process, [cfg, msg]) ==
                     {:ok,
                      %{
                        ~c"confidence" => 10,
                        ~c"text" => ~c"pong!",
                        ~c"why" => [~c"They pinged so I ponged!"]
                      }}
    end
  end
end
