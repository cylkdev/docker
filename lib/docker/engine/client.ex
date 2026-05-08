defmodule Docker.Engine.Client do
  @moduledoc """
  Docker-specific HTTP wrapper over `Sorrel`.

  Adds three Docker Engine conventions on top of the generic transport:

    * The `/v<version>` path prefix that the Engine API uses for versioned
      endpoints.
    * The `:registry_auth` option, which the Engine API accepts as the
      `X-Registry-Auth` header for image pull/push/build calls.
    * The `:into: :frame` decoding mode, which post-processes the body or
      stream through `Docker.Engine.Frame` to reverse Docker's stdout/stderr
      multiplexing.

  Internally, every call resolves an endpoint via `Docker.Engine.Endpoint`,
  converts it to a generic `Sorrel.Endpoint`, and delegates to
  `Sorrel.request/5` or `Sorrel.stream/5`. `Sorrel` itself
  is Docker-agnostic — it does not prepend versions, it does not understand
  registry-auth, and it does not know what a Docker frame is.

  ## Examples

      iex> {:ok, %{status: 200, body: "OK"}} = Docker.Engine.Client.request(:get, "/_ping")

      iex> {:ok, events} =
      ...>   Docker.Engine.Client.stream(
      ...>     :post, "/images/create?fromImage=alpine", nil,
      ...>     into: :ndjson
      ...>   )
      iex> events |> Enum.take(1) |> hd() |> Map.has_key?("status")
      true
  """

  # Abstraction Function:
  #   Stateless façade. Maps Docker-shaped (method, path, body, options) to
  #   generic-shaped (method, full_path, body, minty_options) and delegates
  #   to Sorrel.{request,stream}/4.
  #
  # Data Invariant:
  #   1. Every call resolves a Docker.Engine.Endpoint before any I/O.
  #   2. The path passed to Sorrel starts with /v<digits> exactly when
  #      this module prepended it OR the caller already supplied it.
  #   3. Frame post-processing runs only on 2xx responses; non-2xx bodies
  #      pass through unchanged.

  alias Docker.Engine.Endpoint, as: EngineEndpoint
  alias Docker.Engine.Frame
  alias Sorrel

  @type method :: Sorrel.method()
  @type body :: Sorrel.body()
  @type into :: :auto | :json | :ndjson | :raw | :frame
  @type response :: Sorrel.response()

  @doc """
  Sends one HTTP request to the Docker daemon and waits for the full response.

  Same as `Sorrel.request/5` plus three Docker-specific conventions:

    * `path` — If it does not begin with `/v<digit>`, the resolved Engine
      API version is prepended automatically.
    * `options[:registry_auth]` — A string. Sent as the `X-Registry-Auth`
      header for endpoints that require registry authentication.
    * `options[:into] == :frame` — On 2xx responses, the body is run through
      `Docker.Engine.Frame.demux_all/1` to recover the original stdout and
      stderr bytes (Docker multiplexes them when no PTY is attached).
      On non-2xx responses, the body is returned raw — frame demuxing would
      be wrong on an error body.

  All other options are forwarded verbatim to `Sorrel.request/5`.

  ## Returns

    * `{:ok, response}` — Status was 200..299.
    * `{:error, response}` — Status was outside 200..299.
    * `{:error, reason}` — Endpoint resolution failed or transport failed.
  """
  @spec request(method(), String.t(), body(), keyword()) ::
          {:ok, response()} | {:error, response() | term()}
  def request(method, path, body \\ nil, options \\ []) do
    case EngineEndpoint.from_options(options) do
      {:ok, engine_endpoint} ->
        do_request(method, path, body, engine_endpoint, options)

      {:error, _reason} = error ->
        error
    end
  end

  @spec do_request(method(), String.t(), body(), EngineEndpoint.t(), keyword()) ::
          {:ok, response()} | {:error, response() | term()}
  defp do_request(method, path, body, engine_endpoint, options) do
    full_path = prepend_version(path, engine_endpoint, options)
    minty_endpoint = EngineEndpoint.to_minty(engine_endpoint)
    minty_options = build_minty_options(options)
    into_mode = Keyword.get(options, :into, :auto)
    dispatch_request(minty_endpoint, method, full_path, body, into_mode, minty_options)
  end

  @spec dispatch_request(
          Sorrel.Endpoint.t(),
          method(),
          String.t(),
          body(),
          into(),
          keyword()
        ) :: {:ok, response()} | {:error, response() | term()}
  defp dispatch_request(minty_endpoint, method, full_path, body, :frame, minty_options) do
    raw_options = Keyword.put(minty_options, :into, :raw)

    case Sorrel.request(minty_endpoint, method, full_path, body, raw_options) do
      {:ok, %{status: status, body: raw} = response} when status in 200..299 ->
        {:ok, %{response | body: Frame.demux_all(raw)}}

      other ->
        other
    end
  end

  defp dispatch_request(minty_endpoint, method, full_path, body, _into, minty_options) do
    Sorrel.request(minty_endpoint, method, full_path, body, minty_options)
  end

  @doc """
  Sends one HTTP request and returns an Elixir `Stream` of events.

  Same as `Sorrel.stream/5` plus the Docker conventions documented on
  `request/4`. In addition, when `options[:into]` is `:frame`, the returned
  stream yields `{:stdout, binary} | {:stderr, binary}` events as each frame
  payload arrives, parsed incrementally via
  `Docker.Engine.Frame.decode_chunk/2`.

  ## Returns

    * `{:ok, stream}` — Status was 200..299. Consume with `Enum.*` / `Stream.*`.
    * `{:error, response}` — Non-2xx status; body fully read.
    * `{:error, reason}` — Endpoint resolution or transport failed.
  """
  @spec stream(method(), String.t(), body(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, response() | term()}
  def stream(method, path, body \\ nil, options \\ []) do
    case EngineEndpoint.from_options(options) do
      {:ok, engine_endpoint} ->
        do_stream(method, path, body, engine_endpoint, options)

      {:error, _reason} = error ->
        error
    end
  end

  @spec do_stream(method(), String.t(), body(), EngineEndpoint.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, response() | term()}
  defp do_stream(method, path, body, engine_endpoint, options) do
    full_path = prepend_version(path, engine_endpoint, options)
    minty_endpoint = EngineEndpoint.to_minty(engine_endpoint)
    minty_options = build_minty_options(options)
    into_mode = Keyword.get(options, :into, :ndjson)
    dispatch_stream(minty_endpoint, method, full_path, body, into_mode, minty_options)
  end

  @spec dispatch_stream(
          Sorrel.Endpoint.t(),
          method(),
          String.t(),
          body(),
          into(),
          keyword()
        ) :: {:ok, Enumerable.t()} | {:error, response() | term()}
  defp dispatch_stream(minty_endpoint, method, full_path, body, :frame, minty_options) do
    raw_options = Keyword.put(minty_options, :into, :raw)

    case Sorrel.stream(minty_endpoint, method, full_path, body, raw_options) do
      {:ok, raw_stream} ->
        {:ok, wrap_frame_stream(raw_stream)}

      {:error, _reason} = error ->
        error
    end
  end

  defp dispatch_stream(minty_endpoint, method, full_path, body, _into, minty_options) do
    Sorrel.stream(minty_endpoint, method, full_path, body, minty_options)
  end

  @spec wrap_frame_stream(Enumerable.t()) :: Enumerable.t()
  defp wrap_frame_stream(raw_stream) do
    Stream.transform(
      raw_stream,
      fn -> "" end,
      fn chunk, buffer ->
        {events, new_buffer} = Frame.decode_chunk(chunk, buffer)
        {events, new_buffer}
      end,
      fn _final_buffer -> :ok end
    )
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Builds the keyword list handed to Sorrel. The Sorrel endpoint is
  # passed as a separate positional argument by the caller; this function
  # only strips Docker-specific keys (`:registry_auth`, `:version`,
  # `:endpoint`) and folds `:registry_auth` into the `:headers` list. All
  # other options pass through.
  @spec build_minty_options(keyword()) :: keyword()
  defp build_minty_options(options) do
    options
    |> Keyword.delete(:registry_auth)
    |> Keyword.delete(:version)
    |> Keyword.delete(:endpoint)
    |> add_registry_auth(options)
  end

  @spec add_registry_auth(keyword(), keyword()) :: keyword()
  defp add_registry_auth(minty_options, options) do
    case Keyword.get(options, :registry_auth) do
      value when is_binary(value) ->
        existing = Keyword.get(minty_options, :headers, [])
        Keyword.put(minty_options, :headers, existing ++ [{"x-registry-auth", value}])

      _other ->
        minty_options
    end
  end

  # Prepends `/v<version>` to the path unless the caller already supplied a
  # version-prefixed path. Recognises `/vN[.N]+` at the start. The version
  # comes from `options[:version]` (override) or the resolved engine endpoint.
  @spec prepend_version(String.t(), EngineEndpoint.t(), keyword()) :: String.t()
  defp prepend_version(path, %EngineEndpoint{} = engine_endpoint, options) do
    if Regex.match?(~r{^/v\d}, path) do
      path
    else
      version =
        case Keyword.get(options, :version) do
          v when is_binary(v) and v !== "" -> v
          _other -> EngineEndpoint.version(engine_endpoint)
        end

      "/v" <> version <> path
    end
  end
end
