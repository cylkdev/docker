defmodule Docker.Terminal.RawMode do
  @moduledoc """
  Puts the local terminal (stdin, fd 0) into raw, no-echo mode and back, and
  reports its size — in-process via `Docker.Terminal.Termios`.
  """
  alias Docker.Terminal.Termios

  @stdin_fd 0
  @spec stdin_fd() :: 0
  def stdin_fd, do: @stdin_fd
  @spec enable() :: {:ok, binary()} | {:error, atom()}
  def enable, do: Termios.enable_raw(@stdin_fd)
  @spec restore(binary()) :: :ok | {:error, atom()}
  def restore(saved) when is_binary(saved), do: Termios.restore(@stdin_fd, saved)
  @spec size() :: {:ok, {pos_integer(), pos_integer()}} | {:error, atom()}
  def size, do: Termios.winsize(@stdin_fd)
end
