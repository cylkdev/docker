defmodule Docker.Engine.Endpoint do
  @moduledoc """
  Resolves the Docker daemon a call should reach.

  Wraps a `Sorrel.Endpoint` with Docker Engine API conventions:
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

    1. `options[:endpoint]` — a `Docker.Engine.Endpoint` value.
    2. `options[:host]` — a Docker-style URL.
    3. `options[:socket]` — a unix socket file path.
    4. `DOCKER_HOST` environment variable.
    5. `~/.docker/run/docker.sock` if it exists.
    6. `/var/run/docker.sock` if it exists.

  TLS material for `:tcp` endpoints is loaded from `DOCKER_TLS_VERIFY`
  and `DOCKER_CERT_PATH` (matching the Docker CLI), unless `options[:tls]`
  overrides it.

  ## SSH URLs

  `ssh://[user@]host[:port]` URLs are recognised by the underlying
  `Sorrel.Endpoint.parse/2`, but the URL alone is not enough: the
  parser also requires a `:target` option (and optionally `:ssh` and
  `:user`) saying what to run on or forward to on the remote side. This
  function forwards the URL to `parse/2` without those extra options, so
  using `ssh://` here today returns `{:error, {:invalid_url,
  :missing_ssh_target}}`. Callers that need an SSH-backed Engine endpoint
  should build a `%Docker.Engine.Endpoint{}` directly — wrapping a
  pre-parsed `%Sorrel.Endpoint{transport: :ssh, ...}` in the
  `:minty` field — and pass it via `options[:endpoint]` (rung 1) rather
  than as a URL string.

  Application configuration is not consulted — every override comes from
  caller `options` or environment variables.
  """

  # Abstraction Function:
  #   The Engine endpoint is a small wrapper around a generic Sorrel
  #   endpoint plus the Docker Engine API version string. The generic
  #   endpoint says how to reach the daemon (transport, address, TLS);
  #   the version says which `/v<n>` URL prefix the Engine.Client wrapper
  #   will prepend onto request paths.
  #   Base case: %Engine.Endpoint{
  #     minty: %Sorrel.Endpoint{transport: :unix, socket_path: "/var/run/docker.sock"},
  #     version: "1.45"
  #   }.
  #
  # Data Invariant:
  #   1. minty is a well-formed Sorrel.Endpoint.
  #   2. version is a non-empty string matching ~r/^\d+\.\d+$/.

  alias Sorrel.Endpoint, as: MintyEndpoint

  @default_version "1.45"
  @desktop_socket_relative "~/.docker/run/docker.sock"
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

  ## Parameters

    * `options` — A keyword list. The keys it reads:
      - `:endpoint` — A `Docker.Engine.Endpoint` value. Used as is.
      - `:host` — A URL string (see `Sorrel.Endpoint.parse/2`).
      - `:socket` — A unix socket file path. Shortcut for the legacy "I just
        want to point at a socket file" case.
      - `:tls` — A `Sorrel.Endpoint.tls()` map. Used only when the
        resolved endpoint is `:tcp`. Overrides anything from environment
        variables.
      - `:version` — A version string like `"1.45"`. Overrides the version on
        the resolved endpoint. Defaults to `"#{@default_version}"`.

      Unknown keys are ignored.

  ## What it returns

    * `{:ok, engine_endpoint}` — The first matching rung wins. The result
      is a `%Docker.Engine.Endpoint{}` whose `:minty` field is the generic
      endpoint and whose `:version` is the override (if any) or the module
      default.
    * `{:error, :endpoint_not_resolved}` — every rung gave up.
    * `{:error, {:invalid_url, reason}}` — a URL rung was malformed. For
      `ssh://` URLs in particular, `reason` is `:missing_ssh_target` when
      the caller did not supply a `:target` option, `:missing_user` when
      the URL has no userinfo and no `:user` option was given, and
      `:invalid_target` when the supplied `:target` option was not one of
      the recognised shapes.

  When the resolved endpoint is `:tcp` and `options[:tls]` is missing, this
  function reads `DOCKER_TLS_VERIFY` and `DOCKER_CERT_PATH`. If
  `DOCKER_TLS_VERIFY` is `"1"` or `"true"`, the resulting Sorrel endpoint has
  `scheme: :https`, port defaulting to 2376, and `tls` filled in from
  `DOCKER_CERT_PATH/ca.pem,cert.pem,key.pem`.

  When `options[:tls]` is non-nil and the resolved transport is `:tcp`, the
  resulting Sorrel endpoint's `scheme` is forced to `:https` and the port
  defaults to 2376 if the URL did not specify one.

  This function reads files (rungs 5 and 6) and environment variables (rung 4),
  but does not open any network connection.

  ## Examples

      iex> Docker.Engine.Endpoint.from_options(host: "tcp://h:2376")
      {:ok, %Docker.Engine.Endpoint{
        minty: %Sorrel.Endpoint{transport: :tcp, scheme: :http, host: "h", port: 2376},
        version: "1.45"
      }}

      iex> Docker.Engine.Endpoint.from_options(socket: "/tmp/d.sock")
      {:ok, %Docker.Engine.Endpoint{
        minty: %Sorrel.Endpoint{transport: :unix, socket_path: "/tmp/d.sock"},
        version: "1.45"
      }}
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

  Equivalent to running `from_options/1` but with rungs 1, 2, and 3
  silently skipped. Other options (`:tls`, `:version`) still apply to the
  endpoint resolved from env or the filesystem.

  ## What it returns

    * `{:ok, engine_endpoint}` — same shape as `from_options/1`.
    * `{:error, :endpoint_not_resolved}` — neither environment nor
      filesystem yielded an endpoint.
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
  Returns the underlying generic `Sorrel.Endpoint`.

  Use this when handing the endpoint to `Sorrel.*` functions, which
  are Docker-agnostic and only understand the generic struct.
  """
  @spec to_minty(t()) :: MintyEndpoint.t()
  def to_minty(%__MODULE__{minty: minty}), do: minty

  @doc """
  Returns the Docker Engine API version this endpoint targets, e.g.
  `"1.45"`.

  `Docker.Engine.Client` prepends this version onto every request path
  that does not already start with `/v<digit>`.
  """
  @spec version(t()) :: String.t()
  def version(%__MODULE__{version: version}), do: version

  # ---------------------------------------------------------------------------
  # Internals — precedence ladder
  #
  # Each rung is one named function. It returns either:
  #
  #   * {:ok, engine_endpoint} — this rung resolved the endpoint, stop here.
  #   * :no_match              — this rung had nothing to contribute.
  #   * {:error, reason}       — the input was malformed; short-circuit.
  # ---------------------------------------------------------------------------

  @spec resolve_from_endpoint_option(keyword()) :: rung_result()
  defp resolve_from_endpoint_option(options) do
    case Keyword.get(options, :endpoint) do
      nil ->
        :no_match

      %__MODULE__{} = endpoint ->
        {:ok, endpoint}
    end
  end

  @spec resolve_from_host_option(keyword()) :: rung_result()
  defp resolve_from_host_option(options) do
    case Keyword.get(options, :host) do
      nil ->
        :no_match

      url when is_binary(url) ->
        wrap_minty_parse(url, options)
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
      nil ->
        :no_match

      "" ->
        :no_match

      url when is_binary(url) ->
        wrap_minty_parse(url, options)
    end
  end

  @spec resolve_from_desktop_socket_file(keyword()) :: rung_result()
  defp resolve_from_desktop_socket_file(_options) do
    path = Path.expand(@desktop_socket_relative)

    if File.exists?(path) do
      {:ok,
       %__MODULE__{
         minty: %MintyEndpoint{transport: :unix, socket_path: path},
         version: @default_version
       }}
    else
      :no_match
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
  # Internals — Sorrel parse wrapper
  # ---------------------------------------------------------------------------

  @spec wrap_minty_parse(String.t(), keyword()) :: rung_result()
  defp wrap_minty_parse(url, _options) do
    case MintyEndpoint.parse(url) do
      {:ok, %MintyEndpoint{} = minty} ->
        minty = apply_docker_port_default(minty, url)
        {:ok, %__MODULE__{minty: minty, version: @default_version}}

      {:error, _reason} = error ->
        error
    end
  end

  # Docker's default ports differ from generic HTTP defaults: the Docker
  # daemon listens on 2375 for plain HTTP and 2376 for HTTPS. When a caller
  # gives us a URL without an explicit port, prefer the Docker port over
  # whatever default `Sorrel.Endpoint.parse/2` filled in (80 for plain,
  # 443 for HTTPS). Unix endpoints carry no port and are returned unchanged.
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

  # Returns the URL string from options[:host] if any. apply_tls uses this
  # to detect whether the user gave an explicit port and decide whether to
  # default the port on a TLS scheme upgrade.
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
      nil ->
        apply_env_tls(ep, url)

      %{} = tls ->
        upgrade_to_tls(ep, tls, url)
    end
  end

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

  # Upgrade a wrapped :tcp endpoint to TLS. If the user supplied a URL via
  # options[:host] without an explicit port, prefer the TLS default 2376
  # over whatever earlier defaults filled in (2375 from
  # apply_docker_port_default for tcp://...).
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

  # Detect whether the original URL string included an explicit ":port" after
  # the authority. URI.new/1 backfills defaults for well-known schemes
  # (e.g. https → 443) which we never want; this lets us distinguish "no port"
  # from "explicit port".
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
