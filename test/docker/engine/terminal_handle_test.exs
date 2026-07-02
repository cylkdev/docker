defmodule Docker.Terminal.HandleTest do
  use ExUnit.Case, async: true
  alias Docker.Terminal
  alias Docker.Terminal.Handle

  describe "resize/2" do
    test "errors when the handle has no exec id" do
      assert {:error, :no_exec_id} = Terminal.resize(%Handle{exec_id: nil}, {40, 120})
    end

    test "a bare name cannot be resized" do
      assert {:error, :resize_requires_session} = Terminal.resize("some-name", {40, 120})
    end
  end
end
