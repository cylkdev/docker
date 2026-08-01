defmodule Docker.StreamError do
  @moduledoc """
  Raised from inside a `Docker.Client.stream/4` enumerable when the
  underlying HTTP response fails or stalls part-way through.

  `stream/4` returns `{:ok, stream}` as soon as the daemon answers with a
  2xx status, so a failure that happens while the body is still arriving
  has no return value left to travel through. Raising is the only way the
  consumer can tell a truncated stream from a complete one.

  This is the one place in the library where a failure is not returned as
  `{:error, ErrorMessage.t()}`. The `:error_message` field carries the same
  struct the return path would have, so a caller that rescues can go back to
  handling failures uniformly:

      try do
        Enum.to_list(stream)
      rescue
        error in Docker.StreamError -> {:error, error.error_message}
      end
  """

  defexception [:message, :error_message]

  @type t :: %__MODULE__{message: String.t(), error_message: ErrorMessage.t()}

  @impl true
  def exception(opts) do
    error_message = opts |> Keyword.fetch!(:reason) |> describe()

    %__MODULE__{message: error_message.message, error_message: error_message}
  end

  defp describe(:timeout) do
    ErrorMessage.gateway_timeout(
      "Docker stream stalled: no data received within the idle timeout",
      %{reason: :timeout}
    )
  end

  defp describe(reason) do
    ErrorMessage.bad_gateway("Docker stream failed: #{inspect(reason)}", %{reason: reason})
  end
end
