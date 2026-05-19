defmodule Docker.Client do
  @moduledoc """
  Docker-specific HTTP wrapper over `Req`.

  Adds three Docker Engine conventions on top of the generic transport:

    * The `/v<version>` path prefix that the Engine API uses for versioned
      endpoints.
    * The `:registry_auth` option, which the Engine API accepts as the
      `X-Registry-Auth` header for image pull/push/build calls.
    * The `:into: :frame` decoding mode, which post-processes the body or
      stream through `Docker.Frame` to reverse Docker's stdout/stderr
      multiplexing.

  Internally, every call resolves an endpoint via `Docker.Endpoint`
  and delegates to `Req.request/1`. Unix-socket daemons are reached via
  Req's `:unix_socket` option; TLS material on `:tcp` daemons is passed
  via `connect_options[:transport_opts]`. `ssh://` daemons are not
  supported by this module — both `request/4` and `stream/4` return
  `{:error, :ssh_not_supported_for_unary}`. Long-lived SSH-tunnelled
  streams use `Docker.Streaming` (OneOhOne) instead.

  ## Examples

      iex> {:ok, %{status: 200, body: "OK"}} = Docker.Client.request(:get, "/_ping")

      iex> {:ok, events} =
      ...>   Docker.Client.stream(
      ...>     :post, "/images/create?fromImage=alpine", nil,
      ...>     into: :ndjson
      ...>   )
      iex> events |> Enum.take(1) |> hd() |> Map.has_key?("status")
      true
  """

  # Abstraction Function:
  #   Stateless façade. Maps Docker-shaped (method, path, body, options) to
  #   Req-shaped requests and back.
  #
  # Data Invariant:
  #   1. Every call resolves a Docker.Endpoint before any I/O.
  #   2. The path passed to Req starts with /v<digits> exactly when this
  #      module prepended it OR the caller already supplied it.
  #   3. Frame post-processing runs only on 2xx responses; non-2xx bodies
  #      pass through unchanged.

  alias Docker.Endpoint, as: EngineEndpoint
  alias Docker.Frame
  alias Docker.NDJSON
  alias OneOhOne.Endpoint, as: MintyEndpoint

  @type method :: :get | :post | :put | :delete | :patch | :head | :options
  @type body :: nil | binary() | iodata() | {:json, term()} | {:tar, binary()}
  @type into :: :auto | :json | :ndjson | :raw | :frame
  @type response :: %{status: integer(), body: term(), headers: list()}

  @doc """
  Sends one HTTP request to the Docker daemon and waits for the full response.

  `path` — If it does not begin with `/v<digit>`, the resolved Engine
  API version is prepended automatically.

  `options[:registry_auth]` is sent as the `X-Registry-Auth` header.

  `options[:into] == :frame` runs the 2xx body through
  `Docker.Frame.demux_all/1`. Non-2xx bodies pass through
  unchanged.

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
        case minty(engine_endpoint) do
          %MintyEndpoint{transport: :ssh} -> {:error, :ssh_not_supported_for_unary}
          _ -> do_request(method, path, body, engine_endpoint, options)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Sends one HTTP request and returns an Elixir `Stream` of events.

  Same as `request/4` plus an `Enumerable.t()` body. When
  `options[:into]` is `:frame`, the stream yields
  `{:stdout, binary} | {:stderr, binary}` events as each frame's
  payload completes; when it is `:ndjson` (the default for streams),
  the stream yields one decoded JSON map per line.

  Halting the stream (e.g. `Stream.take/2`) cancels the in-flight HTTP
  request.

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
        case minty(engine_endpoint) do
          %MintyEndpoint{transport: :ssh} -> {:error, :ssh_not_supported_for_unary}
          _ -> do_stream(method, path, body, engine_endpoint, options)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # request/4
  # ---------------------------------------------------------------------------

  defp do_request(method, path, body, engine_endpoint, options) do
    full_path = prepend_version(path, engine_endpoint, options)
    into_mode = Keyword.get(options, :into, :auto)
    req_opts = build_req_opts(engine_endpoint, method, full_path, body, options, into_mode)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: response_body, headers: headers}} ->
        response = %{
          status: status,
          body: maybe_demux_body(response_body, status, into_mode),
          headers: normalize_headers(headers)
        }

        if status in 200..299 do
          {:ok, response}
        else
          {:error, response}
        end

      {:error, %{__exception__: true} = exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp maybe_demux_body(body, status, :frame) when is_binary(body) and status in 200..299,
    do: Frame.demux_all(body)

  defp maybe_demux_body(body, _status, _into), do: body

  # ---------------------------------------------------------------------------
  # stream/4
  # ---------------------------------------------------------------------------

  defp do_stream(method, path, body, engine_endpoint, options) do
    full_path = prepend_version(path, engine_endpoint, options)
    into_mode = Keyword.get(options, :into, :ndjson)
    req_opts = build_req_opts(engine_endpoint, method, full_path, body, options, into_mode)

    stream_opts = Keyword.put(req_opts, :into, :self)

    case Req.request(stream_opts) do
      {:ok, %Req.Response{status: status, body: %Req.Response.Async{}} = resp}
      when status in 200..299 ->
        {:ok, build_event_stream(resp, into_mode)}

      {:ok, %Req.Response{status: status, body: %Req.Response.Async{}} = resp} ->
        body = drain_async_body(resp)
        Req.cancel_async_response(resp)

        {:error,
         %{
           status: status,
           body: body,
           headers: normalize_headers(resp.headers)
         }}

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        response = %{status: status, body: body, headers: normalize_headers(headers)}
        if status in 200..299, do: {:ok, response}, else: {:error, response}

      {:error, %{__exception__: true} = exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp drain_async_body(%Req.Response{body: %Req.Response.Async{ref: ref}} = resp) do
    drain_async_body_loop(resp, ref, [])
  end

  defp drain_async_body_loop(resp, ref, acc) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, [{:data, data}]} -> drain_async_body_loop(resp, ref, [acc, data])
          {:ok, [:done]} -> IO.iodata_to_binary(acc)
          {:ok, _} -> drain_async_body_loop(resp, ref, acc)
          {:error, _} -> IO.iodata_to_binary(acc)
          :unknown -> drain_async_body_loop(resp, ref, acc)
        end
    after
      5_000 -> IO.iodata_to_binary(acc)
    end
  end

  defp build_event_stream(%Req.Response{body: %Req.Response.Async{ref: ref}} = resp, into_mode) do
    Stream.resource(
      fn -> {resp, ref, init_decoder(into_mode), false} end,
      &next_event(&1, into_mode),
      &after_event_stream/1
    )
  end

  defp init_decoder(:frame), do: ""
  defp init_decoder(:ndjson), do: ""
  defp init_decoder(:raw), do: nil
  defp init_decoder(_), do: ""

  defp next_event({_resp, _ref, _decoder, true} = state, _into_mode) do
    {:halt, state}
  end

  defp next_event({resp, ref, decoder, false} = state, into_mode) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, [{:data, chunk}]} ->
            {events, new_decoder} = decode_events(chunk, decoder, into_mode)
            {events, {resp, ref, new_decoder, false}}

          {:ok, [:done]} ->
            {:halt, {resp, ref, decoder, true}}

          {:ok, _other} ->
            {[], {resp, ref, decoder, false}}

          {:error, _reason} ->
            {:halt, {resp, ref, decoder, true}}

          :unknown ->
            {[], state}
        end
    after
      60_000 -> {:halt, {resp, ref, decoder, true}}
    end
  end

  defp after_event_stream({resp, ref, _decoder, done?}) do
    unless done? do
      _ = Req.cancel_async_response(resp)
    end

    drain_ref(ref)
    :ok
  end

  defp drain_ref(ref) do
    receive do
      {^ref, _} -> drain_ref(ref)
    after
      0 -> :ok
    end
  end

  defp decode_events(chunk, buffer, :frame) do
    Frame.decode_chunk(chunk, buffer)
  end

  defp decode_events(chunk, buffer, :ndjson) do
    NDJSON.decode_chunk(chunk, buffer)
  end

  defp decode_events(chunk, buffer, :raw), do: {[chunk], buffer}

  defp decode_events(chunk, buffer, _other) do
    NDJSON.decode_chunk(chunk, buffer)
  end

  # ---------------------------------------------------------------------------
  # Req option building
  # ---------------------------------------------------------------------------

  defp build_req_opts(engine_endpoint, method, full_path, body, options, into_mode) do
    minty = minty(engine_endpoint)

    base_opts =
      [
        method: method,
        url: url_for(minty, full_path),
        retry: false,
        decode_body: into_mode in [:auto, :json]
      ]
      |> Keyword.merge(transport_opts_for(minty))
      |> Keyword.merge(body_opts(body))
      |> Keyword.merge(headers_opt(options))

    case Keyword.get(options, :receive_timeout) do
      nil -> base_opts
      :infinity -> Keyword.put(base_opts, :receive_timeout, :infinity)
      ms when is_integer(ms) -> Keyword.put(base_opts, :receive_timeout, ms)
    end
  end

  defp url_for(%MintyEndpoint{transport: :unix}, full_path), do: "http://localhost" <> full_path

  defp url_for(%MintyEndpoint{transport: :tcp, scheme: scheme, host: host, port: port}, full_path) do
    scheme_str = if scheme === :https, do: "https", else: "http"
    "#{scheme_str}://#{host}:#{port}#{full_path}"
  end

  defp transport_opts_for(%MintyEndpoint{transport: :unix, socket_path: path}),
    do: [unix_socket: path]

  defp transport_opts_for(%MintyEndpoint{transport: :tcp, tls: nil}), do: []

  defp transport_opts_for(%MintyEndpoint{transport: :tcp, tls: tls}) when is_map(tls) do
    candidates = [
      verify: tls[:verify],
      cacertfile: tls[:cacertfile],
      certfile: tls[:certfile],
      keyfile: tls[:keyfile]
    ]

    transport_opts = Enum.reject(candidates, fn {_, v} -> is_nil(v) end)

    [connect_options: [transport_opts: transport_opts]]
  end

  defp body_opts(nil), do: []
  defp body_opts({:json, payload}), do: [json: payload]

  defp body_opts({:tar, tar}) when is_binary(tar) do
    [body: tar, headers: [{"content-type", "application/x-tar"}]]
  end

  defp body_opts(body) when is_binary(body), do: [body: body]
  defp body_opts(body), do: [body: body]

  defp headers_opt(options) do
    caller_headers = Keyword.get(options, :headers, [])

    headers =
      case Keyword.get(options, :registry_auth) do
        value when is_binary(value) -> caller_headers ++ [{"x-registry-auth", value}]
        _other -> caller_headers
      end

    if headers === [] do
      []
    else
      [headers: headers]
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn
      {k, [v]} -> {k, v}
      {k, values} when is_list(values) -> {k, Enum.join(values, ",")}
      {k, v} when is_binary(v) -> {k, v}
      {k, v} -> {k, to_string(v)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Path / version prefix
  # ---------------------------------------------------------------------------

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

  defp minty(engine_endpoint), do: EngineEndpoint.to_minty(engine_endpoint)
end
