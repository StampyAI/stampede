defmodule StampedeTest do
  use ExUnit.Case
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
  """
  @dummy_cfg_verified %{
    service: :dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test])
  }

  describe "stateless functions" do
    test "basic test plugin", _ do
      msg = S.Msg.new(
        body: "!ping", channel_id: :t1, author_id: :u1, server_id: :none
      )
      r = Plugin.Test.process_msg(nil, msg)
      assert r.text == "pong!"
    end
    test "SiteConfig load", _ do
      parsed = SiteConfig.load_from_string(@dummy_cfg)
      verified = SiteConfig.validate!(parsed, SiteConfig.schema_base())
      assert verified == @dummy_cfg_verified
    end
  end
  describe "dummy server" do
    setup %{} do
      with {:ok, reg_pid} <- 
        Registry.start_link(keys: :duplicate, name: Stampede.Registry, partitions: System.schedulers_online()),
      {:ok, spr_pid} <- 
        Task.Supervisor.start_link(name: Stampede.TaskSupervisor),
      {:ok, dummy_pid} <- 
        D.start_link([plugs: MapSet.new([Plugin.Test])], reg_pid) do
          {:ok, reg_pid: reg_pid, dummy_pid: dummy_pid}
        end
    end
    test "dummy + ping", s do
      assert nil == D.send_msg(s.dummy_pid, :t1, :u1, "no response")
      assert "pong!" == D.send_msg(s.dummy_pid, :t1, :u1, "!ping") |> Map.fetch!(:text)
    end
  end
end
