defmodule Docker.Engine.Frame do
  @moduledoc """
  Decoder for Docker's multiplexed stream framing.

  ## The problem this solves

  A program inside a Docker container writes to two separate output
  streams: **stdout** for normal output and **stderr** for errors.
  Docker has to deliver both back to the API client over a single
  HTTP connection, and it does so in one of two formats — chosen by
  whether the container was started with a pseudo-terminal (PTY)
  attached:

    * **Raw merged stream (PTY attached).** The kernel has already
      merged stdout and stderr into one byte stream — the same way
      they look interleaved on a real terminal — and Docker
      forwards those bytes to the client unchanged. There is
      nothing to decode.

    * **Multiplexed framed stream (no PTY).** stdout and stderr
      stay separate. Docker prefixes each chunk with an 8-byte
      header naming which stream the chunk came from and how many
      bytes follow, and writes the chunks back to back. The client
      reads the header, peels off exactly that many bytes, routes
      them to stdout or stderr, and reads the next header.

  This module decodes the Multiplexed framed stream format. The
  rest of this section explains what a PTY is, how the API picks
  between the two formats, and where in this codebase the decoder
  is used.

  ## What a PTY is

  A [PTY](https://man7.org/linux/man-pages/man7/pty.7.html)
  (pseudo-terminal, also written TTY) is a fake terminal created
  by the operating system. It is a *pair* of virtual character
  devices joined back to back; whatever is written into one end
  becomes readable from the other. The two ends have names:

    * **manager** — held by the program controlling the terminal:
      a terminal emulator (Terminal.app, iTerm, xterm), an SSH
      server, `tmux`, `expect`, or — when `Tty: true` — Docker.

    * **subsidiary** — handed to the program running "inside" the
      terminal: a shell, an editor, or any command-line tool. The
      program sees the subsidiary as an ordinary terminal sitting
      on its standard input, output, and error.

  Most people interact with PTYs constantly without noticing:
  every shell opened in a terminal application, every `ssh`
  session, and every `tmux` or `screen` pane runs on top of one.
  The smallest self-contained example is one line of Python:

      $ python3 -c "import pty; pty.spawn(['bash'])"

  `pty.spawn` opens a PTY pair, forks, wires the child's stdin,
  stdout, and stderr to the subsidiary end, and runs `bash`. The
  parent process holds the manager end and shuttles bytes between
  it and the real terminal you launched the command from. Inside
  that `bash`, running `tty` prints the path of the subsidiary
  device (e.g. `/dev/pts/3`) — proof that a brand-new PTY exists.

  The pieces involved when a PTY is in use:

      ┌──────┐  keystrokes   ┌──────────────────────┐
      │      │ ────────────▶ │  Terminal emulator   │
      │ User │               │  (Terminal.app,      │
      │      │ ◀──────────── │   iTerm, xterm, …)   │
      └──────┘  pixels       └──────────┬───────────┘
                                        │ reads/writes
                                        │ manager end
                                        ▼
                            ┌──────────────────────────┐
                            │        Kernel PTY        │
                            │  manager  ↔  subsidiary  │
                            └─────────────┬────────────┘
                                          │ subsidiary appears as
                                          │ stdin/stdout/stderr
                                          ▼
                                  ┌────────────────┐
                                  │    Program     │
                                  │ (bash, vim, …) │
                                  └────────────────┘

  The kernel copies bytes between the two ends and applies
  terminal behaviour along the way (line editing, echo, signal
  generation from Ctrl-C, and so on). When Docker is asked to
  attach a PTY to a container, **Docker plays the manager role**:
  it allocates the PTY pair on the host, hands the subsidiary to
  the containerised process, and forwards the manager bytes over
  the API connection to its client.

  ## Asking Docker for a PTY

  Whoever starts the container decides whether it gets a PTY by
  setting a single true/false flag in the start request. On the
  command line that flag is `-t` (or `--tty`):

      docker run -it ubuntu bash      # with PTY
      docker run ubuntu echo hello    # without PTY

  On the Engine API it is the `Tty` field in the JSON body of
  `POST /containers/create`:

      {"Image": "ubuntu", "Cmd": ["bash"], "Tty": true} # with PTY
      {"Image": "ubuntu", "Cmd": ["echo", "hello"]}     # without PTY

  The same `Tty` field appears on `POST /containers/{id}/exec` for
  running a command inside an already-running container:

      {"Cmd": ["bash"], "AttachStdout": true, "Tty": true}              # with PTY
      {"Cmd": ["ls", "/"], "AttachStdout": true, "AttachStderr": true}  # without PTY

  `Tty` defaults to `false` when omitted, so any code that talks
  to the Engine API directly — without explicitly opting in to a
  PTY — receives framed output and must run it through `demux/1`
  or `demux_all/1` to recover the original stdout and stderr
  bytes.

  ## Where this is used in the codebase

    * `Docker.Engine.Streaming.Session` — incrementally, as bytes arrive
      on a passive socket.
    * `Docker.container_logs/3` and `Docker.exec_start/2` — once,
      over a complete response body.

  ## Frame format

      ┌─────────┬──────────┬─────────────┬──────────────┐
      │ stream  │ reserved │   payload   │   payload    │
      │         │          │    size     │              │
      │ 1 byte  │ 3 bytes  │   4 bytes   │   N bytes    │
      │         │          │(big-endian) │              │
      └─────────┴──────────┴─────────────┴──────────────┘

  How to read a frame, byte by byte:

    * Byte 0 — **stream**: a single-byte tag identifying which
      standard stream the payload belongs to. Valid values:

          1 = stdout — normal program output
          2 = stderr — error output
          0 = stdin  — only used for input sent *to* the daemon;
                       this value never appears in frames coming
                       back from the daemon

    * Bytes 1–3 — **reserved**: three padding bytes the daemon
      sets aside for future use. They have no meaning today and
      are ignored on read.

    * Bytes 4–7 — **payload size**: an unsigned 32-bit integer,
      encoded big-endian (most significant byte first), giving
      the length in bytes of the payload that immediately
      follows. This is what tells the parser how many bytes to
      consume before the next frame header begins.

    * Bytes 8 to 8 + payload size − 1 — **payload**: the raw
      bytes of the stream's output for this frame. No encoding,
      no terminator; the size field is the only delimiter.

  A response body is zero or more frames laid end to end.

  ## Responsibilities

    - Split a buffer into completed stdout and stderr payloads plus
      any trailing partial frame for the next read.
    - Concatenate every completed payload of a complete body into a
      single binary, dropping the framing.

  ## Examples

      iex> Docker.Engine.Frame.demux(<<1, 0, 0, 0, 0, 0, 0, 5, "hello">>)
      {"hello", "", ""}

      iex> Docker.Engine.Frame.demux_all(
      ...>   <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
      ...> )
      "helloerr"

  """

  @doc """
  Returns the completed stdout and stderr payloads in a buffer plus
  any trailing partial frame.

  ## Parameters

    - `buffer` - `binary()`. Bytes possibly containing zero or more
      complete framed payloads followed by an incomplete trailing
      frame.

  ## Returns

  `{stdout, stderr, remaining}` where `stdout` and `stderr` are the
  concatenated payloads of all complete frames whose stream ID is
  `1` (stdout) or `2` (stderr), and `remaining` is the suffix of
  `buffer` that does not yet form a complete frame. Frames with any
  other stream ID are dropped (they should not appear in daemon
  output).

  The caller is expected to prepend `remaining` to the next chunk it
  reads. If `buffer` ends exactly on a frame boundary, `remaining`
  is `""`.

  ## Examples

      # Complete stdout frame, no remaining
      iex> Docker.Engine.Frame.demux(<<1, 0, 0, 0, 0, 0, 0, 5, "hello">>)
      {"hello", "", ""}

      # stdout and stderr in one buffer
      iex> Docker.Engine.Frame.demux(
      ...>   <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
      ...> )
      {"hello", "err", ""}

      # Partial trailing frame — caller prepends it next time
      iex> Docker.Engine.Frame.demux(<<1, 0, 0, 0, 0, 0, 0, 5, "hel">>)
      {"", "", <<1, 0, 0, 0, 0, 0, 0, 5, "hel">>}

  """
  @spec demux(binary()) :: {stdout :: binary(), stderr :: binary(), remaining :: binary()}
  def demux(buffer) when is_binary(buffer), do: do_demux(buffer, "", "")

  defp do_demux(<<stream::8, 0::24, size::32, rest::binary>>, out, err)
       when byte_size(rest) >= size do
    <<payload::binary-size(size), remaining::binary>> = rest

    case stream do
      1 -> do_demux(remaining, out <> payload, err)
      2 -> do_demux(remaining, out, err <> payload)
      _ -> do_demux(remaining, out, err)
    end
  end

  defp do_demux(remaining, out, err), do: {out, err, remaining}

  @doc """
  Returns the concatenated payloads of every complete frame in a
  buffer.

  ## Parameters

    - `body` - `binary()`. A complete framed response body. May
      contain a trailing partial frame, which is included verbatim
      in the output (matching the behaviour of the prior
      `do_demux_docker_multiplexed_stream/2` helper in `Docker`).

  ## Returns

  `binary()`. The concatenation of every complete frame's payload,
  in order, regardless of stream ID. If `body` ends with bytes that
  do not form a complete frame, those bytes are appended verbatim
  to the result. Result order matches input order.

  ## Examples

      # Two frames, payloads concatenated
      iex> Docker.Engine.Frame.demux_all(
      ...>   <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
      ...> )
      "helloerr"

      # Empty body
      iex> Docker.Engine.Frame.demux_all("")
      ""

  """
  @spec demux_all(binary()) :: binary()
  def demux_all(body) when is_binary(body), do: do_demux_all(body, "")

  defp do_demux_all(<<>>, acc), do: acc

  defp do_demux_all(<<_stream::8, 0::24, size::32, rest::binary>>, acc)
       when byte_size(rest) >= size do
    <<payload::binary-size(size), remaining::binary>> = rest
    do_demux_all(remaining, acc <> payload)
  end

  defp do_demux_all(remaining, acc), do: acc <> remaining

  @doc """
  Decodes one network chunk plus the leftover bytes from the previous chunk
  into a list of complete frame events and the new leftover.

  This is the chunk-streaming counterpart to `demux_all/1`. Use it when bytes
  arrive incrementally (for example, while consuming a streaming HTTP
  response) and you need to emit `{:stdout, _}` / `{:stderr, _}` events as
  soon as each frame's payload is complete.

  ## Parameters

    * `chunk` — Newly arrived bytes.
    * `buffer` — Bytes left over from the previous call. Pass `""` on the
      first call.

  ## What it returns

  `{events, leftover}` where:

    * `events` — A list, possibly empty, of `{:stdout, binary} | {:stderr, binary}`
      in arrival order. One element per complete frame whose stream ID is
      `1` (stdout) or `2` (stderr). Frames with any other stream ID are
      dropped (they should not appear in daemon output).
    * `leftover` — Bytes that did not yet form a complete frame. Pass them
      back as `buffer` on the next call.

  Partial-header (fewer than 8 bytes received) and partial-payload (header
  complete but payload short) inputs both yield `events = []` and
  `leftover` equal to the bytes received so far.

  ## Examples

      # Single complete stdout frame, no leftover
      iex> Docker.Engine.Frame.decode_chunk(<<1, 0, 0, 0, 0, 0, 0, 5, "hello">>, "")
      {[{:stdout, "hello"}], ""}

      # Two complete frames in one chunk
      iex> Docker.Engine.Frame.decode_chunk(
      ...>   <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>,
      ...>   ""
      ...> )
      {[stdout: "hello", stderr: "err"], ""}

      # Partial header — buffered for next call
      iex> Docker.Engine.Frame.decode_chunk(<<1, 0, 0, 0, 0>>, "")
      {[], <<1, 0, 0, 0, 0>>}

      # Header complete, payload short — buffered for next call
      iex> Docker.Engine.Frame.decode_chunk(<<1, 0, 0, 0, 0, 0, 0, 5, "hel">>, "")
      {[], <<1, 0, 0, 0, 0, 0, 0, 5, "hel">>}

  """
  @spec decode_chunk(binary(), binary()) ::
          {[{:stdout | :stderr, binary()}], binary()}
  def decode_chunk(chunk, buffer) when is_binary(chunk) and is_binary(buffer) do
    do_decode_chunk(buffer <> chunk, [])
  end

  defp do_decode_chunk(<<stream::8, 0::24, size::32, rest::binary>>, acc)
       when byte_size(rest) >= size do
    <<payload::binary-size(size), remaining::binary>> = rest

    case stream do
      1 -> do_decode_chunk(remaining, [{:stdout, payload} | acc])
      2 -> do_decode_chunk(remaining, [{:stderr, payload} | acc])
      _other -> do_decode_chunk(remaining, acc)
    end
  end

  defp do_decode_chunk(remaining, acc) do
    {Enum.reverse(acc), remaining}
  end
end
