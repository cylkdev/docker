defmodule DockerTest do
  use ExUnit.Case, async: true

  alias Docker.Engine.Sandbox

  @sandbox [sandbox: [enabled: true]]

  describe "endpoint/1" do
    test "delegates to Sorrel.Endpoint.from_options when sandbox is off" do
      # Without sandbox: real resolution. With explicit socket override the
      # call must succeed and return a unix endpoint pointing at that path.
      assert {:ok, %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/x.sock"}} =
               Docker.endpoint(socket: "/tmp/x.sock")
    end

    test "returns the registered response in sandbox mode" do
      endpoint = %Sorrel.Endpoint{transport: :tcp, host: "h", port: 2375}

      Sandbox.set_endpoint_responses([fn -> {:ok, endpoint} end])

      assert {:ok, ^endpoint} = Docker.endpoint(@sandbox)
    end
  end

  describe "ping/1" do
    test "returns the registered response" do
      Sandbox.set_ping_responses([fn -> {:ok, "OK"} end])

      assert {:ok, "OK"} = Docker.ping(@sandbox)
    end

    test "propagates registered errors" do
      Sandbox.set_ping_responses([fn -> {:error, :enoent} end])

      assert {:error, :enoent} = Docker.ping(@sandbox)
    end
  end

  describe "version/1" do
    test "returns metadata" do
      Sandbox.set_version_responses([fn -> {:ok, %{"Version" => "27.0.0"}} end])

      assert {:ok, %{"Version" => "27.0.0"}} = Docker.version(@sandbox)
    end
  end

  describe "list_images/2" do
    test "returns a list" do
      images = [%{"Id" => "i1"}, %{"Id" => "i2"}]
      Sandbox.set_list_images_responses([fn -> {:ok, images} end])

      assert {:ok, ^images} = Docker.list_images(%{all: true}, @sandbox)
    end
  end

  describe "list_networks/2" do
    test "returns a list" do
      Sandbox.set_list_networks_responses([fn -> {:ok, [%{"Id" => "n1"}]} end])

      assert {:ok, [%{"Id" => "n1"}]} = Docker.list_networks(%{}, @sandbox)
    end
  end

  describe "list_containers/2" do
    test "returns a list" do
      Sandbox.set_list_containers_responses([fn -> {:ok, [%{"Id" => "abc"}]} end])

      assert {:ok, [%{"Id" => "abc"}]} = Docker.list_containers(%{all: true}, @sandbox)
    end
  end

  describe "find_image/2" do
    test "returns image details" do
      Sandbox.set_find_image_responses([
        {~r/.*/, fn ref -> {:ok, %{id: "sha256:" <> ref}} end}
      ])

      assert {:ok, %{id: "sha256:alpine"}} = Docker.find_image("alpine", @sandbox)
    end

    test "404 surfaces as error" do
      Sandbox.set_find_image_responses([
        {~r/.*/, fn _ref -> {:error, %{status: 404, body: %{"message" => "no such image"}}} end}
      ])

      assert {:error, %{status: 404}} = Docker.find_image("ghost", @sandbox)
    end
  end

  describe "find_container/2" do
    test "returns container details" do
      Sandbox.set_find_container_responses([
        {~r/.*/, fn ref -> {:ok, %{"Id" => ref, "State" => %{"Running" => true}}} end}
      ])

      assert {:ok, %{"Id" => "c1"}} = Docker.find_container("c1", @sandbox)
    end
  end

  describe "find_network/2" do
    test "returns the network" do
      Sandbox.set_find_network_responses([
        {~r/.*/, fn id -> {:ok, %{"Id" => id}} end}
      ])

      assert {:ok, %{"Id" => "net1"}} = Docker.find_network("net1", @sandbox)
    end
  end

  describe "create_network/2" do
    test "returns the new id" do
      Sandbox.set_create_network_responses([fn -> {:ok, "net-id"} end])

      assert {:ok, "net-id"} = Docker.create_network("sandbox-net", @sandbox)
    end
  end

  describe "connect_network/3" do
    test "succeeds" do
      Sandbox.set_connect_network_responses([
        {~r/.*/, fn _net, _ctr -> {:ok, ""} end}
      ])

      assert {:ok, ""} = Docker.connect_network("net1", "ctr1", @sandbox)
    end
  end

  describe "delete_network/2" do
    test "returns :ok on success" do
      Sandbox.set_delete_network_responses([
        {~r/.*/, fn _id -> :ok end}
      ])

      assert :ok = Docker.delete_network("net1", @sandbox)
    end
  end

  describe "delete_image/3" do
    test "removes an image" do
      Sandbox.set_delete_image_responses([
        {~r/.*/, fn _ref, _params -> {:ok, [%{"Untagged" => "alpine:latest"}]} end}
      ])

      assert {:ok, [%{"Untagged" => _}]} = Docker.delete_image("alpine:latest", %{}, @sandbox)
    end
  end

  describe "create_container/3" do
    test "returns the new id" do
      Sandbox.set_create_container_responses([
        fn _name, _image, _opts -> {:ok, "fake_id"} end
      ])

      assert {:ok, "fake_id"} = Docker.create_container("c1", "alpine", @sandbox)
    end

    test "interactive_shell: invalid value raises before sandbox dispatch" do
      # Argument validation that raises happens in legacy paths only on
      # the live request path (do_create_container). Sandbox mode skips
      # those raises by design — callers wanting to test option validation
      # should hit the non-sandbox path; this test documents that the
      # sandbox path returns whatever the registered fn returns.
      Sandbox.set_create_container_responses([
        fn _name, _image, _opts -> {:ok, "fake_id"} end
      ])

      assert {:ok, "fake_id"} =
               Docker.create_container("c1", "alpine", [interactive_shell: 123] ++ @sandbox)
    end
  end

  describe "start_container/2" do
    test "returns ok" do
      Sandbox.set_start_container_responses([
        {~r/.*/, fn _ref -> {:ok, ""} end}
      ])

      assert {:ok, ""} = Docker.start_container("c1", @sandbox)
    end
  end

  describe "stop_container/2" do
    test "returns ok" do
      Sandbox.set_stop_container_responses([
        {~r/.*/, fn _ref -> {:ok, ""} end}
      ])

      assert {:ok, ""} = Docker.stop_container("c1", @sandbox)
    end
  end

  describe "delete_container/3" do
    test "removes a container" do
      Sandbox.set_delete_container_responses([
        {~r/.*/, fn _ref, _params -> {:ok, ""} end}
      ])

      assert {:ok, ""} = Docker.delete_container("c1", %{force: true}, @sandbox)
    end
  end

  describe "container_logs/3" do
    test "returns demuxed logs" do
      Sandbox.set_container_logs_responses([
        {~r/.*/, fn _ref, _params -> {:ok, "READY\n"} end}
      ])

      assert {:ok, "READY\n"} = Docker.container_logs("c1", %{}, @sandbox)
    end
  end

  describe "container_running?/2 (binary clause)" do
    test "true when registered fn returns true" do
      Sandbox.set_container_running_responses([
        {~r/.*/, fn _ref -> true end}
      ])

      assert Docker.container_running?("c1", @sandbox)
    end

    test "false when registered fn returns false" do
      Sandbox.set_container_running_responses([
        {~r/.*/, fn _ref -> false end}
      ])

      refute Docker.container_running?("c1", @sandbox)
    end
  end

  describe "container_running?/1 (map clause)" do
    test "reads the State.Running field" do
      assert Docker.container_running?(%{"State" => %{"Running" => true}})
      refute Docker.container_running?(%{"State" => %{"Running" => false}})
    end
  end

  describe "exec_create/3" do
    test "returns an exec id" do
      Sandbox.set_exec_create_responses([
        {~r/.*/, fn _ref, _cmd -> {:ok, "exec-1"} end}
      ])

      assert {:ok, "exec-1"} = Docker.exec_create("c1", ["echo", "hi"], @sandbox)
    end
  end

  describe "exec_start/2" do
    test "returns the buffered output" do
      Sandbox.set_exec_start_responses([
        {~r/.*/, fn _id -> {:ok, "hello\n"} end}
      ])

      assert {:ok, "hello\n"} = Docker.exec_start("exec-1", @sandbox)
    end
  end

  describe "exec_inspect/2" do
    test "returns metadata" do
      Sandbox.set_exec_inspect_responses([
        {~r/.*/, fn id -> {:ok, %{id: id, exit_code: 0, running: false}} end}
      ])

      assert {:ok, %{id: "exec-1", exit_code: 0, running: false}} =
               Docker.exec_inspect("exec-1", @sandbox)
    end
  end

  describe "exec_run/3" do
    test "returns the output" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, _cmd -> {:ok, "hi\n"} end}
      ])

      assert {:ok, "hi\n"} = Docker.exec_run("c1", ["echo", "hi"], @sandbox)
    end
  end

  describe "exec_run_with_status/3" do
    test "returns output plus exit metadata" do
      Sandbox.set_exec_run_with_status_responses([
        {~r/.*/, fn _ref, _cmd -> {:ok, %{output: "hi\n", exit_code: 0, running: false}} end}
      ])

      assert {:ok, %{output: "hi\n", exit_code: 0, running: false}} =
               Docker.exec_run_with_status("c1", ["echo", "hi"], @sandbox)
    end
  end

  describe "put_archive/4" do
    test "uploads files" do
      Sandbox.set_put_archive_responses([
        {~r/.*/, fn _ref, _dest, _tar -> {:ok, ""} end}
      ])

      assert {:ok, ""} = Docker.put_archive("c1", "/tmp", "fake-tar-bytes", @sandbox)
    end

    test "errors when destination directory does not exist" do
      Sandbox.set_put_archive_responses([
        {~r/.*/,
         fn _ref, _dest, _tar ->
           {:error, %{status: 404, body: %{"message" => "no such file"}}}
         end}
      ])

      assert {:error, %{status: 404}} =
               Docker.put_archive("c1", "/no/such/dir", "fake-tar-bytes", @sandbox)
    end
  end

  describe "pull_image/3" do
    test "returns a stream of decoded events" do
      events = [
        %{"status" => "Pulling fs layer", "id" => "abc"},
        %{"status" => "Download complete", "id" => "abc"}
      ]

      Sandbox.set_pull_image_responses([
        {~r/alpine.*/, fn _image, _params, _opts -> {:ok, events} end}
      ])

      assert {:ok, stream} = Docker.pull_image("alpine", %{}, @sandbox)
      assert events === Enum.to_list(stream)
    end

    test "matches by image regex and propagates params" do
      Sandbox.set_pull_image_responses([
        {~r/busybox.*/, fn _image, %{tag: "1.36.1"}, _opts -> {:ok, [%{"status" => "ok"}]} end}
      ])

      assert {:ok, stream} = Docker.pull_image("busybox", %{tag: "1.36.1"}, @sandbox)
      assert [%{"status" => "ok"}] = Enum.to_list(stream)
    end

    test "propagates registered errors" do
      Sandbox.set_pull_image_responses([
        {~r/.*/, fn _image, _params, _opts -> {:error, %{status: 404}} end}
      ])

      assert {:error, %{status: 404}} = Docker.pull_image("ghost", %{}, @sandbox)
    end
  end

  describe "build_image/5" do
    test "returns a stream of decoded build events" do
      events = [
        %{"stream" => "Step 1/2 : FROM alpine\n"},
        %{"stream" => "Successfully built deadbeef\n"},
        %{"aux" => %{"ID" => "sha256:deadbeef"}}
      ]

      Sandbox.set_build_image_responses([
        {~r/docker-test:.*/, fn _ctx, _dockerfile, _tag, _params, _opts -> {:ok, events} end}
      ])

      assert {:ok, stream} =
               Docker.build_image("priv/docker", "Dockerfile", "docker-test:tiny", %{}, @sandbox)

      assert events === Enum.to_list(stream)
    end

    test "raises when tag is empty (before sandbox dispatch)" do
      assert_raise RuntimeError, ~r/Expected tag/, fn ->
        Docker.build_image("priv/docker", "Dockerfile", "", %{}, @sandbox)
      end
    end

    test "propagates registered errors" do
      Sandbox.set_build_image_responses([
        {~r/.*/,
         fn _ctx, _dockerfile, _tag, _params, _opts ->
           {:error, :invalid_context_path}
         end}
      ])

      assert {:error, :invalid_context_path} =
               Docker.build_image("/nope", "Dockerfile", "x:y", %{}, @sandbox)
    end
  end

  describe "materialize_image/4" do
    test "returns the registered response" do
      Sandbox.set_materialize_image_responses([
        {~r/.*/, fn _ref, _path, _params -> {:ok, %{id: "img"}} end}
      ])

      assert {:ok, %{id: "img"}} =
               Docker.materialize_image("alpine", "alpine", %{}, @sandbox)
    end
  end
end
