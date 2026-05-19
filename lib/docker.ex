defmodule Docker do
  @moduledoc """
  Elixir client for the Docker Engine API.

  Use this library to create and run Docker containers from Elixir: pull
  images, create containers, start them, run commands inside them, read
  their logs, manage networks, and more.

  ## How it works

  Your code calls functions in this library. The library translates those
  calls into HTTP requests and sends them to a running Docker daemon. The
  daemon does the actual container work.

      ┌──────────────────────────────────────┐
      │           Your Elixir code           │
      │   Docker.create_container("my-app")  │
      └──────────────────┬───────────────────┘
                         │  function call
                         ▼
      ┌──────────────────────────────────────┐
      │         This library (Docker)        │
      │  Translates calls into HTTP requests │
      └──────────────────┬───────────────────┘
                         │  HTTP over Unix socket or TCP
                         ▼
      ┌──────────────────────────────────────┐
      │           Docker daemon              │
      │  (dockerd, running on your machine)  │
      │  Does the actual container work      │
      └──────────────────────────────────────┘

  The daemon is a background process that Docker Desktop or the Docker
  CLI starts for you. By default this library connects to it over the
  local Unix socket at `/var/run/docker.sock` or
  `~/.docker/run/docker.sock`.

  ## Quick start

      # 1. Verify the daemon is reachable
      {:ok, "OK"} = Docker.ping()

      # 2. Pull the image you want to use (only needed once — Docker caches it)
      {:ok, pull_stream} = Docker.pull_image("alpine:3.19")
      Stream.run(pull_stream)

      # 3. Create a container from the image, give it a name
      {:ok, _id} = Docker.create_container("my-worker", "alpine:3.19", %{})

      # 4. Start the container
      {:ok, _} = Docker.start_container("my-worker")

      # 5. Run a command inside the running container
      {:ok, output} = Docker.terminal_run("my-worker", "echo hello")
      IO.puts(output)
      # => "hello\\n"

      # 6. Stop and remove the container when done
      Docker.stop_container("my-worker")
      Docker.delete_container("my-worker")

  ## Container names and labels

  Every container has a name you give it when you create it. Use that name
  anywhere a container ID would work — it is easier to remember than a hex ID.

  Labels are key-value string pairs you attach to a container at creation
  time. They let you tag containers with metadata (environment, role, owner)
  and then filter by that metadata later.

  ### Creating a container with labels

      {:ok, _id} =
        Docker.create_container(
          "worker-1",
          "alpine:3.19",
          %{"env" => "staging", "role" => "worker"}
        )

  ### Finding a container by name

      {:ok, container} = Docker.find_container("worker-1")
      container["Id"]                  # full 64-char hex ID
      container["State"]["Running"]    # true or false
      container["Labels"]              # %{"env" => "staging", "role" => "worker"}

  ### Listing containers filtered by label

      # All running containers with role=worker
      {:ok, workers} = Docker.list_containers(%{}, labels: ["role=worker"])

      # Multiple constraints — containers must match ALL of them (AND logic)
      {:ok, staging_workers} =
        Docker.list_containers(%{}, labels: ["env=staging", "role=worker"])

      # Match a label key regardless of its value
      {:ok, any_env} = Docker.list_containers(%{}, labels: ["env"])

      # Include stopped containers too
      {:ok, all_workers} =
        Docker.list_containers(%{all: true}, labels: ["role=worker"])

  ## Running commands in a container

  `Docker.Terminal` is the recommended way to run commands in a running
  container.

  ### One-shot command

  Run a command and get its output back as a string:

      {:ok, output} = Docker.terminal_run("my-worker", "echo hello")
      # output => "hello\\n"

  Pass a string to run it through `/bin/sh -c` (shell features like pipes
  and redirects work). Pass a list to run the command directly:

      {:ok, output} = Docker.terminal_run("my-worker", ["cat", "/etc/hostname"])

  Get the exit code too:

      {:ok, %{output: out, exit_code: code}} =
        Docker.terminal_run_with_status("my-worker", "ls /nonexistent")
      # code => 1 (the command failed)

  ### Persistent shell

  Open a shell once and send several commands to it. State carries across
  commands — the working directory and environment variables persist:

      {:ok, term}      = Docker.terminal_open("my-worker")
      {:ok, _, term}   = Docker.terminal_command(term, "cd /tmp")
      {:ok, _, term}   = Docker.terminal_command(term, "echo hello > greeting.txt")
      {:ok, out, term} = Docker.terminal_command(term, "cat greeting.txt")
      IO.puts(out)
      # => "hello\\n"
      :ok = Docker.terminal_close(term)

  `terminal_command/2` returns an updated handle each time — thread that
  handle through each call to keep the session alive. See `Docker.Terminal`
  for more options (custom shell, timeout, PTY allocation).

  ## Connecting to a daemon

  Every function accepts an optional keyword list for selecting which daemon
  to connect to:

  | Option       | What it does                                                            |
  |--------------|-------------------------------------------------------------------------|
  | `:host`      | URL string: `"unix:///path"`, `"tcp://host:2375"`, `"https://host:2376"` |
  | `:socket`    | Unix socket path shortcut                                               |
  | `:endpoint`  | Pre-built `Docker.Endpoint` value (advanced)                            |
  | `:tls`       | TLS material map for TCP endpoints                                      |
  | `:version`   | Docker Engine API version string override                               |

  When none of these is given, the library checks the `DOCKER_HOST`
  environment variable, then tries `~/.docker/run/docker.sock` and
  `/var/run/docker.sock` in order. See `Docker.Daemon.endpoint/1` for the
  full resolution order.

      # Local default socket
      Docker.ping()

      # Remote TCP
      Docker.ping(host: "tcp://10.0.0.1:2375")

      # Remote TCP with mTLS
      Docker.ping(
        host: "tcp://10.0.0.1:2376",
        tls: %{
          verify: :verify_peer,
          cacertfile: "/certs/ca.pem",
          certfile: "/certs/cert.pem",
          keyfile: "/certs/key.pem"
        }
      )

  ## Module map

  The public API is split across domain modules. Every function is also
  available directly on this module (e.g. `Docker.create_container/4` and
  `Docker.Container.create_container/4` are the same call):

    * `Docker.Container` — Create, start, stop, delete, and inspect containers.
    * `Docker.Image` — Pull, build, list, and delete images.
    * `Docker.Network` — Create isolated networks and connect containers to them.
    * `Docker.Terminal` — Run commands and open interactive shells (recommended
      for most callers).
    * `Docker.Exec` — Lower-level command execution (prefer `Docker.Terminal`).
    * `Docker.Session` — Raw bidirectional streaming sessions (advanced use).
    * `Docker.Streaming.Session` — The I/O handle returned by `terminal_open/2`
      and `attach/2`.
    * `Docker.Daemon` — Connectivity checks and version info.
    * `Docker.Sandbox` — Canned responses for tests that run without a daemon.

  ## Testing without a daemon

  Pass `sandbox: [enabled: true]` to any function and it will use a canned
  response registered with `Docker.Sandbox` instead of calling a real daemon.
  This lets tests run fast and without Docker installed. See `Docker.Sandbox`
  for the full registration API and examples.

      # In test_helper.exs
      Docker.Sandbox.start_link()

      # In a test
      Docker.Sandbox.set_ping_responses([fn -> {:ok, "OK"} end])
      assert {:ok, "OK"} = Docker.ping(sandbox: [enabled: true])
  """

  @typedoc "A string identifying an image. Accepted forms: `\"alpine:3.19\"`, `\"sha256:abc…\"`, or a unique ID prefix."
  @type image_ref :: binary()

  @typedoc "The body returned by image operations — a binary, a map, or a list of maps depending on the call."
  @type image_output :: binary() | map() | [map()]

  @typedoc "An error reason returned by `{:error, reason}` tuples. The shape varies: an atom for simple errors, a map with `:status` and `:body` for HTTP errors, or a tuple or binary for lower-level failures."
  @type error_reason :: atom() | binary() | map() | list() | tuple()

  @typedoc "Return type for image operations that return both an image reference and output."
  @type image_result :: {:ok, {image_ref(), image_output()}} | {:error, error_reason()}

  @typedoc "Options keyword list accepted by every public function. Common keys: `:host`, `:socket`, `:tls`, `:version`, `:endpoint`, `:sandbox`. See the \"Connecting to a daemon\" section in `Docker`."
  @type options :: keyword()

  @typedoc "A plain map of query parameters forwarded to the Docker Engine HTTP API."
  @type params :: map()

  @typedoc "A map with string keys decoded from a Docker Engine JSON response."
  @type json_map :: map()

  @typedoc "A list of `t:json_map/0` values."
  @type json_list :: [json_map()]

  @typedoc "A 64-character hex string that uniquely identifies a container, image, or network on the daemon."
  @type docker_id :: binary()

  @typedoc "A string ID for an exec instance, returned by `exec_create/3`. Pass it to `exec_start/2` or `exec_inspect/2`."
  @type exec_id :: binary()

  @typedoc "A container name or ID. The name you passed to `create_container/4` is accepted anywhere a container ID is — it is easier to use and remember."
  @type container_ref :: binary()

  @typedoc "A network name or ID. The name you passed to `create_network/3` is accepted anywhere a network ID is."
  @type network_ref :: binary()

  @typedoc "The result of running a command: its combined stdout+stderr output, the exit code (0 = success), and whether the process was still running at inspect time."
  @type exec_result :: %{output: binary(), exit_code: integer() | nil, running: boolean() | nil}

  @typedoc "The standard return type: `{:ok, value}` on success or `{:error, reason}` on failure."
  @type result(t) :: {:ok, t} | {:error, error_reason()}

  @typedoc "A map of string label keys to string label values attached to a container or network at creation time. Example: `%{\"env\" => \"staging\", \"role\" => \"worker\"}`."
  @type labels :: %{binary() => binary()}

  # ---------------------------------------------------------------------------
  # Daemon
  # ---------------------------------------------------------------------------

  defdelegate endpoint(options \\ []), to: Docker.Daemon
  defdelegate ping(options \\ []), to: Docker.Daemon
  defdelegate version(options \\ []), to: Docker.Daemon

  # ---------------------------------------------------------------------------
  # Exec
  # ---------------------------------------------------------------------------

  defdelegate exec_create(container_ref, cmd, options \\ []), to: Docker.Exec
  defdelegate exec_start(exec_id, options \\ []), to: Docker.Exec
  defdelegate exec_inspect(exec_id, options \\ []), to: Docker.Exec
  defdelegate exec_run(container_ref, cmd, options \\ []), to: Docker.Exec
  defdelegate exec_run_with_status(container_ref, cmd, options \\ []), to: Docker.Exec

  # ---------------------------------------------------------------------------
  # Session
  # ---------------------------------------------------------------------------

  defdelegate attach(container_ref, options \\ []), to: Docker.Session
  defdelegate exec_session(container_ref, cmd, options \\ []), to: Docker.Session
  defdelegate send_message(container_ref, message, mode, options \\ []), to: Docker.Session

  # ---------------------------------------------------------------------------
  # Terminal (unified one-shot + persistent interface)
  # ---------------------------------------------------------------------------

  defdelegate terminal_run(container_ref, cmd, options \\ []),
    to: Docker.Terminal,
    as: :run

  defdelegate terminal_run_with_status(container_ref, cmd, options \\ []),
    to: Docker.Terminal,
    as: :run_with_status

  defdelegate terminal_open(container_ref, options \\ []),
    to: Docker.Terminal,
    as: :open

  defdelegate terminal_command(terminal, line, options \\ []),
    to: Docker.Terminal,
    as: :command

  defdelegate terminal_close(terminal),
    to: Docker.Terminal,
    as: :close

  # ---------------------------------------------------------------------------
  # Network
  # ---------------------------------------------------------------------------

  defdelegate list_networks(params \\ %{}, options \\ []), to: Docker.Network
  defdelegate find_network(network_id, options \\ []), to: Docker.Network
  defdelegate create_network(name, labels, options \\ []), to: Docker.Network

  defdelegate connect_network(network_id, container_ref, options \\ []),
    to: Docker.Network

  defdelegate delete_network(network_id, options \\ []), to: Docker.Network

  # ---------------------------------------------------------------------------
  # Image
  # ---------------------------------------------------------------------------

  defdelegate list_images(params \\ %{}, options \\ []), to: Docker.Image
  defdelegate find_image(image_ref, options \\ []), to: Docker.Image
  defdelegate pull_image(image, params \\ %{}, options \\ []), to: Docker.Image

  defdelegate build_image(context_path, dockerfile, tag, params \\ %{}, options \\ []),
    to: Docker.Image

  defdelegate run_build_image(context_path, dockerfile, tag, params \\ %{}, options \\ []),
    to: Docker.Image

  defdelegate materialize_image(image_ref, image_or_path, params, options), to: Docker.Image
  defdelegate delete_image(image_ref, params \\ %{}, options \\ []), to: Docker.Image

  # ---------------------------------------------------------------------------
  # Container
  # ---------------------------------------------------------------------------

  defdelegate list_containers(params \\ %{}, options \\ []), to: Docker.Container
  defdelegate find_container(container_ref, options \\ []), to: Docker.Container
  defdelegate create_container(name, image, labels, options \\ []), to: Docker.Container
  defdelegate start_container(container_ref, options \\ []), to: Docker.Container
  defdelegate stop_container(container_ref, options \\ []), to: Docker.Container

  defdelegate delete_container(container_ref, params \\ %{}, options \\ []),
    to: Docker.Container

  defdelegate container_logs(container_ref, params \\ %{}, options \\ []),
    to: Docker.Container

  defdelegate container_running?(container), to: Docker.Container
  defdelegate container_running?(container_ref, options), to: Docker.Container

  defdelegate put_archive(container_ref, dest_path, tar, options \\ []),
    to: Docker.Container

  @doc false
  defdelegate build_create_container_config(name, image, labels, options), to: Docker.Container
end
