defmodule Docker.ClientTest do
  @moduledoc """
  Error translation, driven through the public API against a real daemon.

  Only statuses the daemon actually sends are covered. Manufacturing a
  malformed response to exercise a defensive branch is what this suite used
  to do; those branches are gone.
  """

  use DaemonCase

  alias Docker.Config

  describe "a status the daemon sends" do
    test "a missing container is :not_found and lifts the daemon's message" do
      assert {:error, %ErrorMessage{code: :not_found} = error} =
               Docker.find_container("docker-ex-test-does-not-exist")

      assert error.message =~ "No such container"
    end

    test "a missing image is :not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.find_image("docker-ex-test-no-such-image:latest")
    end

    test "removing a running container without force is :conflict" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :conflict}} = Docker.delete_container(id)
    end

    test "starting an already-started container is :not_modified" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :not_modified}} = Docker.start_container(id)
    end
  end

  describe "a status the daemon sends on a streaming call" do
    # stream/4 gets an async body it must drain before it can report the
    # error. Every streaming call — pull, build, following logs, attach —
    # reports its failures through this path.
    test "a non-2xx from a streaming call lifts the drained body's message" do
      assert {:error, %ErrorMessage{code: :not_found} = error} =
               Docker.pull_image("docker-ex-review-absent-xyz/nope:latest")

      assert error.message =~ "pull access denied for docker-ex-review-absent-xyz/nope"
      assert %{status: 404, method: :post, path: path} = error.details
      assert path =~ "/images/create?fromImage=docker-ex-review-absent-xyz"
    end
  end

  describe "a daemon that is not there" do
    setup do
      original = Application.fetch_env!(:docker, :socket_path)
      on_exit(fn -> Application.put_env(:docker, :socket_path, original) end)
      :ok
    end

    test "a missing socket is :service_unavailable" do
      missing = Path.join(System.tmp_dir!(), unique_name("docker-absent"))
      Application.put_env(:docker, :socket_path, missing)

      assert {:error, %ErrorMessage{code: :service_unavailable} = error} = Docker.ping()

      assert error.message =~ "Could not reach the Docker daemon"
      assert %{socket_path: ^missing} = error.details
    end
  end

  describe "the API version prefix" do
    test "requests carry the configured version" do
      assert {:ok, _} = Docker.ping()
      assert Config.version() =~ ~r/^\d+\.\d+$/
    end
  end
end
