defmodule Docker.Session do
  @moduledoc """
  Bidirectional streaming sessions against a Docker container or exec
  instance.

  See `Docker` for the full client overview. Every function in this module
  is also exposed on the `Docker` facade (e.g. `Docker.attach/2`).
  """

  alias Docker.Streaming
  alias Docker.Streaming.Session

  @doc """
  Opens a bidirectional session attached to a running container's stdio.
  """
  @spec attach(Docker.container_ref(), Docker.options()) :: Docker.result(Session.t())
  def attach(container_ref, options \\ []) when is_binary(container_ref) do
    with {:ok, tty} <- resolve_attach_tty(container_ref, options) do
      Streaming.open_attach(container_ref, tty, options)
    end
  end

  @doc """
  Creates an exec instance with stdin attached and starts it as an upgraded
  session.
  """
  @spec exec_session(Docker.container_ref(), [binary()], Docker.options()) ::
          Docker.result(Session.t())
  def exec_session(container_ref, cmd, options \\ []) when is_list(cmd) do
    with {:ok, session, _exec_id} <- exec_session_with_id(container_ref, cmd, options) do
      {:ok, session}
    end
  end

  @doc """
  Like `exec_session/3`, but also returns the exec instance id so callers
  can drive control-plane operations (e.g. TTY resize) alongside the
  streaming session.
  """
  @spec exec_session_with_id(Docker.container_ref(), [binary()], Docker.options()) ::
          {:ok, Docker.Streaming.Session.t(), binary()} | {:error, term()}
  def exec_session_with_id(container_ref, cmd, options \\ []) when is_list(cmd) do
    tty = Keyword.get(options, :tty, false)
    create_options = options |> Keyword.put(:attach_stdin, true) |> Keyword.put(:tty, tty)

    with {:ok, exec_id} <- Docker.Exec.exec_create(container_ref, cmd, create_options),
         {:ok, session} <- Streaming.open_exec_start(exec_id, tty, options) do
      {:ok, session, exec_id}
    end
  end

  @doc """
  One-shot helper: attach to the container, write `message`, read until the
  termination condition fires, close the session.
  """
  @spec send_message(
          Docker.container_ref(),
          iodata(),
          Session.recv_mode(),
          Docker.options()
        ) :: {:ok, binary()} | {:ok, {binary(), binary()}} | {:error, Docker.error_reason()}
  def send_message(container_ref, message, mode, options \\ []) do
    with {:ok, session} <- attach(container_ref, options) do
      run_send_message(session, message, mode, options)
    end
  end

  defp run_send_message(session, message, mode, options) do
    with :ok <- Session.send(session, message),
         {:ok, output, _session} <- Session.recv(session, mode, options) do
      {:ok, output}
    else
      {:error, reason, _session} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  after
    Session.close(session)
  end

  defp resolve_attach_tty(container_ref, options) do
    case Keyword.fetch(options, :tty) do
      {:ok, tty} when is_boolean(tty) ->
        {:ok, tty}

      :error ->
        case Docker.Container.find_container(container_ref, options) do
          {:ok, %{"Config" => %{"Tty" => tty}}} when is_boolean(tty) -> {:ok, tty}
          {:ok, _info} -> {:ok, false}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
