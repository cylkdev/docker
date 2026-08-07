defmodule Docker.NetworksTest do
  @moduledoc "Network lifecycle against a real daemon."

  use DaemonCase

  # create_network/3 requires labels; there is no arity-1 form.
  defp create_network! do
    name = unique_name("docker-ex-test-net")
    {:ok, id} = Docker.create_network(name, %{})
    on_exit(fn -> Docker.delete_network(id) end)
    {id, name}
  end

  describe "create_network/3 and find_network/2" do
    test "a created network is findable by the id it returned" do
      {id, name} = create_network!()

      assert {:ok, network} = Docker.find_network(id)
      assert network["Name"] === name
      assert network["Driver"] === "bridge"
    end
  end

  describe "list_networks/2" do
    test "includes a created network" do
      {id, _name} = create_network!()

      assert {:ok, networks} = Docker.list_networks()
      assert Enum.any?(networks, &(&1["Id"] === id))
    end

    test "a driver filter narrows the list" do
      assert {:ok, networks} = Docker.list_networks(%{filters: [driver: ["bridge"]]})
      assert Enum.all?(networks, &(&1["Driver"] === "bridge"))
    end
  end

  describe "connect_network/3" do
    test "a connected container appears in the network's container map" do
      {id, _name} = create_network!()
      container_id = start_container!(["sleep", "30"])

      assert {:ok, _} = Docker.connect_network(id, container_id)

      assert {:ok, network} = Docker.find_network(id)
      assert Map.has_key?(network["Containers"], container_id)
    end
  end

  describe "delete_network/2" do
    test "a deleted network is no longer findable" do
      name = unique_name("docker-ex-test-net")
      {:ok, id} = Docker.create_network(name, %{})
      on_exit(fn -> Docker.delete_network(id) end)

      assert :ok = Docker.delete_network(id)
      assert {:error, %ErrorMessage{code: :not_found}} = Docker.find_network(id)
    end
  end
end
