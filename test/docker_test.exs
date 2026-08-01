defmodule DockerTest do
  use ExUnit.Case, async: true

  alias Docker.Sandbox

  @sandbox [sandbox: [enabled: true]]

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

  describe "list_images/2" do
    test "returns a list" do
      images = [%{"Id" => "i1"}, %{"Id" => "i2"}]
      Sandbox.set_list_images_responses([fn -> {:ok, images} end])

      assert {:ok, ^images} = Docker.list_images(%{all: true}, @sandbox)
    end

    test "encodes the :reference filter" do
      Sandbox.set_list_images_responses([fn params -> {:ok, params} end])

      assert {:ok, params} = Docker.list_images(%{filters: [reference: ["alpine*"]]}, @sandbox)

      assert params[:filters] == ~s({"reference":["alpine*"]})
    end

    test "rewrites :shared_size to the Engine's spelling and leaves identity alone" do
      Sandbox.set_list_images_responses([fn params -> {:ok, params} end])

      assert {:ok, params} =
               Docker.list_images(
                 %{shared_size: true, identity: true, manifests: true},
                 @sandbox
               )

      assert params == %{"shared-size": true, identity: true, manifests: true}
    end

    test "shared-size and identity reach the URL with the Engine's spelling" do
      url =
        Docker.Util.append_query_string(
          "/images/json",
          %{"shared-size": true, identity: true, manifests: true}
        )

      assert url == "/images/json?identity=true&manifests=true&shared-size=true"
      refute url =~ "shared_size"
    end
  end

  describe "list_networks/2" do
    test "returns a list" do
      Sandbox.set_list_networks_responses([fn -> {:ok, [%{"Id" => "n1"}]} end])

      assert {:ok, [%{"Id" => "n1"}]} = Docker.list_networks(%{}, @sandbox)
    end

    test "encodes the :driver filter" do
      Sandbox.set_list_networks_responses([fn params -> {:ok, params} end])

      assert {:ok, params} = Docker.list_networks(%{filters: [driver: ["bridge"]]}, @sandbox)

      assert params[:filters] == ~s({"driver":["bridge"]})
    end
  end

  describe "list_containers/2" do
    test "returns a list" do
      Sandbox.set_list_containers_responses([fn -> {:ok, [%{"Id" => "abc"}]} end])

      assert {:ok, [%{"Id" => "abc"}]} = Docker.list_containers(%{all: true}, @sandbox)
    end

    test "renders the :label map as key=value strings" do
      Sandbox.set_list_containers_responses([fn params -> {:ok, params} end])

      assert {:ok, params} =
               Docker.list_containers(
                 %{all: true, filters: [label: %{"resource_group" => "group_1"}]},
                 @sandbox
               )

      assert params[:all] == true
      assert params[:filters] == ~s({"label":["resource_group=group_1"]})
    end

    test "renders multiple labels" do
      Sandbox.set_list_containers_responses([fn params -> {:ok, params} end])

      assert {:ok, params} =
               Docker.list_containers(
                 %{filters: [label: %{"resource_group" => "group_1", "tier" => "web"}]},
                 @sandbox
               )

      assert JSON.decode!(params[:filters])["label"]
             |> Enum.sort() == ["resource_group=group_1", "tier=web"]
    end

    test "merges a label filter with another filter instead of dropping one" do
      Sandbox.set_list_containers_responses([fn params -> {:ok, params} end])

      assert {:ok, params} =
               Docker.list_containers(
                 %{filters: [label: %{"tier" => "web"}, status: ["running"]]},
                 @sandbox
               )

      assert JSON.decode!(params[:filters]) == %{
               "label" => ["tier=web"],
               "status" => ["running"]
             }
    end

    test "underscored filter keys become hyphenated on the wire" do
      Sandbox.set_list_containers_responses([fn params -> {:ok, params} end])

      assert {:ok, params} = Docker.list_containers(%{filters: [is_task: ["true"]]}, @sandbox)

      assert params[:filters] == ~s({"is-task":["true"]})
    end

    test "sends no filters key when only plain params are given" do
      Sandbox.set_list_containers_responses([fn params -> {:ok, params} end])

      assert {:ok, params} = Docker.list_containers(%{all: true, limit: 5}, @sandbox)

      assert params == %{all: true, limit: 5}
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

  describe "create_network/3" do
    test "returns the new id" do
      Sandbox.set_create_network_responses([
        fn _name, _labels, _opts -> {:ok, "net-id"} end
      ])

      assert {:ok, "net-id"} =
               Docker.create_network("sandbox-net", %{}, @sandbox)
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

      assert Docker.delete_network("net1", @sandbox)
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

  describe "create_container/5" do
    test "returns the new id" do
      Sandbox.set_create_container_responses([
        fn _group, _name, _image, _labels, _opts -> {:ok, "fake_id"} end
      ])

      assert {:ok, "fake_id"} =
               Docker.create_container("g1", "c1", "alpine", %{}, @sandbox)
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

  describe "Util.create_tar/3" do
    test "builds a tar from a local directory rooted at its basename" do
      dir = Path.join(System.tmp_dir!(), "put_archive_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "nested"))
      File.write!(Path.join(dir, "hello.txt"), "hi")
      File.write!(Path.join([dir, "nested", "deep.txt"]), "deep")
      on_exit(fn -> File.rm_rf!(dir) end)

      base = Path.basename(dir)
      tar_path = dir <> ".tar"
      on_exit(fn -> File.rm(tar_path) end)

      assert :ok = Docker.Util.create_tar(tar_path, dir, verbose: false)

      assert {:ok, entries} = :erl_tar.table(String.to_charlist(tar_path), [:compressed])
      entries = Enum.map(entries, &to_string/1)

      assert "#{base}/hello.txt" in entries
      assert "#{base}/nested/deep.txt" in entries
    end

    test "builds a tar from a single local file" do
      path =
        Path.join(System.tmp_dir!(), "put_archive_file_#{System.unique_integer([:positive])}")

      File.write!(path, "hi")
      on_exit(fn -> File.rm!(path) end)

      tar_path = path <> ".tar"
      on_exit(fn -> File.rm(tar_path) end)

      assert :ok = Docker.Util.create_tar(tar_path, path, verbose: false)

      assert {:ok, entries} = :erl_tar.table(String.to_charlist(tar_path), [:compressed])
      assert Enum.map(entries, &to_string/1) == [Path.basename(path)]
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
               Docker.build_image(
                 "examples/busybox-example",
                 "Dockerfile",
                 "docker-test:tiny",
                 %{},
                 @sandbox
               )

      assert events === Enum.to_list(stream)
    end

    test "raises when tag is empty (before sandbox dispatch)" do
      assert_raise RuntimeError, ~r/Expected tag/, fn ->
        Docker.build_image("examples/busybox-example", "Dockerfile", "", %{}, @sandbox)
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

  describe "run_build_image/5" do
    import ExUnit.CaptureIO

    defp register_build_events(events) do
      Sandbox.set_build_image_responses([
        {~r/.*/, fn _ctx, _dockerfile, _tag, _params, _opts -> {:ok, events} end}
      ])
    end

    test "writes stream output and returns :ok on a successful build" do
      register_build_events([
        %{"stream" => "Step 1/1 : FROM alpine\n"},
        %{"aux" => %{"ID" => "sha256:deadbeef"}},
        %{"stream" => "Successfully built deadbeef\n"}
      ])

      output =
        capture_io(fn ->
          assert :ok =
                   Docker.run_build_image(
                     "examples/busybox-example",
                     "Dockerfile",
                     "docker-test:tiny",
                     %{},
                     @sandbox
                   )
        end)

      assert output === "Step 1/1 : FROM alpine\nSuccessfully built deadbeef\n"
    end

    test "returns {:error, message} when the daemon reports a build error" do
      register_build_events([
        %{"stream" => "Step 1/2 : FROM alpine\n"},
        %{
          "error" => "The command '/bin/sh -c exit 1' returned a non-zero code: 1",
          "errorDetail" => %{"code" => 1}
        }
      ])

      capture_io(fn ->
        assert {:error, "The command '/bin/sh -c exit 1' returned a non-zero code: 1"} =
                 Docker.run_build_image(
                   "examples/busybox-example",
                   "Dockerfile",
                   "docker-test:tiny",
                   %{},
                   @sandbox
                 )
      end)
    end

    test "propagates a build_image/5 error without consuming a stream" do
      Sandbox.set_build_image_responses([
        {~r/.*/, fn _ctx, _dockerfile, _tag, _params, _opts -> {:error, :nope} end}
      ])

      assert {:error, :nope} =
               Docker.run_build_image("/nope", "Dockerfile", "x:y", %{}, @sandbox)
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
