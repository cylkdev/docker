defmodule Docker.Engine.ExecTest do
  use ExUnit.Case, async: true

  describe "resize_path/3" do
    test "builds the exec resize path with h and w query params" do
      assert Docker.Exec.resize_path("abc123", 40, 120) == "/exec/abc123/resize?h=40&w=120"
    end
  end
end
