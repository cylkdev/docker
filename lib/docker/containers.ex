defmodule Docker.Containers do
  @moduledoc """
  Container lifecycle management: create, start, stop, delete, inspect, and
  run commands.

  A container is a running (or stopped) process packaged with its own
  filesystem, created from an image. Think of an image as a recipe and a
  container as the dish — you can make many containers from the same image.

  Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.create_container/5`). See `Docker` for the full client
  overview.

  ## Container lifecycle

      # 1. Create a container from an image (it starts stopped)
      {:ok, id} = Docker.Containers.create_container("my-group", "my-worker", "alpine:3.19", %{})

      # 2. Start it
      {:ok, _} = Docker.Containers.start_container("my-worker")

      # 3. Check it is running
      {:ok, container} = Docker.Containers.find_container("my-worker")
      container["State"]["Running"]  # => true

      # 4. Run a command inside it
      {:ok, output} = Docker.exec_run("my-worker", "echo hello")

      # 5. Stop and clean up
      Docker.Containers.stop_container("my-worker")
      Docker.Containers.delete_container("my-worker")
  """

  alias Docker.Instance
  alias Docker.Client
  alias Docker.Frame
  alias Docker.Util

  @doc """
  Returns all stdout and stderr output a container has produced since it
  started.

  The output from both stdout and stderr is combined into a single binary.
  Docker's internal stream multiplexing is transparent — you do not need to
  demultiplex it yourself.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `params` — optional map of Docker Engine query parameters. Useful keys:
      - `"tail"` — string number of lines to return from the end, e.g.
        `"20"` for the last 20 lines. Default: all logs.
      - `"since"` — Unix timestamp (integer) to only return logs after.
      - `"until"` — Unix timestamp (integer) to only return logs before.
    - `options` — optional keyword list. Recognised keys:
      - `:stdout` — boolean, include stdout (default `true`).
      - `:stderr` — boolean, include stderr (default `true`).
      - `:timestamps` — boolean, prepend ISO timestamps to each line
        (default `false`).

  ## Returns

    - `{:ok, output}` — a binary with the combined log output, untrimmed.
    - `{:error, %{status: 404, body: _}}` — container not found.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      # All logs
      {:ok, logs} = Docker.Containers.container_logs("my-worker")
      IO.puts(logs)

      # Last 20 lines only
      {:ok, logs} = Docker.Containers.container_logs("my-worker", %{"tail" => "20"})

      # Stderr only, with timestamps
      {:ok, logs} =
        Docker.Containers.container_logs("my-worker", %{}, stdout: false, timestamps: true)
  """
  @spec container_logs(Docker.container_ref(), Docker.params(), Docker.options()) ::
          Docker.result(binary())
  def container_logs(container_ref, params \\ %{}, options \\ []) do
    if sandbox?(options) do
      sandbox_container_logs_response(container_ref, params, options)
    else
      do_container_logs(container_ref, params, options)
    end
  end

  defp do_container_logs(container_ref, params, options) do
    params =
      Map.merge(
        params,
        %{
          stdout: Keyword.get(options, :stdout, true),
          stderr: Keyword.get(options, :stderr, true),
          timestamps: Keyword.get(options, :timestamps, false)
        }
      )

    url = Util.append_query_string("/containers/#{container_ref}/logs", params)
    req_options = Keyword.put_new(options, :into, :raw)

    case Client.request(:get, url, nil, req_options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, Frame.demux_all(body)}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a list of containers known to the daemon.

  By default, only running containers are returned. Pass `all: true` to
  include stopped containers too.

  ## Parameters

    - `params` — optional map of Docker Engine query parameters: `:all`
      (boolean, include stopped containers), `:limit` (integer), `:size`
      (boolean).
      - `:filters` — optional keyword list: `:ancestor`, `:before`, `:exited`,
        `:expose`, `:health`, `:id`, `:isolation`, `:is_task`, `:label`,
        `:name`, `:network`, `:publish`, `:since`, `:status`, `:volume`.
        `:label` takes a `%{binary() => binary()}` map; every other filter
        takes a list of strings. Several filters may be combined and all must
        match (AND). Underscored keys are hyphenated on the wire (`:is_task`
        -> `is-task`).
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, [map]}` — list of container maps with string keys including
      `"Id"`, `"Names"`, `"Image"`, `"State"`, and `"Labels"`.
    - `{:error, reason}` — daemon not reachable or returned an error.

  ## Examples

      # All containers (running + stopped), no filters
      {:ok, containers} = Docker.Containers.list_containers(%{all: true})

      # Running containers tagged with label `tier=worker`
      # (see create_container/5 for how to attach labels at creation)
      {:ok, workers} =
        Docker.Containers.list_containers(%{filters: [label: %{"tier" => "worker"}]})

      # Multiple label constraints — container must match ALL of them (AND)
      {:ok, containers} =
        Docker.Containers.list_containers(%{
          all: true,
          filters: [label: %{"env" => "staging", "tier" => "worker"}]
        })

      # Combining a label filter with another filter
      {:ok, running} =
        Docker.Containers.list_containers(%{
          filters: [label: %{"tier" => "worker"}, status: ["running"]]
        })
  """
  @spec list_containers(Docker.params(), Docker.options()) :: Docker.result(Docker.json_list())
  def list_containers(params \\ %{}, options \\ []) do
    params =
      case params[:filters] do
        nil -> params
        filters -> Map.put(params, :filters, Util.encode_filters(filters))
      end

    if sandbox?(options) do
      sandbox_list_containers_response(params, options)
    else
      do_list_containers(params, options)
    end
  end

  defp do_list_containers(params, options) do
    url = Util.append_query_string("/containers/json", params)

    case Client.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a single container by name or ID.

  The `container_ref` is the `name` you passed to `create_container/5` — use
  that name here and everywhere else. You can also pass a full 64-character
  container ID or a unique prefix of it.

  ## Parameters

    - `container_ref` — the container name or ID (full or unique prefix).
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, map}` — container details map with string keys. Commonly used:
      - `"Id"` — full 64-character hex ID.
      - `"Name"` — container name (prefixed with `/`, e.g. `"/my-worker"`).
      - `"State"` — map with `"Running"` (boolean), `"ExitCode"`, etc.
      - `"Labels"` — map of label key-value pairs.
      - `"Image"` — image name the container was created from.
    - `{:error, %{status: 404, body: _}}` — no container matched.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      # Find by the name given at creation time
      {:ok, _} = Docker.Containers.create_container("my-group", "my-worker", "alpine:3.19", %{})
      {:ok, container} = Docker.Containers.find_container("my-worker")
      container["Id"]                 # full hex ID
      container["State"]["Running"]   # true or false

      # Find by container ID (or unique prefix)
      {:ok, container} = Docker.Containers.find_container("3f4a2c9b1e0d")
  """
  @spec find_container(Docker.container_ref(), Docker.options()) ::
          Docker.result(Docker.json_map())
  def find_container(container_ref, options \\ []) do
    if sandbox?(options) do
      sandbox_find_container_response(container_ref, options)
    else
      do_find_container(container_ref, options)
    end
  end

  defp do_find_container(container_ref, options) do
    url = "/containers/#{container_ref}/json"

    case Client.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Permanently removes a container by name or ID.

  The container must be stopped first. If it is still running, either stop
  it with `stop_container/2` first, or pass `%{force: true}` in `params` to
  remove it without stopping.

  ## Parameters

    - `container_ref` — the container name or ID to remove.
    - `params` — optional map. Key: `force` (boolean). When `true`, the
      running container is killed before removal (default `false`).
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, _}` — container removed.
    - `{:error, %{status: 404, body: _}}` — container not found.
    - `{:error, %{status: 409, body: _}}` — container is running and
      `force` was not set.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      # Normal removal (container must be stopped first)
      Docker.Containers.stop_container("my-worker")
      {:ok, _} = Docker.Containers.delete_container("my-worker")

      # Force-remove a running container
      {:ok, _} = Docker.Containers.delete_container("my-worker", %{force: true})
  """
  @spec delete_container(Docker.container_ref(), Docker.params(), Docker.options()) ::
          Docker.result(Docker.json_map() | binary() | list())
  def delete_container(container_ref, params \\ %{}, options \\ []) do
    if sandbox?(options) do
      sandbox_delete_container_response(container_ref, params, options)
    else
      do_delete_container(container_ref, params, options)
    end
  end

  defp do_delete_container(container_ref, params, options) do
    url = Util.append_query_string("/containers/#{container_ref}", params)

    case Client.request(:delete, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new container from an image.

  The container starts in a stopped state. Call `start_container/2` to start
  it. The `name` you give here is the handle you use everywhere else —
  `find_container/2`, `start_container/2`, `stop_container/2`, and
  `Docker.exec_run/3` all accept it.

  ## Parameters

    - `group` — a string naming the group this container belongs to. Written
      into the container's labels as `"elixir.docker.app"`, so every container
      in a group can be found later with
      `list_containers(label: %{"elixir.docker.app" => "my-group"})`.
    - `name` — a string name for the container. Must be unique on the
      daemon. Use it as `container_ref` in all other functions.
    - `image` — the image to create the container from. Examples:
      `"alpine:3.19"`, `"ubuntu:22.04"`, `"my-app:latest"`. The image
      must already be present locally (see `Docker.Image.pull_image/3`).
    - `labels` — a `%{binary() => binary()}` map of arbitrary key-value
      string pairs. Labels let you tag containers with metadata
      (environment, role, owner) and filter by them later with
      `list_containers/2`. Pass `%{}` for no labels.
    - `options` — optional keyword list. Recognised keys:

  ## Options

    * `:cmd` — list of strings overriding the image's default command.
      Example: `cmd: ["nginx", "-g", "daemon off;"]`.
    * `:env` — list of `"KEY=VALUE"` strings to set as environment
      variables. Example: `env: ["PORT=8080", "DEBUG=true"]`.
    * `:binds` — list of host-to-container bind mounts in Docker syntax.
      Example: `binds: ["/host/path:/container/path"]`.
    * `:mounts` — list of mount config maps (advanced, mirrors Docker API
      `Mounts` field).
    * `:networks` — list of network names to connect the container to at
      creation time. Example: `networks: ["backend", "frontend"]`.
    * `:network_mode` — string network mode, e.g. `"host"` or `"none"`.
    * `:exposed_ports` — list of `%{port: integer, protocol: "tcp"|"udp"}`
      maps declaring ports to expose.
    * `:port_bindings` — list of
      `%{protocol: "tcp"|"udp", container_port: integer, host_port: integer,
      host_ip: binary}` maps mapping host ports to container ports.
    * `:tty` — boolean, allocate a pseudo-terminal (default `false`).
    * `:open_stdin` — boolean, attach stdin and stdout/stderr
      (default `false`). For an interactive shell, combine the three:
      `cmd: ["/bin/sh"], tty: true, open_stdin: true`.
    * `:auto_remove` — boolean, delete the container automatically when it
      stops (default `false`).
    * `:platform` — string platform specifier, e.g. `"linux/amd64"`.

  ## Returns

    - `{:ok, container_id}` — the 64-character hex ID of the new container.
      Note: you can use the `name` string instead of this ID in all other
      functions.
    - `{:error, {warnings, container_id}}` — the container was created
      (with the returned ID) but the daemon reported warnings. Inspect
      `warnings` (a list of strings) to see what was wrong.
    - `{:error, reason}` — image not found, name already in use, or daemon
      returned an error.

  ## Examples

      # Minimal — no labels, no extra options
      {:ok, id} = Docker.Containers.create_container("my-group", "my-app", "alpine:3.19", %{})

      # With labels — tag it so you can filter it later
      {:ok, id} =
        Docker.Containers.create_container(
          "my-group",
          "my-worker",
          "alpine:3.19",
          %{"env" => "staging", "tier" => "worker"}
        )

      # With environment variables and a custom command
      {:ok, id} =
        Docker.Containers.create_container(
          "my-group",
          "my-server",
          "nginx:alpine",
          %{"app" => "web"},
          env: ["PORT=8080", "DEBUG=true"],
          cmd: ["nginx", "-g", "daemon off;"],
          exposed_ports: [%{port: 80, protocol: "tcp"}],
          port_bindings: [
            %{protocol: "tcp", container_port: 80, host_port: 80, host_ip: "0.0.0.0"}
          ]
        )

      # After creation, find the container by the name you gave it
      {:ok, container} = Docker.Containers.find_container("my-worker")
      container["State"]["Running"]  # => false (not started yet)

      # List all containers with a specific label
      {:ok, workers} =
        Docker.Containers.list_containers(%{filters: [label: %{"tier" => "worker"}]})
  """
  @spec create_container(binary(), binary(), binary(), Docker.labels(), Docker.options()) ::
          Docker.result(Docker.docker_id()) | {:error, {list(), Docker.docker_id()}}
  def create_container(group, name, image, labels, options \\ []) do
    if sandbox?(options) do
      sandbox_create_container_response(group, name, image, labels, options)
    else
      do_create_container(group, name, image, labels, options)
    end
  end

  defp do_create_container(group, name, image, labels, options) do
    platform = Keyword.get(options, :platform, "")

    url = "/containers/create?name=#{name}&platform=#{platform}"

    config = group |> Instance.new(name, image, labels, options) |> Instance.to_map()

    case Client.request(:post, url, {:json, config}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        interpret_create_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp interpret_create_response(%{"Id" => id, "Warnings" => []}), do: {:ok, id}

  defp interpret_create_response(%{"Id" => id, "Warnings" => warnings}),
    do: {:error, {warnings, id}}

  defp interpret_create_response(body), do: {:error, body}

  @doc """
  Starts a previously created container.

  The container must have been created with `create_container/5` first. If
  the container is already running, this returns an error.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, _}` — container is now starting.
    - `{:error, %{status: 304, body: _}}` — container is already running.
    - `{:error, %{status: 404, body: _}}` — container not found.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      {:ok, _} = Docker.Containers.start_container("my-worker")
  """
  @spec start_container(Docker.container_ref(), Docker.options()) ::
          Docker.result(binary() | Docker.json_map())
  def start_container(container_ref, options \\ []) do
    if sandbox?(options) do
      sandbox_start_container_response(container_ref, options)
    else
      do_start_container(container_ref, options)
    end
  end

  defp do_start_container(container_ref, options) do
    url = "/containers/#{container_ref}/start"

    case Client.request(:post, url, {:json, %{}}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a running container.

  Sends SIGTERM to the container's main process and waits for it to exit.
  If the process does not exit within the grace period, Docker sends SIGKILL.
  The container remains in a stopped state and can be started again with
  `start_container/2` or removed with `delete_container/3`.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, _}` — container is stopped.
    - `{:error, %{status: 304, body: _}}` — container is already stopped.
    - `{:error, %{status: 404, body: _}}` — container not found.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      {:ok, _} = Docker.Containers.stop_container("my-worker")
  """
  @spec stop_container(Docker.container_ref(), Docker.options()) ::
          Docker.result(binary() | Docker.json_map())
  def stop_container(container_ref, options \\ []) do
    if sandbox?(options) do
      sandbox_stop_container_response(container_ref, options)
    else
      do_stop_container(container_ref, options)
    end
  end

  defp do_stop_container(container_ref, options) do
    url = "/containers/#{container_ref}/stop"

    case Client.request(:post, url, {:json, %{}}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Uploads files into a container's filesystem by extracting a tar archive at
  a given path.

  Use this to inject config files, scripts, or build artifacts into a
  container without rebuilding the image. The container does not need to be
  running — this works on stopped containers too.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `dest_path` — the absolute path inside the container where the
      archive will be extracted. Example: `"/app"` or `"/etc/myapp"`.
    - `tar_path` — path to a pre-built tar archive on the local filesystem.
      Build one with `Docker.Archive.create_tar/3`.
    - `options` — optional keyword list for daemon selection. See `Docker`.
      Also accepts `:no_overwrite_dir_non_dir` and `:copy_uid_gid` (boolean)
      forwarded to the Docker Engine API.

  ## Returns

    - `{:ok, _}` — archive extracted successfully.
    - `{:error, %{status: 400, body: _}}` — bad request (e.g. path not
      absolute, malformed archive).
    - `{:error, %{status: 404, body: _}}` — container not found.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      :ok = Docker.Archive.create_tar("/tmp/assets.tar", "./assets")

      # Extracts to /tmp/assets/...
      {:ok, _} = Docker.Containers.put_archive("my-container", "/tmp", "/tmp/assets.tar")
  """
  @spec put_archive(
          Docker.container_ref(),
          binary(),
          binary(),
          Docker.options()
        ) :: Docker.result(map() | binary())
  def put_archive(container_ref, dest_path, tar_path, options \\ [])
      when is_binary(container_ref) and is_binary(dest_path) and is_binary(tar_path) do
    if sandbox?(options) do
      sandbox_put_archive_response(container_ref, dest_path, tar_path, options)
    else
      do_put_archive(container_ref, dest_path, tar_path, options)
    end
  end

  defp do_put_archive(container_ref, dest_path, tar_path, options) do
    query = %{path: dest_path}

    query =
      case Keyword.get(options, :no_overwrite_dir_non_dir) do
        nil -> query
        val -> Map.put(query, :noOverwriteDirNonDir, val)
      end

    query =
      case Keyword.get(options, :copy_uid_gid) do
        nil -> query
        val -> Map.put(query, :copyUIDGID, val)
      end

    url = Util.append_query_string("/containers/#{container_ref}/archive", query)

    with {:ok, tar} <- File.read(tar_path),
         {:ok, %{status: code, body: body}} when code in 200..299 <-
           Client.request(:put, url, {:tar, tar}, options) do
      {:ok, body}
    else
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `true` if the container map from `find_container/2` says the
  container is currently running.

  This is a pure data function — it does not make a network call. Pass it
  the map returned by `find_container/2`. For a version that queries the
  daemon directly, use `container_running?/2`.

  ## Parameters

    - `container` — the map returned by `find_container/2`. Must have the
      shape `%{"State" => %{"Running" => boolean}}`.

  ## Examples

      {:ok, container} = Docker.Containers.find_container("my-worker")
      Docker.Containers.container_running?(container)  # => true or false
  """
  @spec container_running?(map()) :: boolean()
  def container_running?(%{"State" => %{"Running" => running}}) when is_boolean(running) do
    running
  end

  @doc """
  Queries the daemon for the current state of a container and returns
  `true` if it is running.

  Returns `false` if the container is stopped or does not exist. Raises if
  the daemon cannot be reached — an unreachable daemon says nothing about
  whether the container is running, so it is not reported as `false`. For a
  version that takes an already-fetched container map, use
  `container_running?/1`.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Examples

      Docker.Containers.container_running?("my-worker")  # => true or false
  """
  @spec container_running?(Docker.container_ref(), Docker.options()) :: boolean()
  def container_running?(container_ref, options \\ []) when is_binary(container_ref) do
    if sandbox?(options) do
      sandbox_container_running_response(container_ref, options)
    else
      case find_container(container_ref, options) do
        {:ok, container} -> container_running?(container)
        {:error, %{status: 404}} -> false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SANDBOX HELPERS
  # ---------------------------------------------------------------------------

  defp sandbox?(options) do
    sandbox_options = options[:sandbox] || []
    enabled = Keyword.get(sandbox_options, :enabled, false)
    enabled and not sandbox_disabled?()
  end

  if Code.ensure_loaded?(SandboxRegistry) do
    @doc false
    defdelegate sandbox_disabled?, to: Docker.Sandbox

    @doc false
    defdelegate sandbox_list_containers_response(params, options),
      to: Docker.Sandbox,
      as: :list_containers_response

    @doc false
    defdelegate sandbox_find_container_response(container_ref, options),
      to: Docker.Sandbox,
      as: :find_container_response

    @doc false
    defdelegate sandbox_start_container_response(container_ref, options),
      to: Docker.Sandbox,
      as: :start_container_response

    @doc false
    defdelegate sandbox_stop_container_response(container_ref, options),
      to: Docker.Sandbox,
      as: :stop_container_response

    @doc false
    defdelegate sandbox_delete_container_response(container_ref, params, options),
      to: Docker.Sandbox,
      as: :delete_container_response

    @doc false
    defdelegate sandbox_container_logs_response(container_ref, params, options),
      to: Docker.Sandbox,
      as: :container_logs_response

    @doc false
    defdelegate sandbox_container_running_response(container_ref, options),
      to: Docker.Sandbox,
      as: :container_running_response

    @doc false
    defdelegate sandbox_create_container_response(group, name, image, labels, options),
      to: Docker.Sandbox,
      as: :create_container_response

    @doc false
    defdelegate sandbox_put_archive_response(container_ref, dest_path, params, options),
      to: Docker.Sandbox,
      as: :put_archive_response
  else
    defp sandbox_disabled?, do: true

    defp sandbox_list_containers_response(params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_find_container_response(container_ref, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_start_container_response(container_ref, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_stop_container_response(container_ref, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_delete_container_response(container_ref, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_container_logs_response(container_ref, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_container_running_response(container_ref, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_create_container_response(group, name, image, labels, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      group: #{inspect(group)}
      name: #{inspect(name)}
      image: #{inspect(image)}
      labels: #{inspect(labels)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_put_archive_response(container_ref, dest_path, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      dest_path: #{inspect(dest_path)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end
  end
end
