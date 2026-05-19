defmodule Docker.Endpoint do
  @moduledoc """
  Resolves the Docker daemon a call should reach.

  Wraps an `OneOhOne.Endpoint` with Docker Engine API conventions:
  the `:version` field, the `DOCKER_HOST` / `DOCKER_TLS_VERIFY` /
  `DOCKER_CERT_PATH` environment variables, and the standard Docker
  Desktop and Linux socket-file fallbacks.

  Building an endpoint does not open a connection. It is pure data.

  ## How to get one

  Most callers do not build an endpoint directly. They pass options to a
  `Docker.*` function and let `from_options/1` figure it out:

      Docker.ping()
      # uses /var/run/docker.sock or ~/.docker/run/docker.sock if present.

      Docker.ping(host: "tcp://10.0.0.1:2375")
      # talks to a remote Docker daemon over plain TCP.

      System.put_env("DOCKER_HOST", "tcp://10.0.0.1:2376")
      System.put_env("DOCKER_TLS_VERIFY", "1")
      System.put_env("DOCKER_CERT_PATH", "/Users/me/.docker/certs")
      Docker.ping()
      # talks to the daemon over TLS, using the certificate files in DOCKER_CERT_PATH.

  ## Resolution precedence

  `from_options/1` walks these in order until one yields:

    1. `options[:endpoint]` — a `Docker.Endpoint` value.
    2. `options[:host]` — a Docker-style URL.
    3. `options[:socket]` — a unix socket file path.
    4. `DOCKER_HOST` environment variable.
    5. `~/.docker/run/docker.sock` if it exists.
    6. `/var/run/docker.sock` if it exists.

  TLS material for `:tcp` endpoints is loaded from `DOCKER_TLS_VERIFY`
  and `DOCKER_CERT_PATH` (matching the Docker CLI), unless `options[:tls]`
  overrides it.

  ## SSH URLs

  `ssh://[user@]host[:port]` URLs cannot be parsed from a bare URL
  string. They need a `:target` (and `:ssh` auth/verify options) that
  this function does not synthesise. Callers wanting an SSH-backed
  Engine endpoint must build a `%Docker.Endpoint{}` directly
  (wrapping a pre-built `%OneOhOne.Endpoint{transport: :ssh, ...}`) and
  pass it via `options[:endpoint]`. Passing a bare `ssh://` URL to
  `options[:host]` returns `{:error, {:invalid_url, :missing_ssh_target}}`.

  SSH endpoints are also only usable with the streaming session API
  (`Docker.attach/2`, `Docker.exec_session/3`, `Docker.send_message/4`).
  `Docker.Client` returns `{:error, :ssh_not_supported_for_unary}`
  for SSH endpoints because Req does not speak SSH.

  Application configuration is not consulted — every override comes from
  caller `options` or environment variables.
  """

  # Abstraction Function:
  #   The Engine endpoint wraps an OneOhOne endpoint plus the Docker
  #   Engine API version string. The OneOhOne endpoint says how to
  #   reach the daemon (transport, address, TLS); the version says
  #   which `/v<n>` URL prefix the Engine.Client wrapper will prepend
  #   onto request paths.
  #   Base case: %Engine.Endpoint{
  #     minty: %OneOhOne.Endpoint{transport: :unix, socket_path: "/var/run/docker.sock"},
  #     version: "1.45"
  #   }.
  #
  # Data Invariant:
  #   1. minty is a well-formed OneOhOne.Endpoint.
  #   2. version is a non-empty string matching ~r/^\d+\.\d+$/.

  alias OneOhOne.Endpoint, as: MintyEndpoint

  @default_version "1.45"
  @desktop_socket_suffix ".docker/run/docker.sock"
  @linux_socket "/var/run/docker.sock"

  @type t :: %__MODULE__{
          minty: MintyEndpoint.t(),
          version: String.t()
        }

  defstruct minty: nil, version: @default_version

  @type rung_result :: {:ok, t()} | :no_match | {:error, term()}

  @doc """
  Resolves a Docker engine endpoint from caller options, environment
  variables, and the filesystem, in a documented order.
  """
  @spec from_options(keyword()) :: {:ok, t()} | {:error, term()}
  def from_options(options \\ []) when is_list(options) do
    with :no_match <- resolve_from_endpoint_option(options),
         :no_match <- resolve_from_host_option(options),
         :no_match <- resolve_from_socket_option(options),
         :no_match <- resolve_from_docker_host_env(options),
         :no_match <- resolve_from_desktop_socket_file(options),
         :no_match <- resolve_from_linux_socket_file(options) do
      {:error, :endpoint_not_resolved}
    else
      {:ok, endpoint} ->
        {:ok, apply_options_overrides(endpoint, options)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Resolves a Docker engine endpoint from environment variables and the
  filesystem only, ignoring options-only rungs.
  """
  @spec from_env(keyword()) :: {:ok, t()} | {:error, term()}
  def from_env(options \\ []) when is_list(options) do
    with :no_match <- resolve_from_docker_host_env(options),
         :no_match <- resolve_from_desktop_socket_file(options),
         :no_match <- resolve_from_linux_socket_file(options) do
      {:error, :endpoint_not_resolved}
    else
      {:ok, endpoint} ->
        {:ok, apply_options_overrides(endpoint, options)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns the underlying `OneOhOne.Endpoint`.

  Use this when handing the endpoint to `OneOhOne.*` functions, which
  are Docker-agnostic and only understand the generic struct.
  """
  @spec to_minty(t()) :: MintyEndpoint.t()
  def to_minty(%__MODULE__{minty: minty}), do: minty

  @doc """
  Returns the Docker Engine API version this endpoint targets, e.g.
  `"1.45"`.
  """
  @spec version(t()) :: String.t()
  def version(%__MODULE__{version: version}), do: version

  # ---------------------------------------------------------------------------
  # Internals — precedence ladder
  # ---------------------------------------------------------------------------

  @spec resolve_from_endpoint_option(keyword()) :: rung_result()
  defp resolve_from_endpoint_option(options) do
    case Keyword.get(options, :endpoint) do
      nil -> :no_match
      %__MODULE__{} = endpoint -> {:ok, endpoint}
    end
  end

  @spec resolve_from_host_option(keyword()) :: rung_result()
  defp resolve_from_host_option(options) do
    case Keyword.get(options, :host) do
      nil -> :no_match
      url when is_binary(url) -> wrap_minty_parse(url, options)
    end
  end

  @spec resolve_from_socket_option(keyword()) :: rung_result()
  defp resolve_from_socket_option(options) do
    case Keyword.get(options, :socket) do
      nil ->
        :no_match

      path when is_binary(path) and path !== "" ->
        {:ok,
         %__MODULE__{
           minty: %MintyEndpoint{transport: :unix, socket_path: path},
           version: @default_version
         }}
    end
  end

  @spec resolve_from_docker_host_env(keyword()) :: rung_result()
  defp resolve_from_docker_host_env(options) do
    case System.get_env("DOCKER_HOST") do
      nil -> :no_match
      "" -> :no_match
      url when is_binary(url) -> wrap_minty_parse(url, options)
    end
  end

  @spec resolve_from_desktop_socket_file(keyword()) :: rung_result()
  defp resolve_from_desktop_socket_file(_options) do
    # Read $HOME at call time rather than using Path.expand("~/...") so that
    # tests can swap HOME via System.put_env/2. Path.expand resolves "~" via
    # :init.get_argument(:home), which the BEAM caches at startup and which
    # does not see env mutations made after boot.
    with home when is_binary(home) and home !== "" <- System.get_env("HOME"),
         path = Path.join(home, @desktop_socket_suffix),
         true <- File.exists?(path) do
      {:ok,
       %__MODULE__{
         minty: %MintyEndpoint{transport: :unix, socket_path: path},
         version: @default_version
       }}
    else
      _ -> :no_match
    end
  end

  @spec resolve_from_linux_socket_file(keyword()) :: rung_result()
  defp resolve_from_linux_socket_file(_options) do
    if File.exists?(@linux_socket) do
      {:ok,
       %__MODULE__{
         minty: %MintyEndpoint{transport: :unix, socket_path: @linux_socket},
         version: @default_version
       }}
    else
      :no_match
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — URL parsing
  # ---------------------------------------------------------------------------

  @spec wrap_minty_parse(String.t(), keyword()) :: rung_result()
  defp wrap_minty_parse(url, _options) do
    case parse_url(url) do
      {:ok, %MintyEndpoint{} = minty} ->
        minty = apply_docker_port_default(minty, url)
        {:ok, %__MODULE__{minty: minty, version: @default_version}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec parse_url(String.t()) :: {:ok, MintyEndpoint.t()} | {:error, {:invalid_url, term()}}
  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: nil}} ->
        {:error, {:invalid_url, :missing_scheme}}

      {:ok, %URI{scheme: "unix", path: path}} ->
        parse_unix_url(path)

      {:ok, %URI{scheme: scheme, host: host, port: port}} when scheme in ~w(tcp http) ->
        parse_tcp_url(:http, host, port)

      {:ok, %URI{scheme: "https", host: host, port: port}} ->
        parse_tcp_url(:https, host, port)

      {:ok, %URI{scheme: "ssh"}} ->
        # SSH endpoints require a :target (and auth) we cannot derive from a
        # bare URL. Callers that need SSH must build the endpoint struct.
        {:error, {:invalid_url, :missing_ssh_target}}

      {:ok, %URI{scheme: scheme}} ->
        {:error, {:invalid_url, {:unsupported_scheme, scheme}}}

      {:error, reason} ->
        {:error, {:invalid_url, reason}}
    end
  end

  defp parse_unix_url(nil), do: {:error, {:invalid_url, :missing_socket_path}}
  defp parse_unix_url(""), do: {:error, {:invalid_url, :missing_socket_path}}

  defp parse_unix_url(path) when is_binary(path) do
    {:ok, %MintyEndpoint{transport: :unix, socket_path: path}}
  end

  defp parse_tcp_url(_scheme, nil, _port), do: {:error, {:invalid_url, :missing_host}}
  defp parse_tcp_url(_scheme, "", _port), do: {:error, {:invalid_url, :missing_host}}

  defp parse_tcp_url(scheme, host, port) when is_binary(host) do
    cond do
      is_nil(port) ->
        {:ok, %MintyEndpoint{transport: :tcp, scheme: scheme, host: host}}

      port in 1..65_535 ->
        {:ok, %MintyEndpoint{transport: :tcp, scheme: scheme, host: host, port: port}}

      true ->
        {:error, {:invalid_url, {:port_out_of_range, port}}}
    end
  end

  # Docker's default ports differ from generic HTTP defaults: the Docker
  # daemon listens on 2375 for plain HTTP and 2376 for HTTPS. When a caller
  # gives us a URL without an explicit port, prefer the Docker port over
  # whatever default our parser filled in. Unix endpoints carry no port
  # and are returned unchanged.
  @spec apply_docker_port_default(MintyEndpoint.t(), String.t()) :: MintyEndpoint.t()
  defp apply_docker_port_default(%MintyEndpoint{transport: :tcp, scheme: scheme} = minty, url) do
    if explicit_port?(url) do
      minty
    else
      docker_default =
        case scheme do
          :http -> 2375
          :https -> 2376
        end

      %{minty | port: docker_default}
    end
  end

  defp apply_docker_port_default(%MintyEndpoint{} = minty, _url), do: minty

  # ---------------------------------------------------------------------------
  # Internals — post-resolution overrides (TLS + version)
  # ---------------------------------------------------------------------------

  @spec apply_options_overrides(t(), keyword()) :: t()
  defp apply_options_overrides(endpoint, options) do
    endpoint
    |> apply_tls(options, options_url(options))
    |> apply_version(options)
  end

  @spec options_url(keyword()) :: String.t() | nil
  defp options_url(options) do
    case Keyword.get(options, :host) do
      url when is_binary(url) -> url
      _other -> nil
    end
  end

  @spec apply_tls(t(), keyword(), String.t() | nil) :: t()
  defp apply_tls(%__MODULE__{minty: %MintyEndpoint{transport: :unix}} = ep, _options, _url) do
    ep
  end

  defp apply_tls(%__MODULE__{minty: %MintyEndpoint{transport: :tcp}} = ep, options, url) do
    case Keyword.get(options, :tls) do
      nil -> apply_env_tls(ep, url)
      %{} = tls -> upgrade_to_tls(ep, tls, url)
    end
  end

  defp apply_tls(%__MODULE__{} = ep, _options, _url), do: ep

  @spec apply_env_tls(t(), String.t() | nil) :: t()
  defp apply_env_tls(ep, url) do
    if env_tls_verify?() do
      cert_path = System.get_env("DOCKER_CERT_PATH")

      tls = %{
        verify: :verify_peer,
        cacertfile: cert_file(cert_path, "ca.pem"),
        certfile: cert_file(cert_path, "cert.pem"),
        keyfile: cert_file(cert_path, "key.pem")
      }

      upgrade_to_tls(ep, tls, url)
    else
      ep
    end
  end

  @spec env_tls_verify?() :: boolean()
  defp env_tls_verify? do
    case System.get_env("DOCKER_TLS_VERIFY") do
      "1" -> true
      "true" -> true
      _other -> false
    end
  end

  @spec cert_file(String.t() | nil, String.t()) :: String.t() | nil
  defp cert_file(nil, _filename), do: nil
  defp cert_file("", _filename), do: nil
  defp cert_file(dir, filename), do: Path.join(dir, filename)

  @spec upgrade_to_tls(t(), MintyEndpoint.tls(), String.t() | nil) :: t()
  defp upgrade_to_tls(%__MODULE__{minty: minty} = ep, tls, url) do
    port =
      cond do
        is_binary(url) and not explicit_port?(url) -> 2376
        is_nil(minty.port) -> 2376
        true -> minty.port
      end

    %{ep | minty: %{minty | scheme: :https, port: port, tls: tls}}
  end

  @spec explicit_port?(String.t()) :: boolean()
  defp explicit_port?(url) do
    case Regex.run(~r{^[a-zA-Z][a-zA-Z0-9+.\-]*://[^/?#]*}, url) do
      [authority] -> Regex.match?(~r/:\d+$/, authority)
      _other -> false
    end
  end

  @spec apply_version(t(), keyword()) :: t()
  defp apply_version(%__MODULE__{} = ep, options) do
    case Keyword.get(options, :version) do
      version when is_binary(version) and version !== "" ->
        %{ep | version: version}

      _other ->
        ep
    end
  end
end
