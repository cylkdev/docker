if Code.ensure_loaded?(SandboxRegistry) do
  defmodule Docker.Engine.Sandbox do
    @moduledoc """
    Per-process canned responses for `Docker.*` functions. Lets your tests
    pretend a Docker daemon is there without ever opening a connection.

    Each test registers its own response functions, scoped to its own pid.
    Tests stay async and never collide.

    ## How to use it in a test

    Start the registry once in `test_helper.exs`:

        Docker.Engine.Sandbox.start_link()
        ExUnit.start()

    In a test, register a response and call the API with `sandbox: [enabled: true]`:

        defmodule MyTest do
          use ExUnit.Case, async: true

          test "lists containers" do
            Docker.Engine.Sandbox.set_list_containers_responses([
              fn -> {:ok, [%{"Id" => "abc"}]} end
            ])

            assert {:ok, [%{"Id" => "abc"}]} =
                     Docker.list_containers(%{}, sandbox: [enabled: true])
          end

          test "find an image with a regex id" do
            Docker.Engine.Sandbox.set_find_image_responses([
              {~r/alpine.*/, fn _id -> {:ok, %{"Id" => "sha256:abc"}} end}
            ])

            assert {:ok, %{"Id" => "sha256:abc"}} =
                     Docker.find_image("alpine:latest", sandbox: [enabled: true])
          end
        end

    ## Identifiers

    Every action lookup is keyed by `{action, id}` where:

      * `action` is an **atom** like `:ping`, `:find_container`,
        `:container_running?` (mid-`?` is fine in atoms; only the
        helper function names drop the trailing `?`).
      * `id` is a **string** — the container ref, image ref, or network ref,
        or the literal `"*"` for actions with no natural id (e.g. `:ping`,
        `:list_*`).

    ## What sandbox mode does NOT do

      * It does not validate inputs — your registered function gets the args
        verbatim. If your code has a bug that passes the wrong shape, the
        sandbox will not catch it.
      * It does not simulate transport errors unless your function returns
        one. Test transport-error handling against the real `Sorrel`
        modules with a fake server.

    ## Examples

        iex> Docker.Engine.Sandbox.set_ping_responses([fn -> {:ok, "OK"} end])
        iex> Docker.ping(sandbox: [enabled: true])
        {:ok, "OK"}
    """

    @registry :docker_engine_sandbox
    @state "state"
    @disabled "disabled"
    @sleep 10
    @keys :unique

    @doc """
    Starts the registry that holds per-process canned responses.

    Call this once at the top of your `test_helper.exs`, before
    `ExUnit.start()`.
    """
    @spec start_link() :: GenServer.on_start()
    def start_link do
      Registry.start_link(keys: @keys, name: @registry)
    end

    # =========================================================================
    # Per-action retrieval and registration
    # =========================================================================

    # ---- ping ("*", arity 1) ------------------------------------------------

    @doc "Returns the registered response for `Docker.ping/1`."
    def ping_response(opts) do
      doc_examples = ["fn -> {:ok, \"OK\"} end", "fn (opts) -> ... end"]
      func = find!(:ping, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.ping/1`."
    def set_ping_responses(funcs) do
      set_responses(:ping, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- version ("*", arity 1) ---------------------------------------------

    @doc "Returns the registered response for `Docker.version/1`."
    def version_response(opts) do
      doc_examples = ["fn -> {:ok, %{...}} end", "fn (opts) -> ... end"]
      func = find!(:version, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.version/1`."
    def set_version_responses(funcs) do
      set_responses(:version, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- socket_available? ("*", arity 1) -----------------------------------
    # Note: Elixir does not allow `?` mid-identifier, so the response/setter
    # helpers drop the trailing `?` from `Docker.socket_available?/1`. The
    # registry key `:socket_available?` (atom) keeps the `?`.

    @doc "Returns the registered response for `Docker.socket_available?/1`."
    def socket_available_response(opts) do
      doc_examples = ["fn -> true end", "fn (opts) -> ... end"]
      func = find!(:socket_available?, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.socket_available?/1`."
    def set_socket_available_responses(funcs) do
      set_responses(:socket_available?, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- socket_path ("*", arity 1) -----------------------------------------

    @doc "Returns the registered response for `Docker.socket_path/1`."
    def socket_path_response(opts) do
      doc_examples = ["fn -> \"/var/run/docker.sock\" end", "fn (opts) -> ... end"]
      func = find!(:socket_path, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.socket_path/1`."
    def set_socket_path_responses(funcs) do
      set_responses(:socket_path, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- endpoint ("*", arity 1) --------------------------------------------

    @doc "Returns the registered response for `Docker.endpoint/1`."
    def endpoint_response(opts) do
      doc_examples = ["fn -> %Sorrel.Endpoint{} end", "fn (opts) -> ... end"]
      func = find!(:endpoint, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.endpoint/1`."
    def set_endpoint_responses(funcs) do
      set_responses(:endpoint, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- list_containers ("*", arity 2: params, opts) -----------------------

    @doc "Returns the registered response for `Docker.list_containers/2`."
    def list_containers_response(params, opts) do
      doc_examples = [
        "fn -> {:ok, [...]} end",
        "fn (params) -> ... end",
        "fn (params, opts) -> ... end"
      ]

      func = find!(:list_containers, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(params)
        2 -> func.(params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.list_containers/2`."
    def set_list_containers_responses(funcs) do
      set_responses(:list_containers, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- list_images ("*", arity 2) -----------------------------------------

    @doc "Returns the registered response for `Docker.list_images/2`."
    def list_images_response(params, opts) do
      doc_examples = [
        "fn -> {:ok, [...]} end",
        "fn (params) -> ... end",
        "fn (params, opts) -> ... end"
      ]

      func = find!(:list_images, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(params)
        2 -> func.(params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.list_images/2`."
    def set_list_images_responses(funcs) do
      set_responses(:list_images, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- list_networks ("*", arity 2) ---------------------------------------

    @doc "Returns the registered response for `Docker.list_networks/2`."
    def list_networks_response(params, opts) do
      doc_examples = [
        "fn -> {:ok, [...]} end",
        "fn (params) -> ... end",
        "fn (params, opts) -> ... end"
      ]

      func = find!(:list_networks, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(params)
        2 -> func.(params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.list_networks/2`."
    def set_list_networks_responses(funcs) do
      set_responses(:list_networks, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- find_container (ref, opts) -----------------------------------------

    @doc "Returns the registered response for `Docker.find_container/2`."
    def find_container_response(container_ref, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, opts) -> ... end"
      ]

      func = find!(:find_container, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.find_container/2`."
    def set_find_container_responses(tuples) do
      set_responses(:find_container, tuples)
    end

    # ---- start_container (ref, opts) ----------------------------------------

    @doc "Returns the registered response for `Docker.start_container/2`."
    def start_container_response(container_ref, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, opts) -> ... end"
      ]

      func = find!(:start_container, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.start_container/2`."
    def set_start_container_responses(tuples) do
      set_responses(:start_container, tuples)
    end

    # ---- stop_container (ref, opts) -----------------------------------------

    @doc "Returns the registered response for `Docker.stop_container/2`."
    def stop_container_response(container_ref, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, opts) -> ... end"
      ]

      func = find!(:stop_container, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.stop_container/2`."
    def set_stop_container_responses(tuples) do
      set_responses(:stop_container, tuples)
    end

    # ---- delete_container (ref, params, opts) -------------------------------

    @doc "Returns the registered response for `Docker.delete_container/3`."
    def delete_container_response(container_ref, params, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, params) -> ... end",
        "fn (container_ref, params, opts) -> ... end"
      ]

      func = find!(:delete_container, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, params)
        3 -> func.(container_ref, params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.delete_container/3`."
    def set_delete_container_responses(tuples) do
      set_responses(:delete_container, tuples)
    end

    # ---- container_logs (ref, params, opts) ---------------------------------

    @doc "Returns the registered response for `Docker.container_logs/3`."
    def container_logs_response(container_ref, params, opts) do
      doc_examples = [
        "fn -> {:ok, \"...\"} end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, params) -> ... end",
        "fn (container_ref, params, opts) -> ... end"
      ]

      func = find!(:container_logs, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, params)
        3 -> func.(container_ref, params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.container_logs/3`."
    def set_container_logs_responses(tuples) do
      set_responses(:container_logs, tuples)
    end

    # ---- container_running? (binary clause: ref, opts) ----------------------
    # Note: Elixir does not allow `?` mid-identifier, so the response/setter
    # helpers drop the trailing `?` from `Docker.container_running?/2`. The
    # registry key `:container_running?` (atom) keeps the `?`.

    @doc "Returns the registered response for `Docker.container_running?/2` (binary clause)."
    def container_running_response(container_ref, opts) do
      doc_examples = [
        "fn -> true end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, opts) -> ... end"
      ]

      func = find!(:container_running?, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.container_running?/2` (binary clause)."
    def set_container_running_responses(tuples) do
      set_responses(:container_running?, tuples)
    end

    # ---- create_container ("*", arity 3: name, image, opts) -----------------

    @doc "Returns the registered response for `Docker.create_container/3`."
    def create_container_response(name, image, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (name) -> ... end",
        "fn (name, image) -> ... end",
        "fn (name, image, opts) -> ... end"
      ]

      func = find!(:create_container, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(name)
        2 -> func.(name, image)
        3 -> func.(name, image, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.create_container/3`."
    def set_create_container_responses(funcs) do
      set_responses(:create_container, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- find_image (ref, opts) ---------------------------------------------

    @doc "Returns the registered response for `Docker.find_image/2`."
    def find_image_response(image_ref, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (image_ref) -> ... end",
        "fn (image_ref, opts) -> ... end"
      ]

      func = find!(:find_image, image_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(image_ref)
        2 -> func.(image_ref, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.find_image/2`."
    def set_find_image_responses(tuples) do
      set_responses(:find_image, tuples)
    end

    # ---- pull_image (image, params, opts) -----------------------------------

    @doc "Returns the registered response for `Docker.pull_image/3`."
    def pull_image_response(image, params, opts) do
      doc_examples = [
        "fn -> {:ok, ...} end",
        "fn (image) -> ... end",
        "fn (image, params) -> ... end",
        "fn (image, params, opts) -> ... end"
      ]

      func = find!(:pull_image, image, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(image)
        2 -> func.(image, params)
        3 -> func.(image, params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.pull_image/3`."
    def set_pull_image_responses(tuples) do
      set_responses(:pull_image, tuples)
    end

    # ---- build_image (context_path, dockerfile, tag, params, opts) ----------

    @doc "Returns the registered response for `Docker.build_image/5`."
    # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
    def build_image_response(context_path, dockerfile, tag, params, opts) do
      doc_examples = [
        "fn -> {:ok, ...} end",
        "fn (context_path) -> ... end",
        "fn (context_path, dockerfile) -> ... end",
        "fn (context_path, dockerfile, tag) -> ... end",
        "fn (context_path, dockerfile, tag, params) -> ... end",
        "fn (context_path, dockerfile, tag, params, opts) -> ... end"
      ]

      func = find!(:build_image, tag, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(context_path)
        2 -> func.(context_path, dockerfile)
        3 -> func.(context_path, dockerfile, tag)
        4 -> func.(context_path, dockerfile, tag, params)
        5 -> func.(context_path, dockerfile, tag, params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.build_image/5`."
    def set_build_image_responses(tuples) do
      set_responses(:build_image, tuples)
    end

    # ---- materialize_image (image_ref, image_or_path, params, opts) ---------

    @doc "Returns the registered response for `Docker.materialize_image/4`."
    def materialize_image_response(image_ref, image_or_path, params, opts) do
      doc_examples = [
        "fn -> {:ok, ...} end",
        "fn (image_ref) -> ... end",
        "fn (image_ref, image_or_path) -> ... end",
        "fn (image_ref, image_or_path, params) -> ... end",
        "fn (image_ref, image_or_path, params, opts) -> ... end"
      ]

      func = find!(:materialize_image, image_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(image_ref)
        2 -> func.(image_ref, image_or_path)
        3 -> func.(image_ref, image_or_path, params)
        4 -> func.(image_ref, image_or_path, params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.materialize_image/4`."
    def set_materialize_image_responses(tuples) do
      set_responses(:materialize_image, tuples)
    end

    # ---- delete_image (image_ref, params, opts) -----------------------------

    @doc "Returns the registered response for `Docker.delete_image/3`."
    def delete_image_response(image_ref, params, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (image_ref) -> ... end",
        "fn (image_ref, params) -> ... end",
        "fn (image_ref, params, opts) -> ... end"
      ]

      func = find!(:delete_image, image_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(image_ref)
        2 -> func.(image_ref, params)
        3 -> func.(image_ref, params, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.delete_image/3`."
    def set_delete_image_responses(tuples) do
      set_responses(:delete_image, tuples)
    end

    # ---- find_network (network_id, opts) ------------------------------------

    @doc "Returns the registered response for `Docker.find_network/2`."
    def find_network_response(network_id, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (network_id) -> ... end",
        "fn (network_id, opts) -> ... end"
      ]

      func = find!(:find_network, network_id, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(network_id)
        2 -> func.(network_id, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.find_network/2`."
    def set_find_network_responses(tuples) do
      set_responses(:find_network, tuples)
    end

    # ---- create_network ("*", arity 2: name, opts) --------------------------

    @doc "Returns the registered response for `Docker.create_network/2`."
    def create_network_response(name, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (name) -> ... end",
        "fn (name, opts) -> ... end"
      ]

      func = find!(:create_network, "*", doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(name)
        2 -> func.(name, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.create_network/2`."
    def set_create_network_responses(funcs) do
      set_responses(:create_network, Enum.map(funcs, fn f -> {"*", f} end))
    end

    # ---- connect_network (network_id, container_ref, opts) ------------------

    @doc "Returns the registered response for `Docker.connect_network/3`."
    def connect_network_response(network_id, container_ref, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (network_id) -> ... end",
        "fn (network_id, container_ref) -> ... end",
        "fn (network_id, container_ref, opts) -> ... end"
      ]

      func = find!(:connect_network, network_id, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(network_id)
        2 -> func.(network_id, container_ref)
        3 -> func.(network_id, container_ref, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.connect_network/3`."
    def set_connect_network_responses(tuples) do
      set_responses(:connect_network, tuples)
    end

    # ---- delete_network (network_id, opts) ----------------------------------

    @doc "Returns the registered response for `Docker.delete_network/2`."
    def delete_network_response(network_id, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (network_id) -> ... end",
        "fn (network_id, opts) -> ... end"
      ]

      func = find!(:delete_network, network_id, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(network_id)
        2 -> func.(network_id, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.delete_network/2`."
    def set_delete_network_responses(tuples) do
      set_responses(:delete_network, tuples)
    end

    # ---- exec_create (container_ref, cmd, opts) -----------------------------

    @doc "Returns the registered response for `Docker.exec_create/3`."
    def exec_create_response(container_ref, cmd, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, cmd) -> ... end",
        "fn (container_ref, cmd, opts) -> ... end"
      ]

      func = find!(:exec_create, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, cmd)
        3 -> func.(container_ref, cmd, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.exec_create/3`."
    def set_exec_create_responses(tuples) do
      set_responses(:exec_create, tuples)
    end

    # ---- exec_start (exec_id, opts) -----------------------------------------

    @doc "Returns the registered response for `Docker.exec_start/2`."
    def exec_start_response(exec_id, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (exec_id) -> ... end",
        "fn (exec_id, opts) -> ... end"
      ]

      func = find!(:exec_start, exec_id, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(exec_id)
        2 -> func.(exec_id, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.exec_start/2`."
    def set_exec_start_responses(tuples) do
      set_responses(:exec_start, tuples)
    end

    # ---- exec_inspect (exec_id, opts) ---------------------------------------

    @doc "Returns the registered response for `Docker.exec_inspect/2`."
    def exec_inspect_response(exec_id, opts) do
      doc_examples = [
        "fn -> {:ok, %{...}} end",
        "fn (exec_id) -> ... end",
        "fn (exec_id, opts) -> ... end"
      ]

      func = find!(:exec_inspect, exec_id, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(exec_id)
        2 -> func.(exec_id, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.exec_inspect/2`."
    def set_exec_inspect_responses(tuples) do
      set_responses(:exec_inspect, tuples)
    end

    # ---- exec_run (container_ref, cmd, opts) --------------------------------

    @doc "Returns the registered response for `Docker.exec_run/3`."
    def exec_run_response(container_ref, cmd, opts) do
      doc_examples = [
        "fn -> {:ok, \"...\"} end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, cmd) -> ... end",
        "fn (container_ref, cmd, opts) -> ... end"
      ]

      func = find!(:exec_run, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, cmd)
        3 -> func.(container_ref, cmd, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.exec_run/3`."
    def set_exec_run_responses(tuples) do
      set_responses(:exec_run, tuples)
    end

    # ---- exec_run_with_status (container_ref, cmd, opts) --------------------

    @doc "Returns the registered response for `Docker.exec_run_with_status/3`."
    def exec_run_with_status_response(container_ref, cmd, opts) do
      doc_examples = [
        "fn -> {:ok, \"...\", 0} end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, cmd) -> ... end",
        "fn (container_ref, cmd, opts) -> ... end"
      ]

      func = find!(:exec_run_with_status, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, cmd)
        3 -> func.(container_ref, cmd, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.exec_run_with_status/3`."
    def set_exec_run_with_status_responses(tuples) do
      set_responses(:exec_run_with_status, tuples)
    end

    # ---- put_archive (container_ref, dest_path, tar, opts) ------------------

    @doc "Returns the registered response for `Docker.put_archive/4`."
    def put_archive_response(container_ref, dest_path, tar, opts) do
      doc_examples = [
        "fn -> :ok end",
        "fn (container_ref) -> ... end",
        "fn (container_ref, dest_path) -> ... end",
        "fn (container_ref, dest_path, tar) -> ... end",
        "fn (container_ref, dest_path, tar, opts) -> ... end"
      ]

      func = find!(:put_archive, container_ref, doc_examples)

      case :erlang.fun_info(func)[:arity] do
        0 -> func.()
        1 -> func.(container_ref)
        2 -> func.(container_ref, dest_path)
        3 -> func.(container_ref, dest_path, tar)
        4 -> func.(container_ref, dest_path, tar, opts)
        _ -> raise_unsupported_arity(func, doc_examples)
      end
    end

    @doc "Registers responses for `Docker.put_archive/4`."
    def set_put_archive_responses(tuples) do
      set_responses(:put_archive, tuples)
    end

    # =========================================================================
    # Sandbox control
    # =========================================================================

    @doc "Disables the sandbox for the calling process."
    @spec disable_docker_sandbox(map()) :: :ok
    def disable_docker_sandbox(_context) do
      with {:error, :registry_not_started} <-
             SandboxRegistry.register(@registry, @disabled, %{}, @keys) do
        raise_not_started!()
      end
    end

    @doc "Returns true if the sandbox is disabled for the calling process."
    @spec sandbox_disabled?() :: boolean()
    def sandbox_disabled? do
      case SandboxRegistry.lookup(@registry, @disabled) do
        {:ok, _state} -> true
        {:error, :registry_not_started} -> raise_not_started!()
        {:error, :pid_not_registered} -> false
      end
    end

    # =========================================================================
    # Private helpers (verbatim from AWS.S3.Sandbox template)
    # =========================================================================

    defp set_responses(key, tuples) do
      tuples
      |> Map.new(fn {id, func} -> {{key, id}, func} end)
      |> then(&SandboxRegistry.register(@registry, @state, &1, @keys))
      |> then(fn
        :ok -> :ok
        {:error, :registry_not_started} -> raise_not_started!()
      end)

      Process.sleep(@sleep)
    end

    @doc false
    def find!(action, id, doc_examples) do
      case SandboxRegistry.lookup(@registry, @state) do
        {:ok, state} ->
          find_response!(state, action, id, doc_examples)

        {:error, :pid_not_registered} ->
          raise """
          No functions have been registered for #{inspect(self())}.

          Action: #{inspect(action)}
          Id: #{inspect(id)}

          Add one of the following patterns to your test setup:

          #{format_example(action, id, doc_examples)}

          Replace `_response` with the value you want the sandbox to return.
          This determines how #{inspect(__MODULE__)} responds when
          `#{inspect(action)}` is called on id #{inspect(id)}.
          """

        {:error, :registry_not_started} ->
          raise """
          Registry not started for #{inspect(__MODULE__)}.

          Add the following line to your `test_helper.exs` to ensure the
          registry is started for this application:

              #{inspect(__MODULE__)}.start_link()
          """
      end
    end

    defp find_response!(state, action, id, doc_examples) do
      sandbox_key = {action, id}

      with state when is_map(state) <- Map.get(state, sandbox_key, state),
           regexes <-
             Enum.filter(state, fn {{_registered_action, registered_pattern}, _func} ->
               regex?(registered_pattern)
             end),
           {_action_pattern, func} when is_function(func) <-
             Enum.find(regexes, state, fn {{registered_action, regex}, _func} ->
               Regex.match?(regex, id) and registered_action === action
             end) do
        func
      else
        func when is_function(func) ->
          func

        functions when is_map(functions) ->
          functions_text =
            Enum.map_join(functions, "\n", fn {key, val} ->
              " #{inspect(key)} => #{inspect(val)}"
            end)

          example =
            action
            |> format_example(id, doc_examples)
            |> indent("  ")

          raise """
          Function not found.

            action: #{inspect(action)}
            id: #{inspect(id)}
            pid: #{inspect(self())}

          Found:

          #{functions_text}

          ---

          You need to register mock responses for `#{inspect(action)}` requests
          so the sandbox knows how to respond during tests.

          Add the following to your `test_helper.exs` or inside the test's
          `setup` block:

          #{example}
          """

        other ->
          raise """
          Unrecognized input for #{inspect(sandbox_key)} in #{inspect(self())}.

          Response does not match the expected format for #{inspect(__MODULE__)}.

          Found value:

          #{inspect(other)}

          To fix this, update your test setup to include one of the following
          response patterns:

          #{format_example(action, id, doc_examples)}

          Replace `_response` with the value you want the sandbox to return.
          This determines how #{inspect(__MODULE__)} responds when
          `#{inspect(action)}` is called on id #{inspect(id)}.
          """
      end
    end

    defp regex?(%Regex{}), do: true
    defp regex?(_other), do: false

    defp indent(text, prefix) do
      text
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", &"#{prefix}#{&1}")
    end

    defp format_example(action, _id, doc_examples) do
      base = action |> Atom.to_string() |> String.trim_trailing("?")

      """
      alias #{inspect(__MODULE__)}

      setup do
        #{inspect(__MODULE__)}.set_#{base}_responses([
          #{Enum.map_join(doc_examples, "\n    # or\n", &("    " <> &1))}
          # or
          {~r|pattern|, fn -> _response end}
        ])
      end
      """
    end

    defp raise_unsupported_arity(func, doc_examples) do
      raise """
      This function's signature is not supported: #{inspect(func)}

      Please provide a function with one of the following arities (0-#{length(doc_examples) - 1}):

      #{Enum.map_join(doc_examples, "\n", &("    " <> &1))}
      """
    end

    defp raise_not_started! do
      raise """
      Registry not started for #{inspect(__MODULE__)}.

      To fix this, add the following line to your `test_helper.exs`:

          #{inspect(__MODULE__)}.start_link()

      This ensures the registry is running for your tests.
      """
    end
  end
end
