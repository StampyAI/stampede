defmodule StampedeTest do
  use ExUnit.Case
  doctest Stampede

  test "greets the world" do
    assert Stampede.hello() == :world
  end
end
