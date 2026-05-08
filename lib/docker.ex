defmodule Docker do
  @moduledoc """
  Elixir client for the Docker Engine HTTP API.

  Reaches a Docker daemon over Unix domain sockets or TCP (with optional mTLS),
  honoring the same `DOCKER_HOST`, `DOCKER_TLS_VERIFY`, and `DOCKER_CERT_PATH`
  environment variables as the Docker CLI.

  ## Endpoint resolution

  Every public function accepts these options for selecting a daemon:

    * `:endpoint` — A `Sorrel.Endpoint` value.
    * `:host` — A URL string (`unix:///…`, `tcp://…`, `https://…`).
    * `:socket` — A unix socket filesystem path (legacy, unix-only).
    * `:tls` — TLS material for `tcp://` endpoints.
    * `:version` — Engine API version override.

  When none of those is given, resolution falls through to `DOCKER_HOST`
  and the standard filesystem socket paths — see
  `Sorrel.Endpoint.from_options/1` for the full precedence order.

  ## Sandbox mode

  Pass `sandbox: [enabled: true]` to any `Docker.*` function to dispatch to a
  canned response registered with `Docker.Engine.Sandbox`. Tests use this to run
  without a real daemon. See `Docker.Engine.Sandbox` for the full registration
  API. The sandbox module only exists when `sandbox_registry` is loaded as a
  dependency (typically only in `:test`); in production every `sandbox_*`
  helper raises if invoked.

  ## Streaming

  `pull_image/3` and `build_image/5` return `{:ok, Enumerable.t()}` of decoded
  NDJSON event maps. Consumers use `Stream.*` and `Enum.*` to filter, transform,
  and short-circuit. Discarding the stream early cancels the in-flight HTTP
  request — no orphan connections.

  `attach/2`, `exec_session/3`, and `send_message/4` return a
  `Docker.Engine.Streaming.Session` for full-duplex byte-stream interaction. The session
  is pull-based: call `Docker.Engine.Streaming.Session.send/2` and
  `Docker.Engine.Streaming.Session.recv/3` directly.

  ## Examples

      iex> Docker.ping()
      {:ok, "OK"}

      iex> Docker.ping(host: "tcp://10.0.0.1:2375")
      {:ok, "OK"}

      iex> {:ok, events} = Docker.pull_image("alpine")
      iex> events
      iex> |> Stream.filter(fn
      iex>      %{"status" => "Downloading"} -> true
      iex>      _ -> false
      iex>    end)
      iex> |> Enum.take(3)
      [...]
  """

  alias Docker.Engine.Client, as: EngineClient
  alias Docker.Engine.Frame
  alias Docker.Engine.Streaming
  alias Docker.Engine.Streaming.Session
  alias ExUtils.Serializer

  @type image_ref :: binary()
  @type image_output :: binary() | map() | [map()]
  @type error_reason :: atom() | binary() | map() | list() | tuple()
  @type image_result :: {:ok, {image_ref(), image_output()}} | {:error, error_reason()}
  @type options :: keyword()
  @type params :: map()
  @type json_map :: map()
  @type json_list :: [json_map()]
  @type docker_id :: binary()
  @type exec_id :: binary()
  @type container_ref :: binary()
  @type network_ref :: binary()
  @type exec_result :: %{output: binary(), exit_code: integer() | nil, running: boolean() | nil}
  @type result(t) :: {:ok, t} | {:error, error_reason()}

  @build_image_query_keys [
    :dockerfile,
    :t,
    :extrahosts,
    :remote,
    :q,
    :nocache,
    :cachefrom,
    :pull,
    :rm,
    :forcerm,
    :memory,
    :memswap,
    :cpushares,
    :cpusetcpus,
    :cpuperiod,
    :cpuquota,
    :buildargs,
    :shmsize,
    :squash,
    :labels,
    :networkmode,
    :platform,
    :target,
    :outputs,
    :version
  ]

  @pull_image_query_keys [
    :fromImage,
    :fromSrc,
    :repo,
    :tag,
    :message,
    :changes,
    :platform
  ]

  @doc """
  Returns the Docker daemon this client will reach for the given options.

  This is a convenience wrapper around `Sorrel.Endpoint.from_options/1`.
  Building an endpoint does not open any connection — it is pure data.

  ## Parameters

    * `options` — A keyword list. Recognised keys:
      - `:endpoint` — A `Sorrel.Endpoint` value, used as-is.
      - `:host` — A URL string like `"unix:///path"`, `"tcp://h:p"`, or `"https://h:p"`.
      - `:socket` — A unix socket file path. Shortcut for the legacy "I just want a socket" case.
      - `:tls` — A TLS map `%{verify: ..., cacertfile: ..., certfile: ..., keyfile: ...}` for tcp endpoints.
      - `:version` — The Docker Engine API version string. Defaults to the version on the resolved `Docker.Engine.Endpoint` (currently `"1.45"`).

    When no option resolves, falls through to `DOCKER_HOST` env var and the
    standard filesystem socket paths
    (`~/.docker/run/docker.sock`, `/var/run/docker.sock`).

  ## Returns

    * `{:ok, endpoint}` — A resolved `Sorrel.Endpoint` value.
    * `{:error, :endpoint_not_resolved}` — No rung in the precedence list yielded an endpoint.
    * `{:error, {:invalid_url, :missing_ssh_target}}` — An `ssh://` URL was supplied without a `:target` option. SSH endpoints need a target (`{:exec, cmd}`, `{:tcp, host, port}`, or `{:unix, path}`); see `Sorrel.Endpoint.parse/2`.
    * `{:error, {:invalid_url, reason}}` — A URL was malformed (other shapes documented in `Sorrel.Endpoint.parse/2`).

  ## Examples

      iex> Docker.endpoint()
      {:ok, %Sorrel.Endpoint{transport: :unix, socket_path: ...}}

      iex> Docker.endpoint(host: "tcp://10.0.0.1:2375")
      {:ok, %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "10.0.0.1", port: 2375, ...}}
  """
  @spec endpoint(keyword()) :: {:ok, Sorrel.Endpoint.t()} | {:error, term()}
  def endpoint(options \\ []) do
    if inline_sandbox?(options) do
      sandbox_endpoint_response(options)
    else
      case Docker.Engine.Endpoint.from_options(options) do
        {:ok, engine_endpoint} ->
          {:ok, Docker.Engine.Endpoint.to_minty(engine_endpoint)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Asks the Docker daemon if it is alive and responsive.

  Hits `GET /_ping`, the cheapest call the daemon answers.
  """
  @spec ping(options()) :: result(binary())
  def ping(options \\ []) do
    if inline_sandbox?(options) do
      sandbox_ping_response(options)
    else
      do_ping(options)
    end
  end

  defp do_ping(options) do
    case EngineClient.request(:get, "/_ping", nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates an exec instance in a running container.
  """
  @spec exec_create(container_ref(), [binary()], options()) :: result(exec_id())
  def exec_create(container_ref, cmd, options \\ []) when is_list(cmd) do
    if inline_sandbox?(options) do
      sandbox_exec_create_response(container_ref, cmd, options)
    else
      do_exec_create(container_ref, cmd, options)
    end
  end

  defp do_exec_create(container_ref, cmd, options) do
    url = "/containers/#{container_ref}/exec"

    payload =
      %{
        "AttachStdout" => true,
        "AttachStderr" => true,
        "AttachStdin" => Keyword.get(options, :attach_stdin, false),
        "Tty" => Keyword.get(options, :tty, false),
        "Cmd" => cmd
      }
      |> put_exec_option_if_present("Env", Keyword.get(options, :env))
      |> put_exec_option_if_present("User", Keyword.get(options, :user))
      |> put_exec_option_if_present("WorkingDir", Keyword.get(options, :workdir))

    case EngineClient.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: %{"Id" => exec_id}}} when code in 200..299 ->
        {:ok, exec_id}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts an exec instance and returns its combined stdout+stderr output.
  """
  @spec exec_start(exec_id(), options()) :: result(binary())
  def exec_start(exec_id, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_exec_start_response(exec_id, options)
    else
      do_exec_start(exec_id, options)
    end
  end

  defp do_exec_start(exec_id, options) do
    options = Keyword.put_new(options, :receive_timeout, :infinity)
    options = Keyword.put_new(options, :into, :frame)
    url = "/exec/#{exec_id}/start"

    payload = %{
      "Detach" => Keyword.get(options, :detach, false),
      "Tty" => false
    }

    case EngineClient.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, body}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns details for an exec instance.
  """
  @spec exec_inspect(exec_id(), options()) :: result(json_map())
  def exec_inspect(exec_id, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_exec_inspect_response(exec_id, options)
    else
      do_exec_inspect(exec_id, options)
    end
  end

  defp do_exec_inspect(exec_id, options) do
    url = "/exec/#{exec_id}/json"

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, Serializer.deserialize(body)}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates and starts an exec instance and returns combined output.
  """
  @spec exec_run(container_ref(), [binary()], options()) :: result(binary())
  def exec_run(container_ref, cmd, options \\ []) when is_list(cmd) do
    if inline_sandbox?(options) do
      sandbox_exec_run_response(container_ref, cmd, options)
    else
      do_exec_run(container_ref, cmd, options)
    end
  end

  defp do_exec_run(container_ref, cmd, options) do
    with {:ok, exec_id} <- exec_create(container_ref, cmd, options) do
      exec_start(exec_id, options)
    end
  end

  @doc """
  Creates and starts an exec instance and returns output plus exit status.
  """
  @spec exec_run_with_status(container_ref(), [binary()], options()) :: result(exec_result())
  def exec_run_with_status(container_ref, cmd, options \\ []) when is_list(cmd) do
    if inline_sandbox?(options) do
      sandbox_exec_run_with_status_response(container_ref, cmd, options)
    else
      do_exec_run_with_status(container_ref, cmd, options)
    end
  end

  defp do_exec_run_with_status(container_ref, cmd, options) do
    with {:ok, exec_id} <- exec_create(container_ref, cmd, options),
         {:ok, output} <- exec_start(exec_id, options),
         {:ok, inspect} <- exec_inspect(exec_id, options) do
      {:ok,
       %{
         output: output,
         exit_code: Map.get(inspect, :exit_code),
         running: Map.get(inspect, :running)
       }}
    end
  end

  @doc """
  Opens a bidirectional session attached to a running container's stdio.
  """
  @spec attach(container_ref(), options()) :: result(Session.t())
  def attach(container_ref, options \\ []) when is_binary(container_ref) do
    with {:ok, tty} <- resolve_attach_tty(container_ref, options) do
      Streaming.open_attach(container_ref, tty, options)
    end
  end

  @doc """
  Creates an exec instance with stdin attached and starts it as an upgraded
  session.
  """
  @spec exec_session(container_ref(), [binary()], options()) :: result(Session.t())
  def exec_session(container_ref, cmd, options \\ []) when is_list(cmd) do
    tty = Keyword.get(options, :tty, false)
    create_options = options |> Keyword.put(:attach_stdin, true) |> Keyword.put(:tty, tty)

    with {:ok, exec_id} <- exec_create(container_ref, cmd, create_options) do
      Streaming.open_exec_start(exec_id, tty, options)
    end
  end

  @doc """
  One-shot helper: attach to the container, write `message`, read until the
  termination condition fires, close the session.
  """
  @spec send_message(
          container_ref(),
          iodata(),
          Session.recv_mode(),
          options()
        ) :: {:ok, binary()} | {:ok, {binary(), binary()}} | {:error, error_reason()}
  def send_message(container_ref, message, mode, options \\ []) do
    with {:ok, session} <- attach(container_ref, options) do
      run_send_message(session, message, mode, options)
    end
  end

  defp run_send_message(session, message, mode, options) do
    with :ok <- Session.send(session, message),
         {:ok, output, _session} <- Session.recv(session, mode, options) do
      {:ok, output}
    else
      {:error, reason, _session} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  after
    :ok = Session.close(session)
  end

  defp resolve_attach_tty(container_ref, options) do
    case Keyword.fetch(options, :tty) do
      {:ok, tty} when is_boolean(tty) ->
        {:ok, tty}

      :error ->
        case find_container(container_ref, options) do
          {:ok, %{"Config" => %{"Tty" => tty}}} when is_boolean(tty) -> {:ok, tty}
          {:ok, _info} -> {:ok, false}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns the Docker Engine version metadata.
  """
  @spec version(options()) :: result(json_map())
  def version(options \\ []) do
    if inline_sandbox?(options) do
      sandbox_version_response(options)
    else
      do_version(options)
    end
  end

  defp do_version(options) do
    case EngineClient.request(:get, "/version", nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a network by name or ID.
  """
  @spec find_network(network_ref(), options()) :: result(json_map())
  def find_network(network_id, options \\ []) when is_binary(network_id) do
    if inline_sandbox?(options) do
      sandbox_find_network_response(network_id, options)
    else
      do_find_network(network_id, options)
    end
  end

  defp do_find_network(network_id, options) do
    url = "/networks/#{network_id}"

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a Docker network.
  """
  @spec create_network(binary(), options()) :: result(binary())
  def create_network(name, options \\ []) when is_binary(name) do
    if inline_sandbox?(options) do
      sandbox_create_network_response(name, options)
    else
      do_create_network(name, options)
    end
  end

  defp do_create_network(name, options) do
    url = "/networks/create"

    payload = %{
      "Name" => name,
      "Driver" => Keyword.get(options, :driver, "bridge"),
      "Internal" => Keyword.get(options, :internal, false),
      "Attachable" => Keyword.get(options, :attachable, false)
    }

    payload = put_network_ipam(payload, options)
    payload = put_network_labels(payload, options)

    case EngineClient.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: %{"Id" => id}}} when code in 200..299 ->
        {:ok, id}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_network_ipam(payload, options) do
    case Keyword.get(options, :ipam_subnet, "172.28.0.0/20") do
      nil ->
        payload

      subnet when is_binary(subnet) ->
        ipam_config = build_ipam_config(subnet, Keyword.get(options, :ipam_gateway))
        Map.put(payload, "IPAM", %{"Config" => [ipam_config]})

      other ->
        raise "Expected ipam_subnet to be a string, got: #{inspect(other)}"
    end
  end

  defp build_ipam_config(subnet, nil), do: %{"Subnet" => subnet}

  defp build_ipam_config(subnet, gateway) when is_binary(gateway),
    do: %{"Subnet" => subnet, "Gateway" => gateway}

  defp build_ipam_config(_subnet, other),
    do: raise("Expected ipam_gateway to be a string, got: #{inspect(other)}")

  defp put_network_labels(payload, options) do
    case Keyword.get(options, :labels) do
      nil -> payload
      labels when is_map(labels) -> Map.put(payload, "Labels", labels)
      other -> raise "Expected labels to be a map, got: #{inspect(other)}"
    end
  end

  @doc """
  Connects a container to a network.
  """
  @spec connect_network(network_ref(), container_ref(), options()) ::
          result(json_map() | binary())
  def connect_network(network_id, container_ref, options \\ [])
      when is_binary(network_id) and is_binary(container_ref) do
    if inline_sandbox?(options) do
      sandbox_connect_network_response(network_id, container_ref, options)
    else
      do_connect_network(network_id, container_ref, options)
    end
  end

  defp do_connect_network(network_id, container_ref, options) do
    url = "/networks/#{network_id}/connect"

    payload = %{"Container" => container_ref}

    case EngineClient.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a Docker network by name or ID.
  """
  @spec delete_network(network_ref(), options()) ::
          :ok | {:error, error_reason()}
  def delete_network(network_id, options \\ []) when is_binary(network_id) do
    if inline_sandbox?(options) do
      sandbox_delete_network_response(network_id, options)
    else
      do_delete_network(network_id, options)
    end
  end

  defp do_delete_network(network_id, options) do
    url = "/networks/#{network_id}"

    case EngineClient.request(:delete, url, nil, options) do
      {:ok, %{status: code}} when code in 200..299 -> :ok
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---

  @doc """
  Returns a list of images known to the daemon.
  """
  @spec list_images(params(), options()) :: result(json_list())
  def list_images(params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_list_images_response(params, options)
    else
      do_list_images(params, options)
    end
  end

  defp do_list_images(params, options) do
    url = append_query_string("/images/json", params)

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a list of networks known to the daemon.
  """
  @spec list_networks(params(), options()) :: result(json_list())
  def list_networks(params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_list_networks_response(params, options)
    else
      do_list_networks(params, options)
    end
  end

  defp do_list_networks(params, options) do
    url = append_query_string("/networks", params)

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns an image by name or ID.
  """
  @spec find_image(image_ref(), options()) :: result(json_map())
  def find_image(image_ref, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_find_image_response(image_ref, options)
    else
      do_find_image(image_ref, options)
    end
  end

  defp do_find_image(image_ref, options) do
    url = "/images/#{image_ref}/json"

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, Serializer.deserialize(body)}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pulls an image from a registry.
  """
  @spec pull_image(image :: binary(), params(), options()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def pull_image(image, params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_pull_image_response(image, params, options)
    else
      do_pull_image(image, params, options)
    end
  end

  defp do_pull_image(image, params, options) do
    query = params |> Map.put(:fromImage, image) |> URI.encode_query()
    url = "/images/create?" <> query
    EngineClient.stream(:post, url, nil, Keyword.put_new(options, :into, :ndjson))
  end

  @doc """
  Builds a local image from a Dockerfile path.
  """
  @spec build_image(binary(), binary(), binary(), params(), options()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def build_image(context_path, dockerfile, tag, params \\ %{}, options \\ [])
      when is_binary(tag) and is_binary(context_path) do
    unless tag !== "" do
      raise "Expected tag to be a string, got: #{inspect(tag)}"
    end

    if inline_sandbox?(options) do
      sandbox_build_image_response(context_path, dockerfile, tag, params, options)
    else
      do_build_image(context_path, dockerfile, tag, params, options)
    end
  end

  defp do_build_image(context_path, dockerfile, tag, params, options) do
    context_path = Path.expand(context_path)
    dockerfile_rel = resolve_dockerfile_path(dockerfile, context_path)

    query =
      params
      |> Map.drop([:tag, :t])
      |> Map.merge(%{t: tag, dockerfile: dockerfile_rel})
      |> URI.encode_query()

    url = "/build?" <> query

    with {:ok, tar} <- build_context_tar(context_path) do
      EngineClient.stream(:post, url, {:tar, tar}, Keyword.put_new(options, :into, :ndjson))
    end
  end

  @doc """
  Returns an image if it exists, otherwise builds or pulls it.
  """
  @spec materialize_image(image_ref(), binary(), params(), options()) ::
          {:ok, term()} | {:error, term()}
  def materialize_image(image_ref, image_or_path, params, options) do
    if inline_sandbox?(options) do
      sandbox_materialize_image_response(image_ref, image_or_path, params, options)
    else
      do_materialize_image(image_ref, image_or_path, params, options)
    end
  end

  defp do_materialize_image(image_ref, image_or_path, params, options) do
    case find_image(image_ref, options) do
      {:ok, image} ->
        {:ok, image}

      {:error, %{status: status}} when status in 400..499 ->
        build_or_pull_image(image_ref, image_or_path, params, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_or_pull_image(image_ref, image_or_path, params, options) do
    if local_image_path?(image_or_path) do
      build_local_image(image_ref, image_or_path, params, options)
    else
      pull_image(image_or_path, Map.take(params, @pull_image_query_keys), options)
    end
  end

  defp build_local_image(image_ref, image_or_path, params, options) do
    with {:ok, tag} <- extract_tag(image_ref, params),
         {dockerfile, context_path} <- normalize_build_path(image_or_path) do
      build_image(
        context_path,
        dockerfile,
        tag,
        Map.take(params, @build_image_query_keys),
        options
      )
    end
  end

  defp normalize_build_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {Path.join(expanded, "Dockerfile"), expanded}
    else
      {nil, expanded}
    end
  end

  defp extract_tag(image_ref, params) do
    {_image_ref, tag_or_nil} = split_image_ref_tag(image_ref)
    tag = params[:tag] || params["tag"] || tag_or_nil

    if is_binary(tag) and tag !== "" do
      {:ok, tag}
    else
      {:error, :missing_tag}
    end
  end

  defp local_image_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    File.dir?(expanded) or File.regular?(expanded)
  end

  defp resolve_dockerfile_path(dockerfile, context_path)
       when is_binary(dockerfile) and is_binary(context_path) do
    expanded = expand_dockerfile(dockerfile, context_path)
    dockerfile_rel = relative_dockerfile(expanded, context_path)

    if String.starts_with?(dockerfile_rel, "..") do
      raise "Dockerfile outside of context, got: #{dockerfile}, context: #{context_path}"
    else
      dockerfile_rel
    end
  end

  defp expand_dockerfile(dockerfile, context_path) do
    expanded = Path.expand(dockerfile)

    cond do
      Path.type(dockerfile) === :absolute -> dockerfile
      File.exists?(expanded) -> expanded
      true -> Path.expand(dockerfile, context_path)
    end
  end

  defp relative_dockerfile(expanded, context_path) do
    case Path.relative_to(expanded, context_path) do
      "." -> "Dockerfile"
      rel -> rel
    end
  end

  defp split_image_ref_tag(image_ref) when is_binary(image_ref) do
    regex = ~r/^(?<name>.+)(?::(?<tag>[^\/:]+))?$/

    case Regex.named_captures(regex, image_ref) do
      %{"name" => name, "tag" => tag} -> {name, tag}
      %{"name" => name} -> {name, nil}
      _ -> {image_ref, nil}
    end
  end

  @doc """
  Deletes an image by name or ID.
  """
  @spec delete_image(image_ref(), params(), options()) ::
          result(json_map() | binary() | list())
  def delete_image(image_ref, params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_delete_image_response(image_ref, params, options)
    else
      do_delete_image(image_ref, params, options)
    end
  end

  defp do_delete_image(image_ref, params, options) do
    url = append_query_string("/images/#{image_ref}", params)

    case EngineClient.request(:delete, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---

  @doc """
  Returns logs for a container by ID or name.
  """
  @spec container_logs(container_ref(), params(), options()) :: result(binary())
  def container_logs(container_ref, params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
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

    url = append_query_string("/containers/#{container_ref}/logs", params)
    req_options = Keyword.put_new(options, :into, :raw)

    case EngineClient.request(:get, url, nil, req_options) do
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
  """
  @spec list_containers(params(), options()) :: result(json_list())
  def list_containers(params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_list_containers_response(params, options)
    else
      do_list_containers(params, options)
    end
  end

  defp do_list_containers(params, options) do
    url = append_query_string("/containers/json", params)

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a container by ID or name.
  """
  @spec find_container(container_ref(), options()) :: result(json_map())
  def find_container(container_ref, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_find_container_response(container_ref, options)
    else
      do_find_container(container_ref, options)
    end
  end

  defp do_find_container(container_ref, options) do
    url = "/containers/#{container_ref}/json"

    case EngineClient.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a container by ID or name.
  """
  @spec delete_container(container_ref(), params(), options()) ::
          result(json_map() | binary() | list())
  def delete_container(container_ref, params \\ %{}, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_delete_container_response(container_ref, params, options)
    else
      do_delete_container(container_ref, params, options)
    end
  end

  defp do_delete_container(container_ref, params, options) do
    url = append_query_string("/containers/#{container_ref}", params)

    case EngineClient.request(:delete, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new container.
  """
  @spec create_container(binary(), binary(), options()) ::
          result(docker_id()) | {:error, {list(), docker_id()}}
  def create_container(name, image, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_create_container_response(name, image, options)
    else
      do_create_container(name, image, options)
    end
  end

  defp do_create_container(name, image, options) do
    platform = Keyword.get(options, :platform, "")
    options = maybe_expose_http_port(options)

    url = "/containers/create?name=#{name}&platform=#{platform}"

    config = build_create_container_config(name, image, options)

    case EngineClient.request(:post, url, {:json, config}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        interpret_create_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_create_container_config(name, image, options) do
    auto_remove? = Keyword.get(options, :auto_remove, false)

    base = %{
      "Image" => image,
      "Name" => name,
      "ExposedPorts" => build_exposed_ports_spec(options),
      "HostConfig" => %{
        "AutoRemove" => auto_remove?,
        "PortBindings" => build_port_bindings_spec(options)
      }
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
  Starts an existing container.
  """
  @spec start_container(container_ref(), options()) :: result(binary() | json_map())
  def start_container(container_ref, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_start_container_response(container_ref, options)
    else
      do_start_container(container_ref, options)
    end
  end

  defp do_start_container(container_ref, options) do
    url = "/containers/#{container_ref}/start"

    case EngineClient.request(:post, url, {:json, %{}}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a running container by ID or name.
  """
  @spec stop_container(container_ref(), options()) :: result(binary() | json_map())
  def stop_container(container_ref, options \\ []) do
    if inline_sandbox?(options) do
      sandbox_stop_container_response(container_ref, options)
    else
      do_stop_container(container_ref, options)
    end
  end

  defp do_stop_container(container_ref, options) do
    url = "/containers/#{container_ref}/stop"

    case EngineClient.request(:post, url, {:json, %{}}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Uploads a tar archive into a running container's filesystem.
  """
  @spec put_archive(container_ref(), binary(), binary(), options()) :: result(map() | binary())
  def put_archive(container_ref, dest_path, tar, options \\ [])
      when is_binary(container_ref) and is_binary(dest_path) and is_binary(tar) do
    if inline_sandbox?(options) do
      sandbox_put_archive_response(container_ref, dest_path, tar, options)
    else
      do_put_archive(container_ref, dest_path, tar, options)
    end
  end

  defp do_put_archive(container_ref, dest_path, tar, options) do
    query =
      %{path: dest_path}
      |> maybe_put(:noOverwriteDirNonDir, Keyword.get(options, :no_overwrite_dir_non_dir))
      |> maybe_put(:copyUIDGID, Keyword.get(options, :copy_uid_gid))

    url = append_query_string("/containers/#{container_ref}/archive", query)

    case EngineClient.request(:put, url, {:tar, tar}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns true if a container is running.
  """
  @spec container_running?(map()) :: boolean()
  def container_running?(%{"State" => %{"Running" => running}}) when is_boolean(running) do
    running
  end

  @doc """
  Returns true if a container is running.
  """
  @spec container_running?(container_ref(), options()) :: boolean()
  def container_running?(container_ref, options \\ []) when is_binary(container_ref) do
    if inline_sandbox?(options) do
      sandbox_container_running_response(container_ref, options)
    else
      case find_container(container_ref, options) do
        {:ok, container} -> container_running?(container)
        _other -> false
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp put_exec_option_if_present(payload, _key, nil), do: payload
  defp put_exec_option_if_present(payload, _key, []), do: payload
  defp put_exec_option_if_present(payload, key, value), do: Map.put(payload, key, value)

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

  defp append_query_string(url, params) do
    case URI.encode_query(params) do
      "" -> url
      query -> "#{url}?#{query}"
    end
  end

  defp build_context_tar(context_path) do
    if File.dir?(context_path) do
      args =
        case :os.type() do
          {:unix, :darwin} ->
            ["--no-xattrs", "--no-acls", "--no-mac-metadata", "-C", context_path, "-cf", "-", "."]

          _other_os ->
            ["-C", context_path, "-cf", "-", "."]
        end

      case run_cmd("tar", args) do
        {output, 0} -> {:ok, output}
        {error, code} -> {:error, %{status: code, error: error}}
      end
    else
      {:error, :invalid_context_path}
    end
  end

  defp run_cmd(executable, args) do
    case ElixirExec.run([executable | args], sync: true, stdout: true) do
      {:ok, %ElixirExec.Output{stdout: chunks}} ->
        {IO.iodata_to_binary(chunks), 0}

      {:error, reason} ->
        {inspect(reason), 1}
    end
  end

  # ---------------------------------------------------------------------------
  # SANDBOX HELPERS
  # ---------------------------------------------------------------------------

  defp inline_sandbox?(opts) do
    sandbox_opts = opts[:sandbox] || []
    enabled = Keyword.get(sandbox_opts, :enabled, false)
    enabled and not sandbox_disabled?()
  end

  if Code.ensure_loaded?(SandboxRegistry) do
    @doc false
    defdelegate sandbox_disabled?, to: Docker.Engine.Sandbox

    @doc false
    defdelegate sandbox_endpoint_response(opts),
      to: Docker.Engine.Sandbox,
      as: :endpoint_response

    @doc false
    defdelegate sandbox_ping_response(opts),
      to: Docker.Engine.Sandbox,
      as: :ping_response

    @doc false
    defdelegate sandbox_version_response(opts),
      to: Docker.Engine.Sandbox,
      as: :version_response

    @doc false
    defdelegate sandbox_list_containers_response(params, opts),
      to: Docker.Engine.Sandbox,
      as: :list_containers_response

    @doc false
    defdelegate sandbox_list_images_response(params, opts),
      to: Docker.Engine.Sandbox,
      as: :list_images_response

    @doc false
    defdelegate sandbox_list_networks_response(params, opts),
      to: Docker.Engine.Sandbox,
      as: :list_networks_response

    @doc false
    defdelegate sandbox_find_container_response(container_ref, opts),
      to: Docker.Engine.Sandbox,
      as: :find_container_response

    @doc false
    defdelegate sandbox_start_container_response(container_ref, opts),
      to: Docker.Engine.Sandbox,
      as: :start_container_response

    @doc false
    defdelegate sandbox_stop_container_response(container_ref, opts),
      to: Docker.Engine.Sandbox,
      as: :stop_container_response

    @doc false
    defdelegate sandbox_delete_container_response(container_ref, params, opts),
      to: Docker.Engine.Sandbox,
      as: :delete_container_response

    @doc false
    defdelegate sandbox_container_logs_response(container_ref, params, opts),
      to: Docker.Engine.Sandbox,
      as: :container_logs_response

    @doc false
    defdelegate sandbox_container_running_response(container_ref, opts),
      to: Docker.Engine.Sandbox,
      as: :container_running_response

    @doc false
    defdelegate sandbox_create_container_response(name, image, opts),
      to: Docker.Engine.Sandbox,
      as: :create_container_response

    @doc false
    defdelegate sandbox_find_image_response(image_ref, opts),
      to: Docker.Engine.Sandbox,
      as: :find_image_response

    @doc false
    defdelegate sandbox_pull_image_response(image, params, opts),
      to: Docker.Engine.Sandbox,
      as: :pull_image_response

    @doc false
    defdelegate sandbox_build_image_response(context_path, dockerfile, tag, params, opts),
      to: Docker.Engine.Sandbox,
      as: :build_image_response

    @doc false
    defdelegate sandbox_materialize_image_response(image_ref, image_or_path, params, opts),
      to: Docker.Engine.Sandbox,
      as: :materialize_image_response

    @doc false
    defdelegate sandbox_delete_image_response(image_ref, params, opts),
      to: Docker.Engine.Sandbox,
      as: :delete_image_response

    @doc false
    defdelegate sandbox_find_network_response(network_id, opts),
      to: Docker.Engine.Sandbox,
      as: :find_network_response

    @doc false
    defdelegate sandbox_create_network_response(name, opts),
      to: Docker.Engine.Sandbox,
      as: :create_network_response

    @doc false
    defdelegate sandbox_connect_network_response(network_id, container_ref, opts),
      to: Docker.Engine.Sandbox,
      as: :connect_network_response

    @doc false
    defdelegate sandbox_delete_network_response(network_id, opts),
      to: Docker.Engine.Sandbox,
      as: :delete_network_response

    @doc false
    defdelegate sandbox_exec_create_response(container_ref, cmd, opts),
      to: Docker.Engine.Sandbox,
      as: :exec_create_response

    @doc false
    defdelegate sandbox_exec_start_response(exec_id, opts),
      to: Docker.Engine.Sandbox,
      as: :exec_start_response

    @doc false
    defdelegate sandbox_exec_inspect_response(exec_id, opts),
      to: Docker.Engine.Sandbox,
      as: :exec_inspect_response

    @doc false
    defdelegate sandbox_exec_run_response(container_ref, cmd, opts),
      to: Docker.Engine.Sandbox,
      as: :exec_run_response

    @doc false
    defdelegate sandbox_exec_run_with_status_response(container_ref, cmd, opts),
      to: Docker.Engine.Sandbox,
      as: :exec_run_with_status_response

    @doc false
    defdelegate sandbox_put_archive_response(container_ref, dest_path, tar, opts),
      to: Docker.Engine.Sandbox,
      as: :put_archive_response
  else
    defp sandbox_disabled?, do: true

    defp sandbox_endpoint_response(opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(opts)}
      """
    end

    defp sandbox_ping_response(opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(opts)}
      """
    end

    defp sandbox_version_response(opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(opts)}
      """
    end

    defp sandbox_list_containers_response(params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_list_images_response(params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_list_networks_response(params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_find_container_response(container_ref, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_start_container_response(container_ref, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_stop_container_response(container_ref, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_delete_container_response(container_ref, params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_container_logs_response(container_ref, params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_container_running_response(container_ref, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_create_container_response(name, image, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      name: #{inspect(name)}
      image: #{inspect(image)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_find_image_response(image_ref, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image_ref: #{inspect(image_ref)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_pull_image_response(image, params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image: #{inspect(image)}
      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_build_image_response(context_path, dockerfile, tag, params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      context_path: #{inspect(context_path)}
      dockerfile: #{inspect(dockerfile)}
      tag: #{inspect(tag)}
      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_materialize_image_response(image_ref, image_or_path, params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image_ref: #{inspect(image_ref)}
      image_or_path: #{inspect(image_or_path)}
      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_delete_image_response(image_ref, params, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image_ref: #{inspect(image_ref)}
      params: #{inspect(params)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_find_network_response(network_id, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      network_id: #{inspect(network_id)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_create_network_response(name, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      name: #{inspect(name)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_connect_network_response(network_id, container_ref, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      network_id: #{inspect(network_id)}
      container_ref: #{inspect(container_ref)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_delete_network_response(network_id, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      network_id: #{inspect(network_id)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_exec_create_response(container_ref, cmd, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      cmd: #{inspect(cmd)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_exec_start_response(exec_id, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      exec_id: #{inspect(exec_id)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_exec_inspect_response(exec_id, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      exec_id: #{inspect(exec_id)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_exec_run_response(container_ref, cmd, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      cmd: #{inspect(cmd)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_exec_run_with_status_response(container_ref, cmd, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      cmd: #{inspect(cmd)}
      options: #{inspect(opts)}
      """
    end

    defp sandbox_put_archive_response(container_ref, dest_path, tar, opts) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      dest_path: #{inspect(dest_path)}
      tar: #{inspect(tar)}
      options: #{inspect(opts)}
      """
    end
  end
end
