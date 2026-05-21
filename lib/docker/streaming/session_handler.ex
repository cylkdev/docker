defmodule Docker.Streaming.SessionHandler do
  @moduledoc """
  `OneOhOne.Handler` implementation that forwards every byte of an
  upgraded Docker stream to a designated owner pid.

  `Docker.Streaming.Session.recv/3` is pull-based (idle-timeout
  or read-until-delimiter), while `OneOhOne` is push-based (handler
  callbacks). This module bridges the two by relaying handler events
  as Erlang messages to the owner process. The owner — the same
  process that called `Docker.attach/2`, `Docker.exec_session/3`, or
  `Docker.send_message/4` — drains those messages from its mailbox
  during `Session.recv/3`.

  ## Message protocol

  Every message uses the connection pid as its second element so an
  owner can demultiplex bytes from multiple concurrent sessions:

    * `{:docker_stream, conn_pid, :data, bytes}` — bytes arrived
      from the daemon. Already past any HTTP framing.
    * `{:docker_stream, conn_pid, :closed}` — the connection was
      closed (by the daemon or by `OneOhOne.close/1`).

  The handler stores the owner pid in `socket.assigns[:owner]` so it
  is available to every callback without re-reading params.
  """

  use OneOhOne.Handler

  alias OneOhOne.Socket

  @logger_prefix "Docker.Streaming.SessionHandler"

  @impl true
  def connect(%{owner: owner}, %Socket{} = socket) when is_pid(owner) do
    Docker.Log.debug(@logger_prefix, "Connecting session | owner=#{inspect(owner)}")
    {:ok, OneOhOne.assign(socket, :owner, owner)}
  end

  def connect(_params, %Socket{} = socket) do
    Docker.Log.warning(@logger_prefix, "Connecting session without owner")
    {:ok, socket}
  end

  @impl true
  def handle_in(bytes, %Socket{transport_pid: transport_pid} = socket) when is_binary(bytes) do
    Docker.Log.debug(
      @logger_prefix,
      "Handling incoming data | transport_pid=#{inspect(transport_pid)}, bytes_size=#{byte_size(bytes)}"
    )

    forward(socket, {:docker_stream, transport_pid, :data, bytes})
    {:ok, socket}
  end

  @impl true
  def terminate(_reason, %Socket{transport_pid: transport_pid} = socket) do
    Docker.Log.debug(
      @logger_prefix,
      "Terminating session | transport_pid=#{inspect(transport_pid)}"
    )

    forward(socket, {:docker_stream, transport_pid, :closed})
    :ok
  end

  defp forward(%Socket{assigns: %{owner: owner}}, message) when is_pid(owner) do
    Docker.Log.debug(
      @logger_prefix,
      "Forwarding message | owner=#{inspect(owner)}, message=#{inspect(message)}"
    )

    if Process.alive?(owner) do
      send(owner, message)
      Docker.Log.debug(@logger_prefix, "Message sent to owner: #{inspect(owner)}")
    else
      Docker.Log.warning(
        @logger_prefix,
        "Unable to forward message. Owner process #{inspect(owner)} is not alive."
      )
    end

    :ok
  end

  defp forward(%Socket{} = socket, _message) do
    Docker.Log.error(@logger_prefix, "No owner assigned to forward message")
    Docker.Log.error(@logger_prefix, "Socket assigns: #{inspect(socket.assigns)}")
    :ok
  end
end
