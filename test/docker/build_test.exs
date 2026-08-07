defmodule Docker.BuildTest do
  @moduledoc "Image building against a real daemon."

  use DaemonCase

  @context Path.expand("../fixtures", __DIR__)

  defp unique_tag, do: unique_name("docker-ex-test-build") <> ":latest"

  describe "build_image/5" do
    test "streams build output and leaves a tagged image" do
      tag = unique_tag()
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)

      assert {:ok, stream} = Docker.build_image(@context, "Dockerfile", tag)

      events = Enum.to_list(stream)
      assert Enum.any?(events, &Map.has_key?(&1, "stream"))

      assert {:ok, image} = Docker.find_image(tag)
      assert tag in image["RepoTags"]
    end

    test "an empty tag is :bad_request" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               Docker.build_image(@context, "Dockerfile", "")
    end

    test "a context path that is not a directory is :bad_request" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               Docker.build_image("/no/such/context", "Dockerfile", unique_tag())
    end
  end

  describe "run_build_image/5" do
    # run_build_image/5 drains the stream itself and returns bare :ok, NOT {:ok, _}.
    test "builds and returns the tag without the caller draining a stream" do
      tag = unique_tag()
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)

      assert :ok = Docker.run_build_image(@context, "Dockerfile", tag)
      assert {:ok, _image} = Docker.find_image(tag)
    end
  end

  describe "delete_image/3" do
    test "a deleted image is no longer findable" do
      tag = unique_tag()
      :ok = Docker.run_build_image(@context, "Dockerfile", tag)
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)

      assert {:ok, _} = Docker.delete_image(tag, %{force: true})
      assert {:error, %ErrorMessage{code: :not_found}} = Docker.find_image(tag)
    end
  end

  describe "the built image" do
    test "carries what the Dockerfile put in it" do
      tag = unique_tag()
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)
      :ok = Docker.run_build_image(@context, "Dockerfile", tag)

      name = unique_name("docker-ex-test")
      {:ok, id} = Docker.create_container("docker-ex-test", name, tag, %{}, cmd: ["sleep", "30"])
      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)
      {:ok, _} = Docker.start_container(id)

      assert {:ok, output} = Docker.exec_run(id, ["/bin/cat", "/built.txt"])
      assert output =~ "built by the test suite"
    end
  end
end
