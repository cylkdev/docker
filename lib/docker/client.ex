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

  Internally, every call delegates to `Req.request/1`, reaching the daemon
  over Req's `:unix_socket` option at `Docker.Config.socket_path/0`.

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
  #   1. The path passed to Req starts with /v<digits> exactly when this
  #      module prepended it OR the caller already supplied it.
  #   2. Frame post-processing runs only on 2xx responses; non-2xx bodies
  #      pass through unchanged.
  #   3. Every {:error, _} leaving this module carries an ErrorMessage. This
  #      is the only place in the library that maps an HTTP status to an
  #      error code, so callers pass failures through untouched.

  alias Docker.Config
  alias Docker.Frame
  alias Docker.NDJSON

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
    * `{:error, error}` — Status was outside 200..299, or the transport
      failed. `error` is an `t:ErrorMessage.t/0` whose `:code` is derived
      from the status (404 becomes `:not_found`) and whose `:details`
      carry `:status`, `:body`, `:method`, and `:path`.
  """
  @spec request(method(), String.t(), body(), keyword()) ::
          {:ok, response()} | {:error, ErrorMessage.t()}
  def request(method, path, body \\ nil, options \\ []) do
    do_request(method, path, body, options)
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
    * `{:error, error}` — Non-2xx status (body fully read into `:details`),
      or the transport failed. `error` is an `t:ErrorMessage.t/0`.

  A failure that happens *after* this function has returned `{:ok, stream}` —
  a truncated or stalled body — has no return value left to travel through
  and is raised as a `Docker.StreamError` from inside the enumerable.
  """
  @spec stream(method(), String.t(), body(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, ErrorMessage.t()}
  def stream(method, path, body \\ nil, options \\ []) do
    do_stream(method, path, body, options)
  end

  # ---------------------------------------------------------------------------
  # request/4
  # ---------------------------------------------------------------------------

  defp do_request(method, path, body, options) do
    full_path = prepend_version(path, options)
    into_mode = Keyword.get(options, :into, :auto)
    req_opts = build_req_opts(method, full_path, body, options, into_mode)

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
          {:error, response_error(response, method, full_path)}
        end

      {:error, %{__exception__: true} = exception} ->
        {:error, transport_error(exception, method, full_path)}
    end
  end

  defp maybe_demux_body(body, status, :frame) when is_binary(body) and status in 200..299,
    do: Frame.demux_all(body)

  defp maybe_demux_body(body, _status, _into), do: body

  # ---------------------------------------------------------------------------
  # stream/4
  # ---------------------------------------------------------------------------

  defp do_stream(method, path, body, options) do
    full_path = prepend_version(path, options)
    into_mode = Keyword.get(options, :into, :ndjson)
    req_opts = build_req_opts(method, full_path, body, options, into_mode)

    stream_opts = Keyword.put(req_opts, :into, :self)

    case Req.request(stream_opts) do
      {:ok, %Req.Response{status: status, body: %Req.Response.Async{}} = resp}
      when status in 200..299 ->
        {:ok, build_event_stream(resp, into_mode)}

      {:ok, %Req.Response{status: status, body: %Req.Response.Async{}} = resp} ->
        body = drain_async_body(resp)
        Req.cancel_async_response(resp)

        response = %{status: status, body: body, headers: normalize_headers(resp.headers)}

        {:error, response_error(response, method, full_path)}

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        response = %{status: status, body: body, headers: normalize_headers(headers)}

        if status in 200..299 do
          {:ok, response}
        else
          {:error, response_error(response, method, full_path)}
        end

      {:error, %{__exception__: true} = exception} ->
        {:error, transport_error(exception, method, full_path)}
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
          {:ok, [{:trailers, _trailers}]} -> drain_async_body_loop(resp, ref, acc)
          {:error, reason} -> raise Docker.StreamError, reason: reason
          :unknown -> drain_async_body_loop(resp, ref, acc)
        end
    after
      # A partial error body is better than hanging: this drain only ever
      # runs to populate the body of an already-failed (non-2xx) response.
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

          {:ok, [{:trailers, _trailers}]} ->
            {[], {resp, ref, decoder, false}}

          {:error, reason} ->
            raise Docker.StreamError, reason: reason

          # Req replies :unknown for messages belonging to another request.
          :unknown ->
            {[], state}
        end
    after
      60_000 -> raise Docker.StreamError, reason: :timeout
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

  defp build_req_opts(method, full_path, body, options, into_mode) do
    base_opts =
      [
        method: method,
        url: "http://localhost" <> full_path,
        unix_socket: Config.socket_path(),
        retry: false,
        decode_body: into_mode in [:auto, :json]
      ]
      |> Keyword.merge(body_opts(body))
      |> Keyword.merge(headers_opt(options))

    case Keyword.get(options, :receive_timeout) do
      nil -> base_opts
      :infinity -> Keyword.put(base_opts, :receive_timeout, :infinity)
      ms when is_integer(ms) -> Keyword.put(base_opts, :receive_timeout, ms)
    end
  end

  defp body_opts(nil), do: []
  defp body_opts({:json, payload}), do: [json: payload]

  defp body_opts({:tar, tar}) when is_binary(tar) do
    [body: tar, headers: [{"content-type", "application/x-tar"}]]
  end

  defp body_opts(body) when is_binary(body) or is_list(body), do: [body: body]

  defp headers_opt(options) do
    caller_headers = Keyword.get(options, :headers, [])

    headers =
      case Keyword.get(options, :registry_auth) do
        nil -> caller_headers
        value when is_binary(value) -> caller_headers ++ [{"x-registry-auth", value}]
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
    end)
  end

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  # Every non-2xx daemon response becomes an ErrorMessage here, so no caller
  # further up ever has to derive a code from a status. `:path` carries the
  # container/image/network ref the call was about, so the error says what
  # failed and not merely that something did.
  @spec response_error(response(), method(), String.t()) :: ErrorMessage.t()
  defp response_error(%{status: status, body: body}, method, path) do
    apply(ErrorMessage, status_code(status), [
      daemon_message(body, status),
      %{status: status, body: body, method: method, path: path}
    ])
  end

  @spec transport_error(Exception.t(), method(), String.t()) :: ErrorMessage.t()
  defp transport_error(exception, method, path) do
    {code, message} = classify_transport(exception)

    apply(ErrorMessage, code, [
      message,
      %{reason: exception, method: method, path: path, socket_path: Config.socket_path()}
    ])
  end

  # Req wraps the POSIX reason; the reason is what distinguishes "Docker isn't
  # running" from "the daemon hung up mid-request", and both are worth telling
  # apart at the call site.
  defp classify_transport(%{reason: reason}) when reason in [:timeout, :etimedout] do
    {:gateway_timeout, "Timed out waiting for the Docker daemon"}
  end

  defp classify_transport(%{reason: reason}) when reason in [:eacces, :eperm] do
    {:forbidden,
     "Permission denied opening the Docker socket at #{Config.socket_path()}. " <>
       "Check that the current user may access it."}
  end

  defp classify_transport(%{reason: reason}) when reason in [:econnrefused, :enoent] do
    {:service_unavailable,
     "Could not reach the Docker daemon at #{Config.socket_path()}. " <>
       "Check that Docker is running."}
  end

  defp classify_transport(%{reason: reason}) when reason in [:closed, :econnreset, :epipe] do
    {:bad_gateway, "The connection to the Docker daemon closed unexpectedly"}
  end

  # Everything above carries a POSIX reason, so it really was the connection.
  # What is left is an exception raised while processing a response the daemon
  # did send — a body that would not decode, most often — which is a bad
  # upstream reply rather than an unreachable daemon.
  defp classify_transport(exception) do
    {:bad_gateway,
     "The Docker daemon returned a response this client could not read: " <>
       Exception.message(exception)}
  end

  # `ErrorMessage.http_code_reason_atom/1` delegates to `Plug.Conn.Status`,
  # which raises for codes outside its table and answers 2xx codes with names
  # ErrorMessage has no constructor for. Neither may escape the error path.
  @spec status_code(integer()) :: ErrorMessage.code()
  defp status_code(status) do
    atom = ErrorMessage.http_code_reason_atom(status)

    if function_exported?(ErrorMessage, atom, 2), do: atom, else: fallback_code(status)
  rescue
    ArgumentError -> fallback_code(status)
  end

  defp fallback_code(status) when status in 300..499, do: :bad_request
  defp fallback_code(_status), do: :internal_server_error

  # The Engine API puts its human-readable text at `body["message"]`.
  defp daemon_message(%{"message" => message}, status) when is_binary(message) do
    presence(message) || generic_message(status)
  end

  # `stream/4` drains error bodies as raw bytes rather than decoding them, so
  # the same 404 that `request/4` hands over as a map arrives here as JSON
  # text. Both paths should produce the same message.
  defp daemon_message(body, status) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) ->
        presence(message) || generic_message(status)

      _not_a_daemon_error_body ->
        presence(body) || generic_message(status)
    end
  end

  defp daemon_message(_body, status), do: generic_message(status)

  defp presence(string) do
    case String.trim(string) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp generic_message(status), do: "The Docker daemon responded with HTTP #{status}"

  # ---------------------------------------------------------------------------
  # Path / version prefix
  # ---------------------------------------------------------------------------

  @spec prepend_version(String.t(), keyword()) :: String.t()
  defp prepend_version(path, options) do
    if Regex.match?(~r{^/v\d}, path) do
      path
    else
      version =
        case Keyword.get(options, :version) do
          nil -> Config.version()
          v when is_binary(v) and v !== "" -> v
        end

      "/v" <> version <> path
    end
  end
end
