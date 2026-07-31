defmodule Docker.StreamError do
  @moduledoc """
  Raised from inside a `Docker.Client.stream/4` enumerable when the
  underlying HTTP response fails or stalls part-way through.

  `stream/4` returns `{:ok, stream}` as soon as the daemon answers with a
  2xx status, so a failure that happens while the body is still arriving
  has no return value left to travel through. Raising is the only way the
  consumer can tell a truncated stream from a complete one.

  The failure is carried by `:message` alone: raise with
  `reason: term` and the term is rendered into the message text.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}

  @impl true
  def exception(opts) do
    %__MODULE__{message: opts |> Keyword.fetch!(:reason) |> describe()}
  end

  defp describe(:timeout),
    do: "Docker stream stalled: no data received within the idle timeout"

  defp describe(reason),
    do: "Docker stream failed: #{inspect(reason)}"
end
