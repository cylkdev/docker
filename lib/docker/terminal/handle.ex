defmodule Docker.Terminal.Handle do
  @moduledoc """
  Control-plane context for an open interactive exec: the transport `stream`,
  the `exec_id` (for resize), and the daemon `opts` (for the control HTTP call).
  Kept out of `Docker.Streaming.Session`, which is pure transport.
  """
  alias Docker.Streaming.Session

  @type t :: %__MODULE__{stream: Session.t(), exec_id: binary() | nil, opts: keyword()}
  defstruct stream: nil, exec_id: nil, opts: []
end
