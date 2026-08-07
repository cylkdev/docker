defmodule Docker.ImagesTest do
  @moduledoc "Image reads against a real daemon."

  use DaemonCase

  describe "find_image/2" do
    test "returns the image by name and tag" do
      assert {:ok, image} = Docker.find_image("alpine:3.19")
      assert image["Id"] =~ "sha256:"
      assert "alpine:3.19" in image["RepoTags"]
    end

    test "returns the same image by its id" do
      {:ok, by_tag} = Docker.find_image("alpine:3.19")

      assert {:ok, by_id} = Docker.find_image(by_tag["Id"])
      assert by_id["Id"] === by_tag["Id"]
    end

    test "an image that is not present is :not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.find_image("docker-ex-test-absent:latest")
    end
  end

  describe "list_images/2" do
    test "includes the test image" do
      assert {:ok, images} = Docker.list_images()

      assert Enum.any?(images, fn image ->
               is_list(image["RepoTags"]) and "alpine:3.19" in image["RepoTags"]
             end)
    end

    test "a reference filter narrows the list" do
      assert {:ok, images} = Docker.list_images(%{filters: [reference: ["alpine*"]]})
      refute images === []

      assert Enum.all?(images, fn image ->
               Enum.any?(image["RepoTags"] || [], &String.starts_with?(&1, "alpine"))
             end)
    end
  end

  describe "materialize_image/4" do
    # No default arguments: all four are required.
    test "an image already present is returned without pulling" do
      assert {:ok, image} = Docker.materialize_image("alpine:3.19", "alpine:3.19", %{}, [])
      assert image["Id"] =~ "sha256:"
    end
  end

  describe "pull_image/3" do
    test "streams progress events and leaves the image present" do
      assert {:ok, stream} = Docker.pull_image("alpine:3.19")

      events = Enum.to_list(stream)

      assert Enum.any?(events, &Map.has_key?(&1, "status"))
      assert {:ok, _} = Docker.find_image("alpine:3.19")
    end
  end
end
