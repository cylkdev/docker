defmodule Docker.Streaming.Session do
  @moduledoc """
  Stateful interactive I/O session against a container's stdin,
  stdout, and stderr.

  Built on top of `OneOhOne`. A session wraps the `OneOhOne` connection
  pid plus the demultiplexer state used when the inner process is
  running without a PTY (Docker frames stdout and stderr separately on
  the wire in that mode).

  Open a session with `Docker.attach/2` or `Docker.exec_session/3`,
  then drive it with `send/2` and `recv/3`. Close with `close/1`.

  ## Responsibilities

    - Wrap a post-handshake connection pid into a session value.
    - Send bytes to the inner process's stdin.
    - Read from the session under one of two termination conditions:
      an idle timeout, or a delimiter appearing in the stdout stream.
    - Demultiplex Docker's framed stdout/stderr stream when the inner
      process has no PTY; pass bytes through unchanged when it does.
    - Close the underlying transport idempotently.

  ## Examples

      iex> {:ok, session} = Docker.attach("my-container")
      iex> Docker.Streaming.Session.send(session, "ls\\n")
      iex> {:ok, _output, session} =
      ...>   Docker.Streaming.Session.recv(session, {:idle_timeout, 200})
      iex> Docker.Streaming.Session.close(session)
      :ok

  """

  alias Docker.Frame

  # Abstraction Function:
  #   socket          represents the OneOhOne.Connection pid for this
  #                   session, or nil after close/1 has run.
  #   tty             records whether the inner process has a PTY.
  #                   When true, daemon output is a raw byte stream;
  #                   when false, output is multiplexed and demuxed via
  #                   Docker.Frame.
  #   buffer          demuxed stdout bytes received but not yet returned.
  #   stderr_buffer   demuxed stderr bytes received but not yet returned.
  #                   Empty when tty is true.
  #   frame_buffer    trailing partial frame from the most recent
  #                   demux call. Empty when tty is true.
  #   closed          set once the underlying socket has been closed.

  @type transport :: pid() | nil

  @type t :: %__MODULE__{
          socket: transport(),
          tty: boolean(),
          buffer: binary(),
          stderr_buffer: binary(),
          frame_buffer: binary(),
          closed: boolean()
        }

  @type recv_mode :: {:idle_timeout, non_neg_integer()} | {:until, binary()}
  @type recv_opts :: keyword()
  @type recv_result ::
          {:ok, binary(), t()}
          | {:ok, {binary(), binary()}, t()}
          | {:error, ErrorMessage.t()}

  defstruct socket: nil,
            tty: false,
            buffer: "",
            stderr_buffer: "",
            frame_buffer: "",
            closed: false

  @default_max_bytes 10_000_000
  @default_until_timeout 30_000

  @doc """
  Returns a new session wrapping a `OneOhOne.Connection` pid.

  No leftover bytes — the handshake handshake belongs to OneOhOne and
  any post-handshake bytes arrive via the handler protocol.
  """
  @spec from_connection(pid(), boolean()) :: t()
  def from_connection(conn_pid, tty) when is_pid(conn_pid) and is_boolean(tty) do
    %__MODULE__{socket: conn_pid, tty: tty}
  end

  @doc """
  Returns `:ok` after sending bytes to the inner process's stdin.
  """
  @spec send(t(), iodata()) :: :ok | {:error, ErrorMessage.t()}
  def send(%__MODULE__{closed: true} = session, _data) do
    {:error, closed_error("Cannot write to a closed session", session)}
  end

  def send(%__MODULE__{socket: socket} = session, data) do
    case transport_send(socket, data) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.bad_gateway(
           "Could not write to the session transport: #{inspect(reason)}",
           %{reason: reason, session: session}
         )}
    end
  end

  @doc """
  Returns bytes from the session under a termination condition.

  On failure the session is carried in the error's `:details` under
  `:session`, so a caller holding buffered output does not lose it:

      {:error, %ErrorMessage{details: %{session: session}}} ->
        # `session` is still usable; its buffers are intact.
  """
  @spec recv(t(), recv_mode(), recv_opts()) :: recv_result()
  def recv(session, mode, opts \\ [])

  def recv(%__MODULE__{closed: true} = session, _mode, _opts) do
    {:error, closed_error("Cannot read from a closed session", session)}
  end

  def recv(%__MODULE__{} = session, {:idle_timeout, ms}, opts)
      when is_integer(ms) and ms >= 0 do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    session = loop_idle(session, ms, max_bytes)
    finalize(session, opts)
  end

  def recv(%__MODULE__{} = session, {:until, delim}, opts)
      when is_binary(delim) and byte_size(delim) > 0 do
    overall = Keyword.get(opts, :timeout, @default_until_timeout)
    deadline = :erlang.monotonic_time(:millisecond) + overall
    loop_until(session, delim, deadline)
  end

  @doc """
  Returns `:ok` after closing the session's underlying transport.
  Idempotent.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{closed: true}), do: :ok

  def close(%__MODULE__{socket: socket}) when not is_nil(socket) do
    transport_close(socket)
  end

  def close(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Transport dispatch — the OneOhOne connection process
  # ---------------------------------------------------------------------------

  defp transport_send(socket, data) when is_pid(socket), do: OneOhOne.push(socket, data)

  # Keeps bare atoms rather than ErrorMessage structs: these two outcomes are
  # control flow for `loop_idle/3` and `recv_and_continue/4`, which decide
  # between them, and neither escapes this module.
  defp transport_recv(socket, ms) when is_pid(socket) do
    receive do
      {:docker_stream, ^socket, :data, chunk} -> {:ok, chunk}
      {:docker_stream, ^socket, :closed} -> {:error, :closed}
    after
      ms -> {:error, :timeout}
    end
  end

  defp transport_close(socket) when is_pid(socket), do: OneOhOne.close(socket)

  # ---------------------------------------------------------------------------
  # Internals — recv loops, ingest, finalize
  # ---------------------------------------------------------------------------

  defp loop_idle(session, ms, max_bytes) do
    if total_bytes(session) >= max_bytes do
      session
    else
      case transport_recv(session.socket, ms) do
        {:ok, chunk} ->
          session
          |> ingest(chunk)
          |> loop_idle(ms, max_bytes)

        {:error, :timeout} ->
          session

        {:error, :closed} ->
          %{session | closed: true}
      end
    end
  end

  defp loop_until(session, delim, deadline) do
    case :binary.match(session.buffer, delim) do
      {pos, len} ->
        out = binary_part(session.buffer, 0, pos + len)
        rest_size = byte_size(session.buffer) - pos - len
        rest = binary_part(session.buffer, pos + len, rest_size)
        {:ok, out, %{session | buffer: rest}}

      :nomatch ->
        remaining = deadline - :erlang.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, timeout_error(session, delim)}
        else
          recv_and_continue(session, delim, deadline, remaining)
        end
    end
  end

  defp recv_and_continue(session, delim, deadline, remaining) do
    case transport_recv(session.socket, remaining) do
      {:ok, chunk} ->
        session
        |> ingest(chunk)
        |> loop_until(delim, deadline)

      {:error, :timeout} ->
        {:error, timeout_error(session, delim)}

      {:error, :closed} ->
        {:error,
         ErrorMessage.gone(
           "The session closed before the delimiter arrived",
           %{session: %{session | closed: true}, delimiter: delim}
         )}
    end
  end

  defp timeout_error(session, delim) do
    ErrorMessage.request_timeout(
      "Timed out waiting for the delimiter #{inspect(delim)}",
      %{session: session, delimiter: delim}
    )
  end

  defp closed_error(message, session) do
    ErrorMessage.gone(message, %{session: session})
  end

  defp finalize(session, opts) do
    split? = Keyword.get(opts, :split, false)
    include_stderr? = Keyword.get(opts, :include_stderr, true)

    cond do
      split? ->
        out = session.buffer
        err = session.stderr_buffer
        {:ok, {out, err}, %{session | buffer: "", stderr_buffer: ""}}

      include_stderr? ->
        out = session.buffer <> session.stderr_buffer
        {:ok, out, %{session | buffer: "", stderr_buffer: ""}}

      true ->
        out = session.buffer
        {:ok, out, %{session | buffer: ""}}
    end
  end

  defp ingest(session, ""), do: session

  defp ingest(%__MODULE__{tty: true} = session, data) do
    %{session | buffer: session.buffer <> data}
  end

  defp ingest(%__MODULE__{tty: false} = session, data) do
    {stdout, stderr, rest} = Frame.demux(session.frame_buffer <> data)

    %{
      session
      | buffer: session.buffer <> stdout,
        stderr_buffer: session.stderr_buffer <> stderr,
        frame_buffer: rest
    }
  end

  defp total_bytes(%__MODULE__{buffer: b, stderr_buffer: e}),
    do: byte_size(b) + byte_size(e)
end
