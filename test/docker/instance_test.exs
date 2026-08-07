defmodule Docker.InstanceTest do
  use ExUnit.Case, async: true

  describe "Instance.to_map/1 (labels)" do
    test "writes the supplied labels into the payload alongside the group label" do
      labels = %{"team" => "platform", "com.docker.kind" => "worker"}

      config =
        "my-group"
        |> Docker.Instance.new("session-xyz", "alpine", labels, [])
        |> Docker.Instance.to_map()

      assert config["Labels"] ===
               Map.put(labels, "elixir.docker.app", "my-group")
    end

    test "writes only the group label when no labels are supplied" do
      config =
        "my-group"
        |> Docker.Instance.new("session-xyz", "alpine", %{}, [])
        |> Docker.Instance.to_map()

      assert config["Labels"] === %{"elixir.docker.app" => "my-group"}
    end
  end
end
