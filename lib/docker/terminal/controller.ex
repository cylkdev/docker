defmodule Docker.Terminal.Controller do
  @moduledoc """
  Struct-based, in-process persistent shell session functions.

  Operates on the `Docker.Streaming.Session.t/0` value directly:
  `open/2` returns one, `command/2,3` returns an updated one,
  `close/1` releases the underlying connection. There is no Elixir
  process associated with the session — the caller threads the session
  through every call.

  Per-call defaults (`:recv_mode`, `:recv_opts`, `:newline`) are not
  stored on the state struct; they are resolved at command time from
  the options passed to `command/3` (falling back to module-level
  defaults when omitted). Callers that want stable defaults across
  many commands should use `Docker.Terminal.Server` (the name-based
  form), which holds them in its own process state.

  Most callers should use the name-based form through `Docker.Terminal`
  (which spawns a `Docker.Terminal.Server` and lets you address the
  session by container name).
  """
  @moduledoc since: "0.1.0"

  alias Docker.Streaming.Session

  @default_recv_mode {:idle_timeout, 200}
  @default_newline "\n"

  @doc """
  Opens a persistent shell against `container_ref` and returns the
  underlying `Docker.Streaming.Session.t/0`.

  ## Parameters

    - `container_ref` - `Docker.container_ref()`.
    - `opts` - `keyword()`. Recognised keys:

        * `:shell` - argv list. Defaults to `["/bin/sh"]`.
        * `:tty` - boolean. Defaults to `true`. A persistent shell
          needs a PTY: stdio-based programs (busybox `/bin/sh`,
          glibc) switch stdout to fully-buffered mode when it is a
          pipe, so replies never reach the caller until the buffer
          fills. With a PTY the shell line-buffers and each command
          reply is observable. Pass `tty: false` only when the
          target process explicitly flushes after every reply (the
          shape of the test REPL under `examples/terminal-example`).

      All other keys are forwarded to `Docker.Session.exec_session/3`
      (e.g. `:env`, `:user`, `:workdir`, `:endpoint`, `:sandbox`).
  """
  @doc since: "0.1.0"
  @spec open(Docker.container_ref(), keyword()) :: Docker.result(Session.t())
  def open(container_ref, opts \\ []) when is_binary(container_ref) and is_list(opts) do
    {shell, exec_opts} = Keyword.pop(opts, :shell, ["/bin/sh"])
    exec_opts = Keyword.put_new(exec_opts, :tty, true)

    Docker.Session.exec_session(container_ref, shell, exec_opts)
  end

  @doc """
  Sends a single line to the inline session and reads the reply,
  returning an updated session.

  Folds `Docker.Streaming.Session.send/2` and
  `Docker.Streaming.Session.recv/3` into one call. The configured
  `:newline` is appended automatically.

  ## Options

    * `:recv_mode` - termination strategy. Defaults to
      `{:idle_timeout, 200}`.
    * `:recv_opts` - keyword forwarded to
      `Docker.Streaming.Session.recv/3`. Defaults to `[]`.
    * `:newline` - binary appended after `line`. Defaults to `"\\n"`.

  Returns `{:ok, output, session}` (or
  `{:ok, {stdout, stderr}, session}` when `:split` is set in
  `:recv_opts`). Returns `{:error, reason, session}` on failure.
  """
  @doc since: "0.1.0"
  @spec command(Session.t(), iodata(), keyword()) ::
          {:ok, {binary(), Session.t()}}
          | {:ok, {{binary(), binary()}, Session.t()}}
          | {:error, {term(), Session.t()}}
  def command(%Session{} = session, line, opts \\ []) do
    recv_mode = Keyword.get(opts, :recv_mode, @default_recv_mode)
    recv_opts = Keyword.get(opts, :recv_opts, [])
    newline = Keyword.get(opts, :newline, @default_newline)
    payload = [line, newline]

    with :ok <- Session.send(session, payload),
         {:ok, output, session} <- Session.recv(session, recv_mode, recv_opts) do
      {:ok, {output, session}}
    else
      {:error, reason} -> {:error, {reason, session}}
      {:error, reason, session} -> {:error, {reason, session}}
    end
  end

  @doc """
  Closes the underlying session. Idempotent.
  """
  @doc since: "0.1.0"
  @spec close(Session.t()) :: :ok
  def close(%Session{} = session), do: Session.close(session)

  @doc false
  @spec transport(Session.t()) :: pid() | port() | nil
  def transport(%Session{socket: socket}), do: socket
end
