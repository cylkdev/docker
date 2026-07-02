defmodule Docker.Terminal.Termios do
  @moduledoc """
  Thin NIF over POSIX termios: put an fd's terminal into raw mode, restore it,
  and read its window size. Operates directly on the fd (kernel-level termios),
  independent of the VM's `user_drv` tty ownership.
  """
  @on_load :load_nif

  @spec load_nif() :: :ok | {:error, term()}
  def load_nif do
    path = :filename.join(:code.priv_dir(:docker), ~c"docker_termios")
    :erlang.load_nif(path, 0)
  end

  @spec enable_raw(non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def enable_raw(_fd), do: :erlang.nif_error(:nif_not_loaded)

  @spec restore(non_neg_integer(), binary()) :: :ok | {:error, atom()}
  def restore(_fd, _saved), do: :erlang.nif_error(:nif_not_loaded)

  @spec winsize(non_neg_integer()) :: {:ok, {pos_integer(), pos_integer()}} | {:error, atom()}
  def winsize(_fd), do: :erlang.nif_error(:nif_not_loaded)
end
