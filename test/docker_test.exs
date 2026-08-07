defmodule DockerTest do
  use ExUnit.Case, async: true

  alias Docker.Sandbox

  @sandbox [sandbox: [enabled: true]]

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
           {:error, ErrorMessage.not_found("no such file", %{status: 404})}
         end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.put_archive("c1", "/no/such/dir", "fake-tar-bytes", @sandbox)
    end
  end

  describe "get_archive/3" do
    test "returns the daemon's tar bytes unchanged" do
      Sandbox.set_get_archive_responses([
        {~r/.*/, fn _ref, _src -> {:ok, "fake-tar-bytes"} end}
      ])

      assert {:ok, "fake-tar-bytes"} = Docker.get_archive("c1", "/app/build", @sandbox)
    end

    test "errors when the path does not exist" do
      Sandbox.set_get_archive_responses([
        {~r/.*/,
         fn _ref, _src ->
           {:error, ErrorMessage.not_found("no such file", %{status: 404})}
         end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.get_archive("c1", "/no/such/path", @sandbox)
    end
  end

  describe "download_archive/4" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "download_archive_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "writes the tar bytes verbatim", %{dir: dir} do
      Sandbox.set_get_archive_responses([
        {~r/.*/, fn _ref, _src -> {:ok, "fake-tar-bytes"} end}
      ])

      dest = Path.join(dir, "build.tar")

      assert {:ok, ^dest} = Docker.download_archive("c1", "/app/build", dest, @sandbox)
      assert File.read!(dest) === "fake-tar-bytes"
    end

    test "propagates a get_archive error without touching the filesystem", %{dir: dir} do
      Sandbox.set_get_archive_responses([
        {~r/.*/,
         fn _ref, _src ->
           {:error, ErrorMessage.not_found("no such file", %{status: 404})}
         end}
      ])

      dest = Path.join(dir, "build.tar")

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.download_archive("c1", "/nope", dest, @sandbox)

      refute File.exists?(dest)
    end

    test "returns :internal_server_error when the destination is unwritable", %{dir: dir} do
      Sandbox.set_get_archive_responses([
        {~r/.*/, fn _ref, _src -> {:ok, "fake-tar-bytes"} end}
      ])

      # A path under a regular file cannot be created.
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "")
      dest = Path.join(blocker, "build.tar")

      assert {:error, %ErrorMessage{code: :internal_server_error} = error} =
               Docker.download_archive("c1", "/app/build", dest, @sandbox)

      assert error.details.dest_path === dest
    end
  end

  describe "stat_archive/3" do
    test "returns the decoded path stat" do
      Sandbox.set_stat_archive_responses([
        {~r/.*/, fn _ref, _src -> {:ok, %{"name" => "build", "size" => 4096}} end}
      ])

      assert {:ok, %{"name" => "build", "size" => 4096}} =
               Docker.stat_archive("c1", "/app/build", @sandbox)
    end

    test "errors when the path does not exist" do
      Sandbox.set_stat_archive_responses([
        {~r/.*/,
         fn _ref, _src ->
           {:error, ErrorMessage.not_found("no such file", %{status: 404})}
         end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.stat_archive("c1", "/no/such/path", @sandbox)
    end
  end

  describe "wait_container/3" do
    test "returns the exit status" do
      Sandbox.set_wait_container_responses([
        {~r/.*/, fn _ref -> {:ok, %{"StatusCode" => 0, "Error" => nil}} end}
      ])

      assert {:ok, %{"StatusCode" => 0}} = Docker.wait_container("c1", %{}, @sandbox)
    end

    test "a non-zero exit code is still {:ok, _}" do
      Sandbox.set_wait_container_responses([
        {~r/.*/, fn _ref -> {:ok, %{"StatusCode" => 137, "Error" => nil}} end}
      ])

      assert {:ok, %{"StatusCode" => 137}} = Docker.wait_container("c1", %{}, @sandbox)
    end

    test "passes the condition through" do
      Sandbox.set_wait_container_responses([
        {~r/.*/, fn _ref, params -> {:ok, %{"StatusCode" => 0, "condition" => params}} end}
      ])

      assert {:ok, %{"condition" => %{condition: "next-exit"}}} =
               Docker.wait_container("c1", %{condition: "next-exit"}, @sandbox)
    end

    test "errors when the container does not exist" do
      Sandbox.set_wait_container_responses([
        {~r/.*/,
         fn _ref ->
           {:error, ErrorMessage.not_found("no such container", %{status: 404})}
         end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.wait_container("ghost", %{}, @sandbox)
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

    test "returns a :bad_request error when tag is empty (before sandbox dispatch)" do
      assert {:error, %ErrorMessage{code: :bad_request, details: %{tag: ""}}} =
               Docker.build_image("examples/busybox-example", "Dockerfile", "", %{}, @sandbox)
    end

    test "returns a :bad_request error when the Dockerfile escapes the context" do
      assert {:error, %ErrorMessage{code: :bad_request, message: message}} =
               Docker.build_image("examples/busybox-example", "../../etc/hosts", "x:y")

      assert message === "Dockerfile is outside of the build context"
    end

    test "returns a :bad_request error when the Dockerfile is an unrelated absolute path" do
      assert {:error, %ErrorMessage{code: :bad_request, details: details}} =
               Docker.build_image("examples/busybox-example", "/etc/hosts", "x:y")

      assert %{dockerfile: "/etc/hosts", context_path: context_path} = details
      assert String.ends_with?(context_path, "examples/busybox-example")
    end

    test "propagates registered errors" do
      Sandbox.set_build_image_responses([
        {~r/.*/,
         fn _ctx, _dockerfile, _tag, _params, _opts ->
           {:error,
            ErrorMessage.bad_request("The build context path is not a directory", %{
              context_path: "/nope"
            })}
         end}
      ])

      assert {:error, %ErrorMessage{code: :bad_request, details: %{context_path: "/nope"}}} =
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

    test "returns an :unprocessable_entity error when the daemon reports a build error" do
      register_build_events([
        %{"stream" => "Step 1/2 : FROM alpine\n"},
        %{
          "error" => "The command '/bin/sh -c exit 1' returned a non-zero code: 1",
          "errorDetail" => %{"code" => 1}
        }
      ])

      capture_io(fn ->
        assert {:error,
                %ErrorMessage{
                  code: :unprocessable_entity,
                  message: "The command '/bin/sh -c exit 1' returned a non-zero code: 1"
                }} =
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
        {~r/.*/,
         fn _ctx, _dockerfile, _tag, _params, _opts ->
           {:error, ErrorMessage.bad_request("nope")}
         end}
      ])

      assert {:error, %ErrorMessage{code: :bad_request, message: "nope"}} =
               Docker.run_build_image("/nope", "Dockerfile", "x:y", %{}, @sandbox)
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
