defmodule Docker.SandboxTest do
  @moduledoc """
  The sandbox is product surface: downstream users register canned responses
  and then call the public `Docker.*` functions with `sandbox: [enabled: true]`.
  These tests drive it the same way, so the dispatch each `Docker.*` function
  performs is exercised rather than bypassed.
  """

  use ExUnit.Case, async: true

  alias Docker.Sandbox

  # ---------------------------------------------------------------------------
  # Happy-path tests (5 representative actions covering "*"-keyed and ref-keyed)
  # ---------------------------------------------------------------------------

  describe "happy path" do
    test "Docker.ping/1 returns the registered response (\"*\"-keyed)" do
      Sandbox.set_ping_responses([fn -> {:ok, "OK"} end])
      assert {:ok, "OK"} = Docker.ping(sandbox: [enabled: true])
    end

    test "Docker.list_containers/2 returns the registered response (\"*\"-keyed)" do
      Sandbox.set_list_containers_responses([fn -> {:ok, [%{"Id" => "abc"}]} end])
      assert {:ok, [%{"Id" => "abc"}]} = Docker.list_containers(%{}, sandbox: [enabled: true])
    end

    test "Docker.find_container/2 returns the registered response (ref-keyed)" do
      Sandbox.set_find_container_responses([
        {"abc123", fn -> {:ok, %{"Id" => "abc123"}} end}
      ])

      assert {:ok, %{"Id" => "abc123"}} =
               Docker.find_container("abc123", sandbox: [enabled: true])
    end

    test "Docker.pull_image/3 dispatches to the registered function with all args" do
      Sandbox.set_pull_image_responses([
        {"alpine:latest",
         fn image, params, options ->
           {:ok, {image, params, options}}
         end}
      ])

      assert {:ok, {"alpine:latest", %{"foo" => "bar"}, options}} =
               Docker.pull_image(
                 "alpine:latest",
                 %{"foo" => "bar"},
                 timeout: 5_000,
                 sandbox: [enabled: true]
               )

      assert options[:timeout] === 5_000
    end

    test "Docker.build_image/5 (high arity) dispatches with all 5 args" do
      Sandbox.set_build_image_responses([
        {"my-app:1.0",
         fn ctx, dockerfile, tag, params, options ->
           {:ok, {ctx, dockerfile, tag, params, options}}
         end}
      ])

      assert {:ok, {"./ctx", "Dockerfile", "my-app:1.0", %{}, options}} =
               Docker.build_image(
                 "./ctx",
                 "Dockerfile",
                 "my-app:1.0",
                 %{},
                 foo: :bar,
                 sandbox: [enabled: true]
               )

      assert options[:foo] === :bar
    end
  end

  # ---------------------------------------------------------------------------
  # Regex-match tests (image refs, container refs, network ids)
  # ---------------------------------------------------------------------------

  describe "regex-keyed registration" do
    test "find_image matches a regex against the image ref" do
      Sandbox.set_find_image_responses([
        {~r/^alpine.*/, fn _ref -> {:ok, %{"Id" => "sha256:alpine"}} end}
      ])

      assert {:ok, %{"Id" => "sha256:alpine"}} =
               Docker.find_image("alpine:3.18", sandbox: [enabled: true])
    end

    test "find_container matches a regex against the container ref" do
      Sandbox.set_find_container_responses([
        {~r/^web-/, fn _ref -> {:ok, %{"Id" => "matched"}} end}
      ])

      assert {:ok, %{"Id" => "matched"}} =
               Docker.find_container("web-server-1", sandbox: [enabled: true])
    end

    test "pull_image matches a regex against the image string" do
      Sandbox.set_pull_image_responses([
        {~r/^docker\.io\//, fn _img, _params, _opts -> {:ok, :pulled} end}
      ])

      assert {:ok, :pulled} =
               Docker.pull_image("docker.io/library/nginx", %{}, sandbox: [enabled: true])
    end
  end

  # ---------------------------------------------------------------------------
  # Error-path tests (registered fn returns {:error, _})
  # ---------------------------------------------------------------------------

  describe "error responses" do
    test "ping surfaces a registered {:error, _} verbatim" do
      error = ErrorMessage.service_unavailable("daemon down", %{reason: :econnrefused})
      Sandbox.set_ping_responses([fn -> {:error, error} end])
      assert {:error, ^error} = Docker.ping(sandbox: [enabled: true])
    end

    test "find_image surfaces a registered {:error, :not_found}" do
      Sandbox.set_find_image_responses([
        {"missing", fn _ref -> {:error, ErrorMessage.not_found("no such image")} end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.find_image("missing", sandbox: [enabled: true])
    end

    test "list_networks surfaces a registered {:error, _} verbatim" do
      Sandbox.set_list_networks_responses([
        fn -> {:error, ErrorMessage.gateway_timeout("timed out")} end
      ])

      assert {:error, %ErrorMessage{code: :gateway_timeout}} =
               Docker.list_networks(%{}, sandbox: [enabled: true])
    end
  end

  # ---------------------------------------------------------------------------
  # Arity-mismatch tests
  # ---------------------------------------------------------------------------

  describe "unsupported arity" do
    test "ping registered with arity 2 raises a clear error" do
      Sandbox.set_ping_responses([fn _a, _b -> :nope end])

      assert_raise RuntimeError, ~r/signature is not supported/, fn ->
        Docker.ping(sandbox: [enabled: true])
      end
    end

    test "find_image registered with arity 5 raises a clear error" do
      Sandbox.set_find_image_responses([
        {"any", fn _a, _b, _c, _d, _e -> :nope end}
      ])

      assert_raise RuntimeError, ~r/signature is not supported/, fn ->
        Docker.find_image("any", sandbox: [enabled: true])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # sandbox_disabled?/0 predicate
  #
  # No `Docker.*` function exposes this — it is the opt-out hook the sandbox
  # consults internally — so it is called directly.
  # ---------------------------------------------------------------------------

  describe "sandbox_disabled?/0" do
    test "is false when the calling pid has not opted out" do
      refute Sandbox.sandbox_disabled?()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpful failure when no responses are registered for the calling pid
  # ---------------------------------------------------------------------------

  describe "helpful errors" do
    test "calling a response without registering raises with setup hints" do
      assert_raise RuntimeError, ~r/No functions have been registered/, fn ->
        Docker.ping(sandbox: [enabled: true])
      end
    end

    test "calling a response with a missing id raises with the available functions" do
      Sandbox.set_find_image_responses([
        {"a", fn _ref -> {:ok, :a} end}
      ])

      assert_raise RuntimeError, ~r/Function not found/, fn ->
        Docker.find_image("b", sandbox: [enabled: true])
      end
    end
  end
end
