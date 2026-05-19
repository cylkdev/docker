defmodule Docker.SandboxTest do
  use ExUnit.Case, async: true

  alias Docker.Sandbox

  # ---------------------------------------------------------------------------
  # The full action table from the plan. Each row drives the exhaustive arity
  # check: for action `:foo` with arity N, the sandbox must export both
  # `foo_response/N` and `set_foo_responses/1`.
  # ---------------------------------------------------------------------------
  @actions [
    {:ping, 1},
    {:version, 1},
    {:socket_available?, 1},
    {:socket_path, 1},
    {:endpoint, 1},
    {:list_containers, 2},
    {:list_images, 2},
    {:list_networks, 2},
    {:find_container, 2},
    {:start_container, 2},
    {:stop_container, 2},
    {:delete_container, 3},
    {:container_logs, 3},
    {:container_running?, 2},
    {:create_container, 4},
    {:find_image, 2},
    {:pull_image, 3},
    {:build_image, 5},
    {:materialize_image, 4},
    {:delete_image, 3},
    {:find_network, 2},
    {:create_network, 3},
    {:connect_network, 3},
    {:delete_network, 2},
    {:exec_create, 3},
    {:exec_start, 2},
    {:exec_inspect, 2},
    {:exec_run, 3},
    {:exec_run_with_status, 3},
    {:put_archive, 4}
  ]

  # ---------------------------------------------------------------------------
  # Happy-path tests (5 representative actions covering "*"-keyed and ref-keyed)
  # ---------------------------------------------------------------------------

  describe "happy path" do
    test "ping_response/1 returns the registered response (\"*\"-keyed)" do
      Sandbox.set_ping_responses([fn -> {:ok, "OK"} end])
      assert {:ok, "OK"} = Sandbox.ping_response([])
    end

    test "list_containers_response/2 returns the registered response (\"*\"-keyed)" do
      Sandbox.set_list_containers_responses([fn -> {:ok, [%{"Id" => "abc"}]} end])
      assert {:ok, [%{"Id" => "abc"}]} = Sandbox.list_containers_response(%{}, [])
    end

    test "find_container_response/2 returns the registered response (ref-keyed)" do
      Sandbox.set_find_container_responses([
        {"abc123", fn -> {:ok, %{"Id" => "abc123"}} end}
      ])

      assert {:ok, %{"Id" => "abc123"}} = Sandbox.find_container_response("abc123", [])
    end

    test "pull_image_response/3 dispatches to the registered function with all args" do
      Sandbox.set_pull_image_responses([
        {"alpine:latest",
         fn image, params, options ->
           {:ok, {image, params, options}}
         end}
      ])

      assert {:ok, {"alpine:latest", %{"foo" => "bar"}, [timeout: 5_000]}} =
               Sandbox.pull_image_response("alpine:latest", %{"foo" => "bar"}, timeout: 5_000)
    end

    test "build_image_response/5 (high arity) dispatches with all 5 args" do
      Sandbox.set_build_image_responses([
        {"my-app:1.0",
         fn ctx, dockerfile, tag, params, options ->
           {:ok, {ctx, dockerfile, tag, params, options}}
         end}
      ])

      assert {:ok, {"./ctx", "Dockerfile", "my-app:1.0", %{}, [foo: :bar]}} =
               Sandbox.build_image_response("./ctx", "Dockerfile", "my-app:1.0", %{}, foo: :bar)
    end
  end

  # ---------------------------------------------------------------------------
  # Regex-match tests (image refs, container refs, network ids)
  # ---------------------------------------------------------------------------

  describe "regex-keyed registration" do
    test "find_image_response matches a regex against the image ref" do
      Sandbox.set_find_image_responses([
        {~r/^alpine.*/, fn _ref -> {:ok, %{"Id" => "sha256:alpine"}} end}
      ])

      assert {:ok, %{"Id" => "sha256:alpine"}} =
               Sandbox.find_image_response("alpine:3.18", [])
    end

    test "find_container_response matches a regex against the container ref" do
      Sandbox.set_find_container_responses([
        {~r/^web-/, fn _ref -> {:ok, %{"Id" => "matched"}} end}
      ])

      assert {:ok, %{"Id" => "matched"}} =
               Sandbox.find_container_response("web-server-1", [])
    end

    test "pull_image_response matches a regex against the image string" do
      Sandbox.set_pull_image_responses([
        {~r/^docker\.io\//, fn _img, _params, _opts -> {:ok, :pulled} end}
      ])

      assert {:ok, :pulled} =
               Sandbox.pull_image_response("docker.io/library/nginx", %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Error-path tests (registered fn returns {:error, _})
  # ---------------------------------------------------------------------------

  describe "error responses" do
    test "ping_response surfaces a registered {:error, _} verbatim" do
      Sandbox.set_ping_responses([fn -> {:error, :econnrefused} end])
      assert {:error, :econnrefused} = Sandbox.ping_response([])
    end

    test "find_image_response surfaces a registered {:error, :not_found}" do
      Sandbox.set_find_image_responses([
        {"missing", fn _ref -> {:error, :not_found} end}
      ])

      assert {:error, :not_found} = Sandbox.find_image_response("missing", [])
    end

    test "list_networks_response surfaces a registered {:error, :timeout}" do
      Sandbox.set_list_networks_responses([fn -> {:error, :timeout} end])
      assert {:error, :timeout} = Sandbox.list_networks_response(%{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Arity-mismatch tests
  # ---------------------------------------------------------------------------

  describe "unsupported arity" do
    test "ping registered with arity 2 raises a clear error" do
      Sandbox.set_ping_responses([fn _a, _b -> :nope end])

      assert_raise RuntimeError, ~r/signature is not supported/, fn ->
        Sandbox.ping_response([])
      end
    end

    test "find_image registered with arity 5 raises a clear error" do
      Sandbox.set_find_image_responses([
        {"any", fn _a, _b, _c, _d, _e -> :nope end}
      ])

      assert_raise RuntimeError, ~r/signature is not supported/, fn ->
        Sandbox.find_image_response("any", [])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # sandbox_disabled?/0 predicate
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
        Sandbox.ping_response([])
      end
    end

    test "calling a response with a missing id raises with the available functions" do
      Sandbox.set_find_image_responses([
        {"a", fn _ref -> {:ok, :a} end}
      ])

      assert_raise RuntimeError, ~r/Function not found/, fn ->
        Sandbox.find_image_response("b", [])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Exhaustive: every action in the canonical table has both
  # `<action>_response/N` and `set_<action>_responses/1` exported with the
  # correct arity. Catches missing actions without N+ duplicate happy-path tests.
  # ---------------------------------------------------------------------------

  @tag :exhaustive
  test "every action in the canonical table is exported with the right arity" do
    Code.ensure_loaded!(Docker.Sandbox)
    exports = Docker.Sandbox.__info__(:functions)

    for {action, public_arity} <- @actions do
      # Elixir does not allow `?` mid-identifier, so helper names drop the `?`
      # while the registry key (the action atom) keeps it.
      base = action |> Atom.to_string() |> String.trim_trailing("?")
      response_name = String.to_atom("#{base}_response")
      setter_name = String.to_atom("set_#{base}_responses")

      assert {response_name, public_arity} in exports,
             "Docker.Sandbox is missing #{response_name}/#{public_arity}"

      assert {setter_name, 1} in exports,
             "Docker.Sandbox is missing #{setter_name}/1"
    end
  end
end
