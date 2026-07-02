defmodule Docker.Streaming.SessionResizeTest do
  use ExUnit.Case, async: true

  alias Docker.Streaming.Session

  describe "resize/2" do
    test "errors when the session has no exec id" do
      assert {:error, :no_exec_id} = Session.resize(%Session{exec_id: nil}, {40, 120})
    end
  end
end
