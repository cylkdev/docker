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

  ## Examples

      iex> {:ok, session} = Docker.Streaming.open_attach("my-container", false, [])
      iex> Docker.Streaming.Session.send(session, "ls\\n")
      iex> {:ok, _output, _session} =
      ...>   Docker.Streaming.Session.recv(session, {:idle_timeout, 200})

  """

  alias Docker.Config
  alias Docker.Streaming.Session
  alias Docker.Streaming.SessionHandler

  @doc """
  Returns a streaming session attached to a running container's stdio.
  """
  @spec open_attach(container_ref :: binary(), tty :: boolean(), opts :: keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def open_attach(container_ref, tty, opts)
      when is_binary(container_ref) and is_boolean(tty) and is_list(opts) do
    open_upgrade(:post, build_attach_path(container_ref, opts), "", tty)
  end

  @doc """
  Returns a streaming session driving an exec instance's stdio.
  """
  @spec open_exec_start(exec_id :: binary(), tty :: boolean(), opts :: keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def open_exec_start(exec_id, tty, opts)
      when is_binary(exec_id) and is_boolean(tty) and is_list(opts) do
    body = JSON.encode!(%{"Detach" => false, "Tty" => tty})
    path = "/v#{Config.version()}/exec/#{exec_id}/start"

    open_upgrade(:post, path, body, tty)
  end

  # `OneOhOne` sends only `host` and `content-length` for us; the upgrade
  # headers the Engine API expects have to come from the caller.
  defp open_upgrade(method, path, body, tty) do
    upgrade = %{
      method: method,
      path: path,
      body: body,
      headers: [
        {"upgrade", "tcp"},
        {"connection", "Upgrade"},
        {"content-type", "application/json"}
      ]
    }

    start_opts = [
      endpoint: %OneOhOne.Endpoint{transport: :unix, socket_path: Config.socket_path()},
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

  @spec build_attach_path(binary(), keyword()) :: String.t()
  defp build_attach_path(container_ref, opts) do
    query =
      URI.encode_query(%{
        stream: "1",
        stdin: bool_param(Keyword.get(opts, :stdin, true)),
        stdout: bool_param(Keyword.get(opts, :stdout, true)),
        stderr: bool_param(Keyword.get(opts, :stderr, true))
      })

    "/v#{Config.version()}/containers/#{container_ref}/attach?#{query}"
  end

  @spec bool_param(boolean()) :: String.t()
  defp bool_param(true), do: "1"
  defp bool_param(false), do: "0"
end
