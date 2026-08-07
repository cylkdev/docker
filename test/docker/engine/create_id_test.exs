defmodule Docker.Engine.CreateIdTest do
  @moduledoc "Both create endpoints return an id the daemon then recognises."

  use DaemonCase

  test "create_network returns an id the daemon knows" do
    name = unique_name("docker-ex-test-net")

    assert {:ok, id} = Docker.create_network(name, %{})
    on_exit(fn -> Docker.delete_network(id) end)

    assert {:ok, network} = Docker.find_network(id)
    assert network["Name"] === name
  end

  test "exec_create returns an id exec_inspect recognises" do
    container_id = start_container!(["sleep", "30"])

    assert {:ok, exec_id} = Docker.exec_create(container_id, ["/bin/echo", "hi"])
    assert {:ok, %{"Running" => false}} = Docker.exec_inspect(exec_id)
  end
end
