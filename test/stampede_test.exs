defmodule StampedeTest do
  use ExUnit.Case
  alias Stampede, as: S
  doctest Stampede

  test "basic test plugin" do
    msg = S.Msg.new(
      body: "!ping", channel_id: :t1, author_id: :u1, server_id: :none
    )
    r = Plugin.Test.process_msg(nil, msg)
    assert r.text == "pong!"
  end
end
