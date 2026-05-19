defmodule Docker.Log do
  @moduledoc false
  require Logger

  @spec debug(prefix :: binary(), message :: binary()) :: :ok
  def debug(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.debug()
  end

  @spec warning(prefix :: binary(), message :: binary()) :: :ok
  def warning(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.warning()
  end

  @spec error(prefix :: binary(), message :: binary()) :: :ok
  def error(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.error()
  end

  @doc """
  Logs a single event from `Docker.pull_image/3`'s event stream in human-readable form.

  Use this with `Stream.each/2` when you want the same per-event progress
  output the old callback-based `pull_image/3` produced:

      {:ok, events} = Docker.pull_image("alpine")
      events
      |> Stream.each(&Docker.Log.log_pull_event/1)
      |> Stream.run()

  ## Parameters

    * `event` - A map decoded from the daemon's NDJSON event stream. The
      function inspects `"error"`, `"stream"`, `"status"`, and `"id"` keys
      when present.

  ## What it returns

  `:ok`. Side effect: writes one log record to `Logger`. Events with an
  `"error"` key go to `:error`; everything else goes to `:info`. Empty or
  whitespace-only `"stream"` lines emit nothing.
  """
  @spec log_pull_event(term()) :: :ok
  def log_pull_event(event) when is_map(event), do: log_event_map(event)
  def log_pull_event(event), do: log_other(event)

  defp log_event_map(%{"error" => err}), do: Logger.error("error: " <> to_string(err))
  defp log_event_map(%{"stream" => raw}), do: log_stream_line(raw)
  defp log_event_map(%{"status" => status, "id" => id}), do: Logger.info("#{id}: #{status}")
  defp log_event_map(%{"status" => status}), do: Logger.info(status)
  defp log_event_map(other), do: log_other(other)

  defp log_stream_line(raw) do
    case raw |> to_string() |> String.trim_trailing() do
      "" -> :ok
      line -> Logger.info(line)
    end
  end

  defp log_other(event) do
    event |> inspect() |> Logger.info()
  end

  @doc """
  Logs a single event from `Docker.build_image/5`'s event stream.

  The Docker build endpoint emits events with the same shape as the pull
  endpoint (`"stream"` lines for build progress, `"error"` on failure,
  occasional `"status"` records for layer pulls), so this delegates to
  `log_pull_event/1`.
  """
  @spec log_build_event(term()) :: :ok
  def log_build_event(event), do: log_pull_event(event)

  defp format_message(prefix, message) do
    "[#{prefix}] #{message}"
  end
end
