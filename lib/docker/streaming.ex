defmodule Docker.Streaming do
  @moduledoc """
  Long-lived bidirectional sessions against the Docker Engine.

  Unlike the request/reply endpoints in `Docker`, sessions opened
  through this module stay open after the HTTP response and become
  a raw two-way pipe carrying the inner process's stdin, stdout,
  and stderr.

  ## Responsibilities

    - Open an attach session against a running container.
    - Open an exec-start session against an exec instance.
    - Resolve a `Docker.Endpoint` from caller options and pass
      its underlying `OneOhOne.Endpoint` through to `OneOhOne.start_link/2`.

  ## Examples

      iex> {:ok, session} = Docker.Streaming.open_attach("my-container", false, [])
      iex> Docker.Streaming.Session.send(session, "ls\\n")
      iex> {:ok, _output, _session} =
      ...>   Docker.Streaming.Session.recv(session, {:idle_timeout, 200})

  """

  alias Docker.Endpoint
  alias Docker.Streaming.Session
  alias Docker.Streaming.SessionHandler

  @doc """
  Returns a streaming session attached to a running container's stdio.
  """
  @spec open_attach(container_ref :: binary(), tty :: boolean(), opts :: keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def open_attach(container_ref, tty, opts)
      when is_binary(container_ref) and is_boolean(tty) and is_list(opts) do
    with {:ok, engine_endpoint} <- Endpoint.from_options(opts) do
      path = build_attach_path(container_ref, engine_endpoint, opts)
      open_upgrade(engine_endpoint, :post, path, "", tty, opts)
    end
  end

  @doc """
  Returns a streaming session driving an exec instance's stdio.
  """
  @spec open_exec_start(exec_id :: binary(), tty :: boolean(), opts :: keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def open_exec_start(exec_id, tty, opts)
      when is_binary(exec_id) and is_boolean(tty) and is_list(opts) do
    with {:ok, engine_endpoint} <- Endpoint.from_options(opts) do
      encoder = opts[:json][:protocol_encode] || (&JSON.protocol_encode/2)
      body = JSON.encode!(%{"Detach" => false, "Tty" => tty}, encoder)
      path = "/v#{Endpoint.version(engine_endpoint)}/exec/#{exec_id}/start"
      open_upgrade(engine_endpoint, :post, path, body, tty, opts)
    end
  end

  defp open_upgrade(engine_endpoint, method, path, body, tty, _opts) do
    minty = Endpoint.to_minty(engine_endpoint)

    upgrade = %{
      method: method,
      path: path,
      body: body
    }

    start_opts = [
      endpoint: minty,
      upgrade: upgrade,
      params: %{owner: self()}
    ]

    case OneOhOne.start_link(SessionHandler, start_opts) do
      {:ok, conn_pid} ->
        {:ok, Session.from_connection(conn_pid, tty)}

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
