defmodule Docker.Engine.Streaming.Session do
  @moduledoc """
  Stateful interactive I/O session against a container's stdin,
  stdout, and stderr.

  Built on top of `Sorrel.Tunnel`. A session wraps the
  post-handshake socket plus the demultiplexer state used when the
  inner process is running without a PTY (Docker frames stdout and
  stderr separately on the wire in that mode).

  Open a session with `Docker.attach/2` or `Docker.exec_session/3`,
  then drive it with `send/2` and `recv/3`. Close with `close/1`.

  ## Responsibilities

    - Wrap a post-handshake socket plus optional leftover bytes
      into a session value.
    - Send bytes to the inner process's stdin.
    - Read from the session under one of two termination
      conditions: an idle timeout, or a delimiter appearing in the
      stdout stream.
    - Demultiplex Docker's framed stdout/stderr stream when the
      inner process has no PTY; pass bytes through unchanged when
      it does.
    - Close the underlying socket idempotently.

  ## Examples

      iex> {:ok, session} = Docker.attach("my-container")
      iex> :ok = Docker.Engine.Streaming.Session.send(session, "ls\\n")
      iex> {:ok, _output, session} =
      ...>   Docker.Engine.Streaming.Session.recv(session, {:idle_timeout, 200})
      iex> Docker.Engine.Streaming.Session.close(session)
      :ok

  """

  alias Docker.Engine.Frame
  alias Sorrel.Tunnel

  # Abstraction Function:
  #   socket          represents the transport handle for this session,
  #                   or nil after close/1 has run.
  #   tty             records whether the inner process has a PTY
  #                   allocated. When true, daemon output is a raw byte
  #                   stream; when false, output is multiplexed and is
  #                   demuxed via Docker.Engine.Frame.
  #   buffer          holds demuxed stdout bytes received but not yet
  #                   returned to the caller. Empty initially.
  #   stderr_buffer   holds demuxed stderr bytes received but not yet
  #                   returned to the caller. Empty initially. Always
  #                   empty when tty is true (the daemon folds stderr
  #                   into stdout on the wire under PTY).
  #   frame_buffer    holds the trailing partial frame from the most
  #                   recent Docker.Engine.Frame.demux/1 call -- bytes that
  #                   look like the start of a frame but are not yet
  #                   complete. Empty initially. Always empty when tty
  #                   is true.
  #   closed          is true once the underlying socket has been
  #                   closed (by us or by the peer). Once set, no
  #                   further I/O is attempted.
  #
  #   Base case: %Session{socket: nil, tty: false, buffer: "",
  #                       stderr_buffer: "", frame_buffer: "",
  #                       closed: false} is the unconstructed value;
  #                       callers never observe it directly.
  #
  #   Many-to-one: After close/1, both closed: true and socket: nil
  #   represent the same terminal "no further I/O" state.
  #
  # Data Invariant:
  #   1. tty and closed are booleans.
  #   2. buffer, stderr_buffer, and frame_buffer are binaries.
  #   3. If tty == true, then frame_buffer == "" and stderr_buffer == "".
  #   4. If closed == true, send/2 and recv/3 return errors without
  #      touching socket.
  #   5. byte_size(buffer) + byte_size(stderr_buffer) <= max_bytes,
  #      enforced after each chunk by loop_idle/3.
  #
  # Commutative Diagram (recv/3, :idle_timeout, non-tty, single chunk c):
  #
  #   %Session{buffer: B, stderr_buffer: E, frame_buffer: F}
  #                          |
  #                       read(c)
  #                          v
  #   %Session{buffer: B<>out, stderr_buffer: E<>err, frame_buffer: rest}
  #          |                                                  |
  #         AF                                                 AF
  #          |                                                  |
  #          v                                                  v
  #    emitted(B, E), pending(F)        --read(c)-->     emitted(B<>out, E<>err),
  #                                                       pending(rest)
  #
  #   where {out, err, rest} = Docker.Engine.Frame.demux(F <> c)

  @type t :: %__MODULE__{
          socket: Tunnel.t() | nil,
          tty: boolean(),
          buffer: binary(),
          stderr_buffer: binary(),
          frame_buffer: binary(),
          closed: boolean()
        }

  @type recv_mode :: {:idle_timeout, pos_integer()} | {:until, binary()}
  @type recv_opts :: keyword()
  @type recv_result ::
          {:ok, binary(), t()}
          | {:ok, {binary(), binary()}, t()}
          | {:error, term(), t()}

  defstruct socket: nil,
            tty: false,
            buffer: "",
            stderr_buffer: "",
            frame_buffer: "",
            closed: false

  @default_max_bytes 10_000_000
  @default_until_timeout 30_000

  @doc """
  Returns a new session wrapping a post-handshake socket and any
  leftover bytes.

  ## Parameters

    - `socket` - `Sorrel.Tunnel.t()`. A socket returned
      by `Sorrel.tunnel/4`.
    - `leftover` - `binary()`. Bytes already read past the upgrade
      response head; ingested before the first read.
    - `tty` - `boolean()`. Whether the inner process has a PTY.
      Must match the actual container/exec configuration.

  ## Returns

  A `t()` ready for `send/2` and `recv/3`. The returned value
  satisfies the module's data invariant.

  ## Examples

      # Empty leftover, non-tty session
      iex> Docker.Engine.Streaming.Session.from_upgrade(socket, "", false)
      %Docker.Engine.Streaming.Session{tty: false, closed: false, buffer: "", ...}

  """
  @spec from_upgrade(Tunnel.t(), binary(), boolean()) :: t()
  def from_upgrade(socket, leftover, tty) when is_binary(leftover) and is_boolean(tty) do
    ingest(%__MODULE__{socket: socket, tty: tty}, leftover)
  end

  @doc """
  Returns `:ok` after sending bytes to the inner process's stdin.

  ## Parameters

    - `session` - `t()`. Must satisfy the module's data invariant.
    - `data` - `iodata()`. Bytes to send. The caller must include
      any trailing newline the inner process expects.

  ## Returns

  `:ok` on success. Returns `{:error, :closed}` if the session has
  already been closed, or `{:error, reason}` for other transport
  failures. Does not modify session state.

  ## Examples

      # Successful send
      iex> Docker.Engine.Streaming.Session.send(session, "hello\\n")
      :ok

  """
  @spec send(t(), iodata()) :: :ok | {:error, term()}
  def send(%__MODULE__{closed: true}, _data), do: {:error, :closed}
  def send(%__MODULE__{socket: socket}, data), do: Tunnel.send(socket, data)

  @doc """
  Returns bytes from the session under a termination condition.

  ## Parameters

    - `session` - `t()`. Must satisfy the module's data invariant.
    - `mode` - `recv_mode()`. One of:
        - `{:idle_timeout, ms}` - read available bytes; if no new
          data arrives for `ms` milliseconds, return what has
          accumulated. Treats peer close as end-of-stream.
        - `{:until, delim}` - read until `delim` (a non-empty
          binary) appears in the assembled stdout. Bytes past
          `delim` stay buffered for the next call.
    - `opts` - `keyword()`. Optional:
        - `:include_stderr` - default `true`. When not splitting,
          merge stderr into the returned binary.
        - `:split` - default `false`. Return `{stdout, stderr}`
          separately instead of merged.
        - `:max_bytes` - default `10_000_000`. Hard cap on
          accumulated output for `:idle_timeout` reads.
        - `:timeout` - default `30_000`. Overall deadline for
          `:until` reads.

  ## Returns

  For `:idle_timeout` without `:split`: `{:ok, binary(), t()}`.
  For `:idle_timeout` with `:split`: `{:ok, {stdout, stderr}, t()}`.
  For `:until`: `{:ok, binary(), t()}` containing everything up to
  and including the delimiter.

  Returns `{:error, :closed, t()}` if the session was already
  closed, `{:error, :closed_before_delimiter, t()}` if the peer
  closed before the delimiter appeared, `{:error, :timeout, t()}`
  if an `:until` read exhausted its overall timeout, or
  `{:error, reason, t()}` for other transport failures.

  The returned session value satisfies the module's data invariant.

  ## Examples

      # Idle-timeout read, merged stdout+stderr
      iex> Docker.Engine.Streaming.Session.recv(session, {:idle_timeout, 200})
      {:ok, "hello\\n", %Docker.Engine.Streaming.Session{...}}

      # Read until a marker
      iex> Docker.Engine.Streaming.Session.recv(session, {:until, "OK\\n"}, timeout: 5_000)
      {:ok, "ready... OK\\n", %Docker.Engine.Streaming.Session{...}}

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
  Returns `:ok` after closing the session's underlying socket.

  ## Parameters

    - `session` - `t()`. Must satisfy the module's data invariant.

  ## Returns

  `:ok`. Idempotent -- calling on an already-closed session also
  returns `:ok`.

  ## Examples

      # Always safe to call, even after close
      iex> Docker.Engine.Streaming.Session.close(session)
      :ok

  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{closed: true}), do: :ok

  def close(%__MODULE__{socket: socket}) when not is_nil(socket) do
    :ok = Tunnel.close(socket)
    :ok
  end

  def close(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------

  defp loop_idle(session, ms, max_bytes) do
    if total_bytes(session) >= max_bytes do
      session
    else
      case Tunnel.recv(session.socket, 0, ms) do
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
    case Tunnel.recv(session.socket, 0, remaining) do
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
