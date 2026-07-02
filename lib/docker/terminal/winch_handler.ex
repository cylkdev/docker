defmodule Docker.Terminal.WinchHandler do
  @moduledoc """
  A `:gen_event` handler installed on `:erl_signal_server` that forwards each
  `:sigwinch` (terminal window resize) to an owner process as `{:winch}`.
  """
  @behaviour :gen_event

  @impl :gen_event
  def init(owner), do: {:ok, owner}

  @impl :gen_event
  def handle_event(:sigwinch, owner) do
    send(owner, {:winch})
    {:ok, owner}
  end

  def handle_event(_other, owner), do: {:ok, owner}

  @impl :gen_event
  def handle_call(_request, owner), do: {:ok, :ok, owner}

  @impl :gen_event
  def handle_info(_msg, owner), do: {:ok, owner}
end
