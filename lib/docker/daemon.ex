defmodule Docker.Daemon do
  @moduledoc """
  Connection health and version checks for the Docker daemon.

  Use this module to verify the daemon is reachable before making other
  calls, and to inspect which version of the Docker Engine API it speaks.
  Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.ping/1`).

  ## Example

      # Check the daemon is up
      {:ok, "OK"} = Docker.Daemon.ping()

      # See what version it is running
      {:ok, info} = Docker.Daemon.version()
      info["Version"]     # e.g. "24.0.5"
      info["ApiVersion"]  # e.g. "1.43"

  See `Docker` for the full client overview, including how to point these
  calls at a remote daemon.
  """

  alias Docker.Client
  alias Docker.Endpoint

  @doc """
  Returns the Docker daemon this client will reach for the given options.

  This is a convenience wrapper around `Docker.Endpoint.from_options/1`.
  Building an endpoint does not open any connection — it is pure data.

  ## Parameters

    * `options` — A keyword list. Recognised keys:
      - `:endpoint` — A `Docker.Endpoint` value, used as-is.
      - `:host` — A URL string like `"unix:///path"`, `"tcp://host:2375"`, or `"https://host:2376"`.
      - `:socket` — A unix socket file path. Shortcut for the legacy "I just want a socket" case.
      - `:tls` — A TLS map `%{verify: ..., cacertfile: ..., certfile: ..., keyfile: ...}` for tcp endpoints.
      - `:version` — The Docker Engine API version string. Defaults to the version on the resolved `Docker.Endpoint` (currently `"1.45"`).

    When no option resolves, falls through to `DOCKER_HOST` env var and the
    standard filesystem socket paths
    (`~/.docker/run/docker.sock`, `/var/run/docker.sock`).

  ## Returns

    * `{:ok, endpoint}` — A resolved `OneOhOne.Endpoint` value.
    * `{:error, :endpoint_not_resolved}` — No rung in the precedence list yielded an endpoint.
    * `{:error, {:invalid_url, :missing_ssh_target}}` — An `ssh://` URL was supplied without a `:target` option. SSH endpoints need a target (`{:exec, cmd}`, `{:tcp, host, port}`, or `{:unix, path}`).
    * `{:error, {:invalid_url, reason}}` — A URL was malformed.

  ## Examples

      iex> Docker.endpoint()
      {:ok, %OneOhOne.Endpoint{transport: :unix, socket_path: ...}}

      iex> Docker.endpoint(host: "tcp://10.0.0.1:2375")
      {:ok, %OneOhOne.Endpoint{transport: :tcp, scheme: :http, host: "10.0.0.1", port: 2375, ...}}
  """
  @spec endpoint(keyword()) :: {:ok, OneOhOne.Endpoint.t()} | {:error, term()}
  def endpoint(options \\ []) do
    if sandbox?(options) do
      sandbox_endpoint_response(options)
    else
      case Endpoint.from_options(options) do
        {:ok, engine_endpoint} ->
          {:ok, Endpoint.to_minty(engine_endpoint)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Asks the Docker daemon whether it is alive and responsive.

  This sends the smallest possible HTTP request (`GET /_ping`). Use it as a
  quick sanity check before making other calls.

  ## Parameters

    - `options` — optional keyword list. Controls which daemon to reach.
      Common keys: `:host`, `:socket`, `:tls`. See `Docker` for the full
      options table. Defaults to the local socket if nothing is given.

  ## Returns

    - `{:ok, "OK"}` — the daemon is reachable and answered.
    - `{:error, reason}` — the daemon could not be reached or returned an
      error. `reason` is typically an exception struct, an atom like
      `:timeout`, or a map `%{status: code, body: body}`.

  ## Examples

      # Connect to the local Docker daemon
      {:ok, "OK"} = Docker.Daemon.ping()

      # Connect to a remote daemon
      {:ok, "OK"} = Docker.Daemon.ping(host: "tcp://10.0.0.1:2375")
  """
  @spec ping(Docker.options()) :: Docker.result(binary())
  def ping(options \\ []) do
    if sandbox?(options) do
      sandbox_ping_response(options)
    else
      do_ping(options)
    end
  end

  defp do_ping(options) do
    case Client.request(:get, "/_ping", nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a map describing the Docker Engine and the host it is running on.

  Useful for checking API compatibility before making other calls. The map
  includes the Engine version, the API version it speaks, the host OS and
  architecture, and more.

  ## Parameters

    - `options` — optional keyword list. Same daemon-selection keys as
      `ping/1`. See `Docker` for the full options table.

  ## Returns

    - `{:ok, map}` — a map with string keys. Commonly used keys:
      - `"Version"` — Docker Engine version, e.g. `"24.0.5"`.
      - `"ApiVersion"` — highest API version the daemon supports, e.g. `"1.43"`.
      - `"MinAPIVersion"` — lowest API version the daemon accepts.
      - `"Os"` — operating system, e.g. `"linux"`.
      - `"Arch"` — CPU architecture, e.g. `"amd64"`.
    - `{:error, reason}` — daemon not reachable or returned an error.

  ## Examples

      {:ok, info} = Docker.Daemon.version()
      info["Version"]     # e.g. "24.0.5"
      info["ApiVersion"]  # e.g. "1.43"
      info["Os"]          # e.g. "linux"
  """
  @spec version(Docker.options()) :: Docker.result(Docker.json_map())
  def version(options \\ []) do
    if sandbox?(options) do
      sandbox_version_response(options)
    else
      do_version(options)
    end
  end

  defp do_version(options) do
    case Client.request(:get, "/version", nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
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
    defdelegate sandbox_endpoint_response(options),
      to: Docker.Sandbox,
      as: :endpoint_response

    @doc false
    defdelegate sandbox_ping_response(options),
      to: Docker.Sandbox,
      as: :ping_response

    @doc false
    defdelegate sandbox_version_response(options),
      to: Docker.Sandbox,
      as: :version_response
  else
    defp sandbox_disabled?, do: true

    defp sandbox_endpoint_response(options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(options)}
      """
    end

    defp sandbox_ping_response(options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(options)}
      """
    end

    defp sandbox_version_response(options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(options)}
      """
    end
  end
end
