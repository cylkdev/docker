defmodule Docker.Container do
  @moduledoc """
  Container lifecycle management: create, start, stop, delete, inspect, and
  run commands.

  A container is a running (or stopped) process packaged with its own
  filesystem, created from an image. Think of an image as a recipe and a
  container as the dish — you can make many containers from the same image.

  Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.create_container/4`). See `Docker` for the full client
  overview.

  ## Container lifecycle

      # 1. Create a container from an image (it starts stopped)
      {:ok, id} = Docker.Container.create_container("my-worker", "alpine:3.19", %{})

      # 2. Start it
      {:ok, _} = Docker.Container.start_container("my-worker")

      # 3. Check it is running
      {:ok, container} = Docker.Container.find_container("my-worker")
      container["State"]["Running"]  # => true

      # 4. Run a command inside it
      {:ok, output} = Docker.terminal_run("my-worker", "echo hello")

      # 5. Stop and clean up
      Docker.Container.stop_container("my-worker")
      Docker.Container.delete_container("my-worker")
  """

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
      {:ok, logs} = Docker.Container.container_logs("my-worker")
      IO.puts(logs)

      # Last 20 lines only
      {:ok, logs} = Docker.Container.container_logs("my-worker", %{"tail" => "20"})

      # Stderr only, with timestamps
      {:ok, logs} =
        Docker.Container.container_logs("my-worker", %{}, stdout: false, timestamps: true)
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

  By default, only running containers are returned. Pass `%{all: true}` in
  `params` to include stopped containers too.

  ## Parameters

    - `params` — optional map of Docker Engine query parameters. Common keys:
      - `all` — boolean. Include stopped containers (default `false`).
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Options

    * `:labels` — a list of label strings in `"key"` or `"key=value"` form.
      Encoded into the Docker Engine's `filters` query parameter as
      `{"label": [...]}`. When set, this **overrides** any `:filters` (or
      `"filters"`) key already present in `params`. Labels were attached
      at creation time via `create_container/4`.

  ## Returns

    - `{:ok, [map]}` — list of container maps with string keys including
      `"Id"`, `"Names"`, `"Image"`, `"State"`, and `"Labels"`.
    - `{:error, reason}` — daemon not reachable or returned an error.

  ## Examples

      # All containers (running + stopped), no filters
      {:ok, containers} = Docker.Container.list_containers(%{all: true})

      # Running containers tagged with label `tier=worker`
      # (see create_container/4 for how to attach labels at creation)
      {:ok, workers} =
        Docker.Container.list_containers(%{}, labels: ["tier=worker"])

      # Multiple label constraints — container must match ALL of them (AND)
      {:ok, containers} =
        Docker.Container.list_containers(%{all: true},
          labels: ["env=staging", "tier=worker"])

      # Match a label key regardless of its value
      {:ok, containers} = Docker.Container.list_containers(%{}, labels: ["env"])
  """
  @spec list_containers(Docker.params(), Docker.options()) :: Docker.result(Docker.json_list())
  def list_containers(params \\ %{}, options \\ []) do
    params = apply_label_filter(params, options)

    if sandbox?(options) do
      sandbox_list_containers_response(params, options)
    else
      do_list_containers(params, options)
    end
  end

  defp apply_label_filter(params, options) do
    case Keyword.get(options, :labels) do
      nil ->
        params

      labels when is_list(labels) ->
        unless Enum.all?(labels, &is_binary/1) do
          raise "Expected labels to be a list of strings, got: #{inspect(labels)}"
        end

        params
        |> Map.delete("filters")
        |> Map.put(:filters, JSON.encode!(%{"label" => labels}))

      other ->
        raise "Expected labels to be a list of strings, got: #{inspect(other)}"
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

  The `container_ref` is the `name` you passed to `create_container/4` — use
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
      {:ok, _} = Docker.Container.create_container("my-worker", "alpine:3.19", %{})
      {:ok, container} = Docker.Container.find_container("my-worker")
      container["Id"]                 # full hex ID
      container["State"]["Running"]   # true or false

      # Find by container ID (or unique prefix)
      {:ok, container} = Docker.Container.find_container("3f4a2c9b1e0d")
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
      Docker.Container.stop_container("my-worker")
      {:ok, _} = Docker.Container.delete_container("my-worker")

      # Force-remove a running container
      {:ok, _} = Docker.Container.delete_container("my-worker", %{force: true})
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
  `Docker.terminal_run/3` all accept it.

  ## Parameters

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
    * `:networks` — list of network names (strings) or a map of
      `name => config` to connect the container to at creation time.
    * `:network_mode` — string network mode, e.g. `"host"` or `"none"`.
    * `:exposed_ports` — list of `%{port: integer, protocol: "tcp"|"udp"}`
      maps declaring ports to expose.
    * `:port_bindings` — list of port binding maps for host-to-container
      port mapping.
    * `:expose_http_port` — boolean shortcut: exposes port 80/tcp and
      binds it to host port 80 (default `false`).
    * `:interactive_shell` — boolean or shell path. When `true`, sets the
      default command to `["/bin/sh"]` with TTY and stdin attached. Pass
      a string or list to use a different shell.
    * `:open_stdin` — boolean, attach stdin even without `:interactive_shell`
      (default `false`).
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
      {:ok, id} = Docker.Container.create_container("my-app", "alpine:3.19", %{})

      # With labels — tag it so you can filter it later
      {:ok, id} =
        Docker.Container.create_container(
          "my-worker",
          "alpine:3.19",
          %{"env" => "staging", "tier" => "worker"}
        )

      # With environment variables and a custom command
      {:ok, id} =
        Docker.Container.create_container(
          "my-server",
          "nginx:alpine",
          %{"app" => "web"},
          env: ["PORT=8080", "DEBUG=true"],
          cmd: ["nginx", "-g", "daemon off;"],
          expose_http_port: true
        )

      # After creation, find the container by the name you gave it
      {:ok, container} = Docker.Container.find_container("my-worker")
      container["State"]["Running"]  # => false (not started yet)

      # List all containers with a specific label
      {:ok, workers} =
        Docker.Container.list_containers(%{}, labels: ["tier=worker"])
  """
  @spec create_container(binary(), binary(), Docker.labels(), Docker.options()) ::
          Docker.result(Docker.docker_id()) | {:error, {list(), Docker.docker_id()}}
  def create_container(name, image, labels, options \\ [])
      when is_binary(name) and is_binary(image) do
    if sandbox?(options) do
      sandbox_create_container_response(name, image, labels, options)
    else
      do_create_container(name, image, labels, options)
    end
  end

  defp do_create_container(name, image, labels, options) do
    platform = Keyword.get(options, :platform, "")
    options = maybe_expose_http_port(options)

    url = "/containers/create?name=#{name}&platform=#{platform}"

    config = build_create_container_config(name, image, labels, options)

    case Client.request(:post, url, {:json, config}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        interpret_create_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def build_create_container_config(name, image, labels, options) do
    auto_remove? = Keyword.get(options, :auto_remove, false)

    base = %{
      "Image" => image,
      "Name" => name,
      "ExposedPorts" => build_exposed_ports_spec(options),
      "HostConfig" => %{
        "AutoRemove" => auto_remove?,
        "PortBindings" => build_port_bindings_spec(options)
      },
      "Labels" => labels
    }

    base
    |> maybe_put_container_networking(options)
    |> maybe_put_container_mounts(options)
    |> maybe_put_container_env(options)
    |> maybe_put_container_command(options)
    |> maybe_put_interactive_shell(options)
    |> maybe_put_open_stdin(options)
  end

  defp interpret_create_response(%{"Id" => id, "Warnings" => []}), do: {:ok, id}

  defp interpret_create_response(%{"Id" => id, "Warnings" => warnings}),
    do: {:error, {warnings, id}}

  defp interpret_create_response(body), do: {:error, body}

  @doc """
  Starts a previously created container.

  The container must have been created with `create_container/4` first. If
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

      {:ok, _} = Docker.Container.start_container("my-worker")
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

      {:ok, _} = Docker.Container.stop_container("my-worker")
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

  To create a tar binary in Elixir, use `:erl_tar.create/3` with
  `[:binary, :memory]`.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `dest_path` — the absolute path inside the container where the
      archive will be extracted. Example: `"/app"` or `"/etc/myapp"`.
    - `tar` — a binary containing a valid tar archive.
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

      # Create a tar containing a single file and upload it
      {:ok, tar} =
        :erl_tar.create("archive", [{"hello.txt", "Hello from Elixir!"}],
          [:binary, :memory])

      {:ok, _} = Docker.Container.put_archive("my-container", "/tmp", tar)
  """
  @spec put_archive(Docker.container_ref(), binary(), binary(), Docker.options()) ::
          Docker.result(map() | binary())
  def put_archive(container_ref, dest_path, tar, options \\ [])
      when is_binary(container_ref) and is_binary(dest_path) and is_binary(tar) do
    if sandbox?(options) do
      sandbox_put_archive_response(container_ref, dest_path, tar, options)
    else
      do_put_archive(container_ref, dest_path, tar, options)
    end
  end

  defp do_put_archive(container_ref, dest_path, tar, options) do
    query =
      %{path: dest_path}
      |> Util.maybe_put(:noOverwriteDirNonDir, Keyword.get(options, :no_overwrite_dir_non_dir))
      |> Util.maybe_put(:copyUIDGID, Keyword.get(options, :copy_uid_gid))

    url = Util.append_query_string("/containers/#{container_ref}/archive", query)

    case Client.request(:put, url, {:tar, tar}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
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

      {:ok, container} = Docker.Container.find_container("my-worker")
      Docker.Container.container_running?(container)  # => true or false
  """
  @spec container_running?(map()) :: boolean()
  def container_running?(%{"State" => %{"Running" => running}}) when is_boolean(running) do
    running
  end

  @doc """
  Queries the daemon for the current state of a container and returns
  `true` if it is running.

  Returns `false` if the container is stopped, does not exist, or cannot be
  reached. For a version that takes an already-fetched container map, use
  `container_running?/1`.

  ## Parameters

    - `container_ref` — the container name or ID.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Examples

      Docker.Container.container_running?("my-worker")  # => true or false
  """
  @spec container_running?(Docker.container_ref(), Docker.options()) :: boolean()
  def container_running?(container_ref, options \\ []) when is_binary(container_ref) do
    if sandbox?(options) do
      sandbox_container_running_response(container_ref, options)
    else
      case find_container(container_ref, options) do
        {:ok, container} -> container_running?(container)
        _other -> false
      end
    end
  end

  defp maybe_put_container_command(base_params, options) do
    case Keyword.get(options, :cmd) do
      nil -> base_params
      cmd when is_list(cmd) -> Map.put(base_params, "Cmd", cmd)
      other -> raise "Expected cmd to be a list, got: #{inspect(other)}"
    end
  end

  defp maybe_put_container_env(base_params, options) do
    case Keyword.get(options, :env) do
      nil ->
        base_params

      env when is_list(env) ->
        Map.put(base_params, "Env", env)

      other ->
        raise "Expected env to be a list, got: #{inspect(other)}"
    end
  end

  defp maybe_put_container_mounts(base_params, options) do
    base_params
    |> maybe_put_host_binds(options)
    |> maybe_put_mounts(options)
  end

  defp maybe_put_host_binds(base_params, options) do
    case Keyword.get(options, :binds) do
      nil ->
        base_params

      binds when is_list(binds) ->
        host_config = Map.get(base_params, "HostConfig", %{})
        Map.put(base_params, "HostConfig", Map.put(host_config, "Binds", binds))

      other ->
        raise "Expected binds to be a list, got: #{inspect(other)}"
    end
  end

  defp maybe_put_mounts(base_params, options) do
    case Keyword.get(options, :mounts) do
      nil ->
        base_params

      mounts when is_list(mounts) ->
        host_config = Map.get(base_params, "HostConfig", %{})
        Map.put(base_params, "HostConfig", Map.put(host_config, "Mounts", mounts))

      other ->
        raise "Expected mounts to be a list, got: #{inspect(other)}"
    end
  end

  defp maybe_put_container_networking(base_params, options) do
    base_params
    |> maybe_put_network_mode(options)
    |> maybe_put_networks(options)
  end

  defp maybe_put_network_mode(base_params, options) do
    case Keyword.get(options, :network_mode) do
      nil ->
        base_params

      mode when is_binary(mode) ->
        host_config = Map.get(base_params, "HostConfig", %{})
        Map.put(base_params, "HostConfig", Map.put(host_config, "NetworkMode", mode))

      other ->
        raise "Expected network_mode to be a string, got: #{inspect(other)}"
    end
  end

  defp maybe_put_networks(base_params, options) do
    case Keyword.get(options, :networks) do
      nil ->
        base_params

      networks when is_list(networks) ->
        endpoints = build_network_endpoints_from_list(networks)
        Map.put(base_params, "NetworkingConfig", %{"EndpointsConfig" => endpoints})

      networks when is_map(networks) ->
        endpoints = build_network_endpoints_from_map(networks)
        Map.put(base_params, "NetworkingConfig", %{"EndpointsConfig" => endpoints})

      other ->
        raise "Expected networks to be a list or map, got: #{inspect(other)}"
    end
  end

  defp build_network_endpoints_from_list(networks) do
    networks
    |> Enum.map(fn
      name when is_binary(name) -> {name, %{}}
      other -> raise "Expected networks entries to be strings, got: #{inspect(other)}"
    end)
    |> Map.new()
  end

  defp build_network_endpoints_from_map(networks) do
    networks
    |> Enum.map(fn
      {name, config} when is_binary(name) and is_map(config) ->
        {name, config}

      other ->
        raise "Expected networks to be a map of name => config, got: #{inspect(other)}"
    end)
    |> Map.new()
  end

  defp maybe_put_open_stdin(base_params, options) do
    if Keyword.get(options, :open_stdin, false) do
      base_params
      |> Map.put("OpenStdin", true)
      |> Map.put("AttachStdin", true)
      |> Map.put("AttachStdout", true)
      |> Map.put("AttachStderr", true)
    else
      base_params
    end
  end

  defp maybe_put_interactive_shell(base_params, options) do
    if Keyword.has_key?(options, :cmd) do
      base_params
    else
      apply_interactive_shell(base_params, Keyword.get(options, :interactive_shell, false))
    end
  end

  defp apply_interactive_shell(base_params, false), do: base_params

  defp apply_interactive_shell(base_params, true),
    do: put_interactive_shell_cmd(base_params, ["/bin/sh"])

  defp apply_interactive_shell(base_params, shell) when is_binary(shell) and byte_size(shell) > 0,
    do: put_interactive_shell_cmd(base_params, [shell])

  defp apply_interactive_shell(base_params, [head | _rest] = cmd) when is_binary(head) do
    if Enum.all?(cmd, &is_binary/1) do
      put_interactive_shell_cmd(base_params, cmd)
    else
      raise "Expected interactive_shell to be a boolean, string, or non-empty list of strings, got: #{inspect(cmd)}"
    end
  end

  defp apply_interactive_shell(_base_params, other) do
    raise "Expected interactive_shell to be a boolean, string, or non-empty list of strings, got: #{inspect(other)}"
  end

  defp put_interactive_shell_cmd(base_params, cmd) do
    base_params
    |> Map.put("Cmd", cmd)
    |> Map.put("Tty", true)
    |> Map.put("OpenStdin", true)
    |> Map.put("AttachStdin", true)
    |> Map.put("AttachStdout", true)
    |> Map.put("AttachStderr", true)
  end

  defp maybe_expose_http_port(options) do
    if Keyword.get(options, :expose_http_port, false) do
      options
      |> ensure_exposed_port_config(80, "tcp")
      |> ensure_port_binding_config(%{
        protocol: "tcp",
        container: %{port: 80},
        host: %{port: 80, ip: "0.0.0.0"}
      })
    else
      options
    end
  end

  defp ensure_exposed_port_config(options, port, protocol) do
    existing = Keyword.get(options, :exposed_ports, [])

    if Enum.any?(existing, &(&1.port === port and &1.protocol === protocol)) do
      options
    else
      Keyword.put(options, :exposed_ports, existing ++ [%{port: port, protocol: protocol}])
    end
  end

  defp ensure_port_binding_config(options, binding) do
    existing = Keyword.get(options, :port_bindings, [])

    if Enum.any?(existing, &port_binding_matches?(&1, binding)) do
      options
    else
      Keyword.put(options, :port_bindings, existing ++ [binding])
    end
  end

  defp port_binding_matches?(config, binding) do
    config.protocol === binding.protocol and
      config.container.port === binding.container.port and
      config.host.port === binding.host.port and
      config.host.ip === binding.host.ip
  end

  defp build_exposed_ports_spec(options) do
    options
    |> Keyword.get(:exposed_ports, [])
    |> Map.new(fn config ->
      protocol = config.protocol
      port = config.port

      unless protocol in ["tcp", "udp"] do
        raise "Expected protocol to be tcp or udp, got: #{inspect(protocol)}"
      end

      key = "#{Integer.to_string(port)}/#{protocol}"

      {key, %{}}
    end)
  end

  defp build_port_bindings_spec(options) do
    options
    |> Keyword.get(:port_bindings, [])
    |> Enum.group_by(fn config -> {config.container.port, config.protocol} end)
    |> Map.new(fn {{container_port, protocol}, configs} ->
      unless protocol in ["tcp", "udp"] do
        raise "Expected protocol to be tcp or udp, got: #{inspect(protocol)}"
      end

      key = "#{Integer.to_string(container_port)}/#{protocol}"

      values =
        Enum.map(configs, fn config ->
          %{"HostPort" => Integer.to_string(config.host.port), "HostIp" => config.host.ip}
        end)

      {key, values}
    end)
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
    defdelegate sandbox_create_container_response(name, image, labels, options),
      to: Docker.Sandbox,
      as: :create_container_response

    @doc false
    defdelegate sandbox_put_archive_response(container_ref, dest_path, tar, options),
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

    defp sandbox_create_container_response(name, image, labels, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      name: #{inspect(name)}
      image: #{inspect(image)}
      labels: #{inspect(labels)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_put_archive_response(container_ref, dest_path, tar, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      dest_path: #{inspect(dest_path)}
      tar: #{inspect(tar)}
      options: #{inspect(options)}
      """
    end
  end
end
