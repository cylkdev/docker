defmodule Docker.Terminal.Pty do
  @moduledoc """
  Bridges a raw local terminal (`:stdio`) to an open interactive exec. The
  calling process must be the stream owner (it called `Docker.Terminal.open_pty/2`).
  """
  alias Docker.Streaming.Session
  alias Docker.Terminal
  alias Docker.Terminal.{Handle, RawMode, WinchHandler}

  @spec handle_stream_message(term()) :: {:write, binary()} | :halt
  def handle_stream_message({:docker_stream, _pid, :data, bytes}), do: {:write, bytes}
  def handle_stream_message({:docker_stream, _pid, :closed}), do: :halt

  @spec forward_keystrokes(iodata(), Handle.t()) :: :ok | {:error, term()}
  def forward_keystrokes(bytes, %Handle{stream: %Session{} = s}), do: Session.send(s, bytes)

  @spec attach(Handle.t()) :: :ok
  def attach(%Handle{} = handle) do
    :ok = :io.setopts(:standard_io, binary: true)
    winch = install_winch(self())
    reader = spawn_link(fn -> read_loop(handle) end)

    result = recv_loop(handle)

    Process.exit(reader, :kill)
    uninstall_winch(winch)
    result
  end

  defp install_winch(owner) do
    h = {WinchHandler, make_ref()}
    :ok = :gen_event.add_handler(:erl_signal_server, h, owner)
    :os.set_signal(:sigwinch, :handle)
    h
  end

  defp uninstall_winch(h) do
    :gen_event.delete_handler(:erl_signal_server, h, [])
    :os.set_signal(:sigwinch, :default)
    :ok
  end

  defp recv_loop(handle) do
    receive do
      {:docker_stream, _pid, :closed} = msg ->
        :halt = handle_stream_message(msg)
        :ok

      {:docker_stream, _pid, :data, _bytes} = msg ->
        {:write, bytes} = handle_stream_message(msg)
        IO.binwrite(:stdio, bytes)
        recv_loop(handle)

      {:winch} ->
        on_winch(handle)
        recv_loop(handle)
    end
  end

  defp read_loop(handle) do
    case IO.binread(:stdio, 1) do
      :eof -> :ok
      {:error, _} -> :ok
      bytes -> forward_keystrokes(bytes, handle); read_loop(handle)
    end
  end

  @spec on_winch(Handle.t()) :: :ok
  def on_winch(%Handle{} = handle) do
    with {:ok, size} <- RawMode.size(), do: Terminal.resize(handle, size)
    :ok
  end
end
