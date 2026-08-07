defmodule Docker.ContainersLifecycleTest do
  @moduledoc "The container lifecycle, driven the way a caller drives it."

  use DaemonCase

  describe "ping/1" do
    test "reaches the daemon" do
      assert {:ok, "OK"} = Docker.ping()
    end
  end

  describe "create_container/5 and find_container/2" do
    test "a created container is findable by the id it returned" do
      id = create_container!(["sleep", "30"])

      assert {:ok, container} = Docker.find_container(id)
      assert container["Id"] =~ id
      assert container["State"]["Running"] === false
    end

    test "labels given at creation come back on inspect" do
      name = unique_name("docker-ex-test")

      {:ok, id} =
        Docker.create_container(
          "docker-ex-test",
          name,
          "alpine:3.19",
          %{"tier" => "worker"},
          cmd: ["sleep", "30"]
        )

      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)

      assert {:ok, container} = Docker.find_container(id)
      assert container["Config"]["Labels"]["tier"] === "worker"
    end
  end

  describe "start_container/2 and stop_container/2" do
    test "a started container is running, and a stopped one is not" do
      id = create_container!(["sleep", "30"])

      assert {:ok, _} = Docker.start_container(id)
      assert Docker.container_running?(id)

      assert {:ok, _} = Docker.stop_container(id)
      refute Docker.container_running?(id)
    end
  end

  describe "container_running?/1 (map clause)" do
    test "reads the state out of an inspect response" do
      id = start_container!(["sleep", "30"])
      {:ok, container} = Docker.find_container(id)

      assert Docker.container_running?(container)
    end
  end

  describe "delete_container/3" do
    test "a deleted container is no longer findable" do
      name = unique_name("docker-ex-test")

      {:ok, id} =
        Docker.create_container("docker-ex-test", name, "alpine:3.19", %{}, cmd: ["sleep", "30"])

      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)

      assert {:ok, _} = Docker.delete_container(id)
      assert {:error, %ErrorMessage{code: :not_found}} = Docker.find_container(id)
    end
  end

  describe "container_logs/3" do
    test "returns what the container printed" do
      id = start_container!(["/bin/sh", "-c", "echo hello-from-logs"])

      {:ok, _} = Docker.wait_container(id)

      assert {:ok, logs} = Docker.container_logs(id, %{stdout: true})
      assert logs =~ "hello-from-logs"
    end
  end

  describe "list_containers/2" do
    test "lists a running container" do
      id = start_container!(["sleep", "30"])

      assert {:ok, containers} = Docker.list_containers()
      assert Enum.any?(containers, &(&1["Id"] =~ id))
    end

    test "a label filter narrows the list to matching containers" do
      name = unique_name("docker-ex-test")
      tier = unique_name("tier")

      {:ok, id} =
        Docker.create_container("docker-ex-test", name, "alpine:3.19", %{"tier" => tier},
          cmd: ["sleep", "30"]
        )

      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)
      {:ok, _} = Docker.start_container(id)

      other = start_container!(["sleep", "30"])

      assert {:ok, containers} =
               Docker.list_containers(%{filters: [label: %{"tier" => tier}]})

      ids = Enum.map(containers, & &1["Id"])
      assert Enum.any?(ids, &(&1 =~ id))
      refute Enum.any?(ids, &(&1 =~ other))
    end

    test "all: true includes a stopped container that the default hides" do
      id = create_container!(["sleep", "30"])

      {:ok, running_only} = Docker.list_containers()
      refute Enum.any?(running_only, &(&1["Id"] =~ id))

      {:ok, all} = Docker.list_containers(%{all: true})
      assert Enum.any?(all, &(&1["Id"] =~ id))
    end
  end
end
