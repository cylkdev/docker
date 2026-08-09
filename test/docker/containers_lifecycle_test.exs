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
      assert {:ok, %{"State" => %{"Running" => true}}} = Docker.find_container(id)

      assert {:ok, _} = Docker.stop_container(id)
      assert {:ok, %{"State" => %{"Running" => false}}} = Docker.find_container(id)
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

  describe "create_container/5 (security and resource options)" do
    test "the daemon reports back every option it was given" do
      id =
        create_container!(["sleep", "30"],
          user: "65534:65534",
          readonly_rootfs: true,
          cap_drop: ["ALL"],
          security_opt: ["no-new-privileges:true"],
          tmpfs: %{"/tmp" => "rw,noexec,nosuid,nodev,size=64m"},
          cgroupns_mode: "private",
          memory: 536_870_912,
          nano_cpus: 1_000_000_000,
          pids_limit: 256
        )

      assert {:ok, container} = Docker.find_container(id)

      assert container["Config"]["User"] === "65534:65534"

      assert container["HostConfig"]["ReadonlyRootfs"] === true
      assert container["HostConfig"]["CapDrop"] === ["ALL"]
      assert container["HostConfig"]["SecurityOpt"] === ["no-new-privileges:true"]
      assert container["HostConfig"]["Tmpfs"] === %{"/tmp" => "rw,noexec,nosuid,nodev,size=64m"}
      assert container["HostConfig"]["CgroupnsMode"] === "private"
      assert container["HostConfig"]["Memory"] === 536_870_912
      assert container["HostConfig"]["NanoCpus"] === 1_000_000_000
      assert container["HostConfig"]["PidsLimit"] === 256
    end

    test "a container created without them keeps the daemon's own defaults" do
      id = create_container!(["sleep", "30"])

      assert {:ok, container} = Docker.find_container(id)

      assert container["Config"]["User"] === ""
      assert container["HostConfig"]["ReadonlyRootfs"] === false
      assert container["HostConfig"]["CapDrop"] === nil
      assert container["HostConfig"]["Memory"] === 0
      assert container["HostConfig"]["NanoCpus"] === 0
    end
  end

  describe "create_container/5 (options this library does not support)" do
    # These settings each hand a container a way to reach the host, and none of
    # them has a field in `Docker.Instance`. An unrecognised key in `opts` is
    # ignored rather than forwarded, so passing them changes nothing — this
    # test is what keeps that true.
    test "a caller passing host-escape options gets a container without them" do
      id =
        create_container!(["sleep", "30"],
          privileged: true,
          cap_add: ["SYS_ADMIN"],
          devices: [%{"PathOnHost" => "/dev/mem", "PathInContainer" => "/dev/mem"}],
          device_cgroup_rules: ["c 1:1 rwm"],
          userns_mode: "host",
          pid_mode: "host"
        )

      assert {:ok, container} = Docker.find_container(id)

      assert container["HostConfig"]["Privileged"] === false
      assert container["HostConfig"]["CapAdd"] === nil
      assert container["HostConfig"]["Devices"] === nil
      assert container["HostConfig"]["DeviceCgroupRules"] === nil
      assert container["HostConfig"]["UsernsMode"] === ""
      assert container["HostConfig"]["PidMode"] === ""
    end
  end
end
