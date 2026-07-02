defmodule Docker.Streaming.Session do
  @moduledoc """
  Stateful interactive I/O session against a container's stdin,
  stdout, and stderr.

  Built on top of `OneOhOne`. A session wraps the underlying transport
  handle (a `OneOhOne` connection pid in production, or a `:gen_tcp`
  port in unit tests) plus the demultiplexer state used when the inner
  process is running without a PTY (Docker frames stdout and stderr
  separately on the wire in that mode).

  Open a session with `Docker.attach/2` or `Docker.exec_session/3`,
  then drive it with `send/2` and `recv/3`. Close with `close/1`.

  ## Responsibilities

    - Wrap a post-handshake transport handle plus optional leftover
      bytes into a session value.
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
  #   socket          represents the transport handle for this session,
  #                   or nil after close/1 has run. The handle is either
  #                   a OneOhOne.Connection pid (production path) or a
  #                   :gen_tcp port (unit-test path).
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

  @type transport :: pid() | :gen_tcp.socket() | nil

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
          | {:error, term(), t()}

  defstruct socket: nil,
            tty: false,
            exec_id: nil,
            opts: [],
            buffer: "",
            stderr_buffer: "",
            frame_buffer: "",
            closed: false

  @default_max_bytes 10_000_000
  @default_until_timeout 30_000

  @doc """
  Returns a new session wrapping a post-handshake transport handle and
  any leftover bytes.

  ## Parameters

    - `socket` - a transport handle. Either a `OneOhOne.Connection`
      pid or a `:gen_tcp` port.
    - `leftover` - `binary()`. Bytes already read past the upgrade
      response head; ingested before the first read.
    - `tty` - `boolean()`. Whether the inner process has a PTY.
  """
  @spec from_upgrade(transport(), binary(), boolean()) :: t()
  def from_upgrade(socket, leftover, tty) when is_binary(leftover) and is_boolean(tty) do
    ingest(%__MODULE__{socket: socket, tty: tty}, leftover)
  end

  @doc """
  Returns a new session wrapping a `OneOhOne.Connection` pid.

  No leftover bytes — the handshake handshake belongs to OneOhOne and
  any post-handshake bytes arrive via the handler protocol.
  """
  @spec from_connection(pid(), boolean(), binary() | nil, keyword()) :: t()
  def from_connection(conn_pid, tty, exec_id \\ nil, opts \\ [])
      when is_pid(conn_pid) and is_boolean(tty) do
    %__MODULE__{socket: conn_pid, tty: tty, exec_id: exec_id, opts: opts}
  end

  @doc """
  Returns `:ok` after sending bytes to the inner process's stdin.
  """
  @spec send(t(), iodata()) :: :ok | {:error, term()}
  def send(%__MODULE__{closed: true}, _data), do: {:error, :closed}
  def send(%__MODULE__{socket: socket}, data), do: transport_send(socket, data)

  @doc """
  Resizes the exec's TTY to `{rows, cols}`.

  Requires a session opened from an exec (one that carries an `exec_id`);
  returns `{:error, :no_exec_id}` otherwise.
  """
  @spec resize(t(), {pos_integer(), pos_integer()}) :: :ok | {:error, term()}
  def resize(%__MODULE__{exec_id: nil}, _size), do: {:error, :no_exec_id}

  def resize(%__MODULE__{exec_id: exec_id, opts: opts}, {rows, cols})
      when is_integer(rows) and is_integer(cols) do
    Docker.Exec.resize(exec_id, rows, cols, opts)
  end

  @doc """
  Returns bytes from the session under a termination condition.
  """
  @spec recv(t(), recv_mode(), recv_opts()) :: recv_result()
  def recv(session, mode, opts \\ [])

  def recv(%__MODULE__{closed: true} = s, _mode, _opts), do: {:error, :closed, s}

  def recv(%__MODULE__{} = session, {:idle_timeout, ms}, opts)
      when is_integer(ms) and ms >= 0 do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    session = loop_idle(session, ms, max_bytes)
    finalize(session, opts)
  end

  def recv(%__MODULE__{} = session, {:until, delim}, opts)
      when is_binary(delim) and byte_size(delim) > 0 do
    overall = Keyword.get(opts, :timeout, @default_until_timeout)
    deadline = System.monotonic_time(:millisecond) + overall
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
  # Transport dispatch — pid (OneOhOne) vs port (:gen_tcp)
  # ---------------------------------------------------------------------------

  defp transport_send(socket, data) when is_pid(socket), do: OneOhOne.push(socket, data)
  defp transport_send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)

  defp transport_recv(socket, ms) when is_pid(socket) do
    receive do
      {:docker_stream, ^socket, :data, chunk} -> {:ok, chunk}
      {:docker_stream, ^socket, :closed} -> {:error, :closed}
    after
      ms -> {:error, :timeout}
    end
  end

  defp transport_recv(socket, ms) when is_port(socket) do
    :gen_tcp.recv(socket, 0, ms)
  end

  defp transport_close(socket) when is_pid(socket) do
    OneOhOne.close(socket)
  end

  defp transport_close(socket) when is_port(socket) do
    :gen_tcp.close(socket)
  end

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

        {:error, _reason} ->
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
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, :timeout, session}
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
        {:error, :timeout, session}

      {:error, :closed} ->
        {:error, :closed_before_delimiter, %{session | closed: true}}

      {:error, reason} ->
        {:error, reason, %{session | closed: true}}
    end
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
