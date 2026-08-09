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

  alias Docker.Client
  alias Docker.Streaming.Session
  alias Docker.Streaming.SessionHandler

  @doc """
  Returns a streaming session attached to a running container's stdio.
  """
  @spec open_attach(container_ref :: binary(), tty :: boolean(), opts :: keyword()) ::
          Docker.result(Session.t())
  def open_attach(container_ref, tty, opts) do
    open_upgrade(:post, build_attach_path(container_ref, opts), "", tty, opts)
  end

  @doc """
  Returns a streaming session driving an exec instance's stdio.
  """
  @spec open_exec_start(exec_id :: binary(), tty :: boolean(), opts :: keyword()) ::
          Docker.result(Session.t())
  def open_exec_start(exec_id, tty, opts) do
    body = JSON.encode!(%{"Detach" => false, "Tty" => tty})
    path = "/v#{Keyword.get(opts, :version, Client.default_version())}/exec/#{exec_id}/start"

    open_upgrade(:post, path, body, tty, opts)
  end

  # `OneOhOne` sends only `host` and `content-length` for us; the upgrade
  # headers the Engine API expects have to come from the caller.
  defp open_upgrade(method, path, body, tty, opts) do
    socket_path = Keyword.get(opts, :socket_path, Client.default_socket_path())

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
      endpoint: %OneOhOne.Endpoint{transport: :unix, socket_path: socket_path},
      upgrade: upgrade,
      params: %{owner: self()}
    ]

    case OneOhOne.start_link(SessionHandler, start_opts) do
      {:ok, conn_pid} ->
        {:ok, Session.from_connection(conn_pid, tty)}

      {:error, reason} ->
        {:error, upgrade_error(reason, path, opts)}
    end
  end

  # The upgrade never completed, so there is no HTTP status to read a code
  # from — only the reason OneOhOne failed with.
  defp upgrade_error(%ErrorMessage{} = error, _path, _opts), do: error

  defp upgrade_error({:shutdown, reason}, path, opts), do: upgrade_error(reason, path, opts)

  defp upgrade_error(reason, path, opts) when reason in [:enoent, :econnrefused] do
    socket_path = Keyword.get(opts, :socket_path, Client.default_socket_path())

    ErrorMessage.service_unavailable(
      "Could not reach the Docker daemon at #{socket_path}. " <>
        "Check that Docker is running.",
      %{reason: reason, path: path, socket_path: socket_path}
    )
  end

  defp upgrade_error(reason, path, opts) when reason in [:eacces, :eperm] do
    socket_path = Keyword.get(opts, :socket_path, Client.default_socket_path())

    ErrorMessage.forbidden(
      "Permission denied opening the Docker socket at #{socket_path}. " <>
        "Check that the current user may access it.",
      %{reason: reason, path: path, socket_path: socket_path}
    )
  end

  defp upgrade_error(reason, path, opts) do
    socket_path = Keyword.get(opts, :socket_path, Client.default_socket_path())

    ErrorMessage.bad_gateway(
      "Could not open a streaming session with the Docker daemon: #{inspect(reason)}",
      %{reason: reason, path: path, socket_path: socket_path}
    )
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

    "/v#{Keyword.get(opts, :version, Client.default_version())}/containers/#{container_ref}/attach?#{query}"
  end

  @spec bool_param(boolean()) :: String.t()
  defp bool_param(true), do: "1"
  defp bool_param(false), do: "0"
end
