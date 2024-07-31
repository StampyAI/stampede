defmodule StampedeDummyNewTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Stampede, as: S
  alias Services.Dummy, as: D
  import AssertValue

  setup_all do
    :ok = D.Server.debug_start_own_parents()
  end

  describe "new dummy system" do
    setup context do
      :ok = D.Server.debug_start_self(context.test)
      %{id: context.test}
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
  end
end
