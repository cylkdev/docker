defmodule Docker.Engine.Streaming do
  @moduledoc """
  Long-lived bidirectional sessions against the Docker Engine.

  Unlike the request/reply endpoints in `Docker`, sessions opened
  through this module stay open after the HTTP response and become
  a raw two-way pipe carrying the inner process's stdin, stdout,
  and stderr.

  ## Responsibilities

    - Open an attach session against a running container.
    - Open an exec-start session against an exec instance.
    - Resolve a `Docker.Engine.Endpoint` from caller options and pass
      its underlying `Sorrel.Endpoint` through to
      `Sorrel.tunnel/5`.

  ## Examples

      iex> {:ok, session} = Docker.Engine.Streaming.open_attach("my-container", false, [])
      iex> :ok = Docker.Engine.Streaming.Session.send(session, "ls\\n")
      iex> {:ok, _output, _session} =
      ...>   Docker.Engine.Streaming.Session.recv(session, {:idle_timeout, 200})

  """

  alias Docker.Engine.Endpoint
  alias Docker.Engine.Streaming.Session
  alias Sorrel

  @doc """
  Returns a streaming session attached to a running container's
  stdio.

  ## Parameters

    - `container_ref` - `binary()`. Container ID or name.
    - `tty` - `boolean()`. Whether the container was started with a PTY.
      Determines whether the session demuxes Docker's multiplexed stream
      framing (`false`) or treats output as a raw byte stream (`true`).
    - `opts` - `keyword()`. Connection options:
        - `:endpoint` - a `Docker.Engine.Endpoint` or `Sorrel.Endpoint`. Overrides resolution.
        - `:host` - a Docker daemon URL (`tcp://...`, `https://...`, `unix://...`).
        - `:socket` - shortcut for unix socket path.
        - `:tls` - TLS material map.
        - `:version` - override Docker API version (defaults to `Docker.Engine.Endpoint.from_options/1` resolution).
        - `:stdin`, `:stdout`, `:stderr` - default `true`.
        - `:connect_timeout`, `:receive_timeout` - default `10_000` ms.

  ## Returns

  `{:ok, Docker.Engine.Streaming.Session.t()}` on success. The returned
  session is open and ready for `Docker.Engine.Streaming.Session.send/2`
  and `Docker.Engine.Streaming.Session.recv/3`. The returned value
  satisfies the session module's data invariant.

  Returns `{:error, reason}` if the endpoint cannot be resolved, the
  daemon cannot be reached, the upgrade handshake fails, or the
  daemon returns a status other than 101 or 200.

  ## Examples

      # Attach to a non-tty container
      iex> {:ok, session} = Docker.Engine.Streaming.open_attach("my-container", false, [])
      iex> Docker.Engine.Streaming.Session.close(session)
      :ok

  """
  @spec open_attach(container_ref :: binary(), tty :: boolean(), opts :: keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def open_attach(container_ref, tty, opts)
      when is_binary(container_ref) and is_boolean(tty) and is_list(opts) do
    case Endpoint.from_options(opts) do
      {:ok, engine_endpoint} ->
        minty_endpoint = Endpoint.to_minty(engine_endpoint)
        path = build_attach_path(container_ref, engine_endpoint, opts)
        upgrade_opts = Keyword.delete(opts, :endpoint)

        case Sorrel.tunnel(minty_endpoint, :post, path, "", upgrade_opts) do
          {:ok, socket, leftover} ->
            {:ok, Session.from_upgrade(socket, leftover, tty)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a streaming session driving an exec instance's stdio.

  ## Parameters

    - `exec_id` - `binary()`. Exec instance ID returned by
      `Docker.exec_create/3`.
    - `tty` - `boolean()`. Must match the `Tty` value passed to
      `exec_create`. Determines whether the session demuxes
      multiplexed stream framing.
    - `opts` - `keyword()`. Connection options. Same shape as
      `open_attach/3`.

  ## Returns

  `{:ok, Docker.Engine.Streaming.Session.t()}` on success. The returned
  value satisfies the session module's data invariant.

  Returns `{:error, reason}` if the endpoint cannot be resolved, the
  daemon cannot be reached, the upgrade handshake fails, or the
  daemon returns a status other than 101 or 200.

  ## Examples

      # Drive an exec instance with stdin attached
      iex> {:ok, exec_id} =
      ...>   Docker.exec_create("my-container", ["cat"], attach_stdin: true)
      iex> {:ok, session} = Docker.Engine.Streaming.open_exec_start(exec_id, false, [])
      iex> Docker.Engine.Streaming.Session.close(session)
      :ok

  """
  @spec open_exec_start(exec_id :: binary(), tty :: boolean(), opts :: keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def open_exec_start(exec_id, tty, opts)
      when is_binary(exec_id) and is_boolean(tty) and is_list(opts) do
    case Endpoint.from_options(opts) do
      {:ok, engine_endpoint} ->
        minty_endpoint = Endpoint.to_minty(engine_endpoint)
        encoder = opts[:json][:protocol_encode] || (&JSON.protocol_encode/2)
        body = JSON.encode!(%{"Detach" => false, "Tty" => tty}, encoder)
        path = "/v#{Endpoint.version(engine_endpoint)}/exec/#{exec_id}/start"
        upgrade_opts = Keyword.delete(opts, :endpoint)

        case Sorrel.tunnel(minty_endpoint, :post, path, body, upgrade_opts) do
          {:ok, socket, leftover} ->
            {:ok, Session.from_upgrade(socket, leftover, tty)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_attach_path(binary(), Endpoint.t(), keyword()) :: String.t()
  defp build_attach_path(container_ref, %Endpoint{} = engine_endpoint, opts) do
    version = Endpoint.version(engine_endpoint)

    query =
      URI.encode_query(%{
        stream: "1",
        stdin: bool_param(Keyword.get(opts, :stdin, true)),
        stdout: bool_param(Keyword.get(opts, :stdout, true)),
        stderr: bool_param(Keyword.get(opts, :stderr, true))
      })

    "/v#{version}/containers/#{container_ref}/attach?#{query}"
  end

  @spec bool_param(boolean()) :: String.t()
  defp bool_param(true), do: "1"
  defp bool_param(false), do: "0"
end
