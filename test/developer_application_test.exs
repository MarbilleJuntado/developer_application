defmodule DeveloperApplicationTest do
  use ExUnit.Case
  doctest DeveloperApplication

  test "greets the world" do
    assert DeveloperApplication.hello() == :world
  end
end
