defmodule Docker.ContainersTest do
  @moduledoc """
  Archive and wait endpoints against a real daemon.

  The malformed-header cases this suite used to carry are gone with the
  branches that handled them: the daemon always sends a valid base64 JSON
  stat header.
  """

  use DaemonCase

  describe "get_archive/3" do
    test "returns the tar bytes for a path in the container" do
      id = start_container!(["sleep", "30"])

      assert {:ok, tar} = Docker.get_archive(id, "/etc/hostname")
      assert is_binary(tar)
      # A tar member header carries the file name in its first 100 bytes.
      assert binary_part(tar, 0, 100) =~ "hostname"
    end

    test "a path that does not exist is :not_found" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.get_archive(id, "/no/such/path")
    end
  end

  describe "stat_archive/3" do
    test "returns the daemon's decoded path stat" do
      id = start_container!(["sleep", "30"])

      assert {:ok, stat} = Docker.stat_archive(id, "/etc/hostname")
      assert stat["name"] === "hostname"
      assert is_integer(stat["size"])
    end

    test "a path that does not exist is :not_found" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.stat_archive(id, "/no/such/path")
    end
  end

  describe "wait_container/3" do
    test "returns the exit status once the container stops" do
      id = start_container!(["/bin/sh", "-c", "exit 0"])

      assert {:ok, %{"StatusCode" => 0}} = Docker.wait_container(id)
    end

    test "a non-zero exit is still a successful call" do
      id = start_container!(["/bin/sh", "-c", "exit 7"])

      assert {:ok, %{"StatusCode" => 7}} = Docker.wait_container(id)
    end

    test "an elapsed :receive_timeout is :gateway_timeout" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :gateway_timeout}} =
               Docker.wait_container(id, %{}, receive_timeout: 100)
    end
  end

  describe "put_archive/4" do
    test "a tar written into the container is readable back out" do
      id = start_container!(["sleep", "30"])
      tar_path = Path.join(System.tmp_dir!(), unique_name("put-archive") <> ".tar")
      on_exit(fn -> File.rm(tar_path) end)

      source = Path.join(System.tmp_dir!(), unique_name("payload"))
      File.write!(source, "hello from the test")
      on_exit(fn -> File.rm(source) end)

      :ok = Docker.Util.create_tar(tar_path, source, verbose: false)

      assert {:ok, _} = Docker.put_archive(id, "/tmp", tar_path)
      assert {:ok, tar} = Docker.get_archive(id, "/tmp/#{Path.basename(source)}")
      assert tar =~ "hello from the test"
    end
  end
end
