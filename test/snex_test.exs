defmodule SnexTest do
  use ExUnit.Case
  doctest Snex

  test "greets the world" do
    assert Snex.hello() == :world
  end
end
