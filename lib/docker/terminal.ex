defmodule Docker.Terminal do
  @moduledoc """
  Persistent shell sessions against a running Docker container.

  `open/2` starts a session process registered in
  `Docker.Terminal.Registry` under the container name; `command/3` and
  `close/1` address it by that name. State carries across commands —
  the working directory and environment variables persist.

  For a fire-and-forget command that needs no session, use
  `Docker.exec_run/3`.

  See `Docker` for the full client overview. Every function in this
  module is also exposed on the `Docker` facade
  (e.g. `Docker.terminal_open/2`).

  ## Examples

      iex> :ok = Docker.Terminal.open("my-container")
      iex> {:ok, {_, "my-container"}} = Docker.Terminal.command("my-container", "cd /tmp")
      iex> {:ok, {out, "my-container"}} = Docker.Terminal.command("my-container", "pwd")
      iex> :ok = Docker.Terminal.close("my-container")

  This module is also the session process itself: one `GenServer` per
  open session, owning the `Docker.Streaming.Session.t/0` handle and
  the mailbox its bytes arrive on.
  """
  @moduledoc since: "0.1.0"

  use GenServer

  alias Docker.Streaming.Session

  @type server_state :: %{
          name: binary(),
          session: Session.t(),
          defaults: keyword(),
          socket_ref: reference()
        }

  @default_recv_mode {:idle_timeout, 200}
  @default_newline "\n"
  @default_keys [:recv_mode, :recv_opts, :newline]

  # ---------------------------------------------------------------------------
  # PUBLIC API
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` after opening a persistent shell against `container_ref`
  and registering it under the container name.

  Stands up a session process under `Docker.Terminal.Supervisor`
  registered in `Docker.Terminal.Registry` keyed by `container_ref`.
  Only one session per container name may be open at a time.

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
        * `:recv_mode`, `:recv_opts`, `:newline` - per-session
          defaults for `command/3`, overridable per call.

      All other keys are forwarded to `Docker.Session.exec_session/3`
      (e.g. `:env`, `:user`, `:workdir`, `:sandbox`).

  Returns `{:error, {:already_started, pid}}` if a session under
  `container_ref` is already open, or `{:error, reason}` if the
  underlying exec instance could not be created or started.
  """
  @doc since: "0.1.0"
  @spec open(Docker.container_ref(), keyword()) :: :ok | {:error, term()}
  def open(container_ref, opts \\ []) when is_binary(container_ref) and is_list(opts) do
    spec = %{
      id: {__MODULE__, container_ref},
      start: {__MODULE__, :start_link, [{container_ref, opts}]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Docker.Terminal.Supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the reply after sending a single line to the shell open under
  `container_ref`.

  Folds `Docker.Streaming.Session.send/2` and
  `Docker.Streaming.Session.recv/3` into one call. The configured
  `:newline` is appended automatically.

  ## Options

  Each overrides the same key passed to `open/2` for this call only.

    * `:recv_mode` - termination strategy. Defaults to
      `{:idle_timeout, 200}`.
    * `:recv_opts` - keyword forwarded to
      `Docker.Streaming.Session.recv/3`. Defaults to `[]`.
    * `:newline` - binary appended after `line`. Defaults to `"\\n"`.

  Returns `{:ok, {output, container_ref}}` (or
  `{:ok, {{stdout, stderr}, container_ref}}` when `:split` is set in
  `:recv_opts`), `{:error, {reason, container_ref}}` on failure, or
  `{:error, {:not_found, container_ref}}` when no session is open under
  that name.
  """
  @doc since: "0.1.0"
  @spec command(binary(), iodata(), keyword()) ::
          {:ok, {binary(), binary()}}
          | {:ok, {{binary(), binary()}, binary()}}
          | {:error, {term(), binary()}}
  def command(container_ref, line, opts \\ []) when is_binary(container_ref) do
    case whereis(container_ref) do
      {:ok, pid} -> GenServer.call(pid, {:command, line, opts}, :infinity)
      :error -> {:error, {:not_found, container_ref}}
    end
  end

  @doc """
  Returns `:ok` after closing the session open under `container_ref`.

  Idempotent: returns `:ok` even when no session is registered.
  """
  @doc since: "0.1.0"
  @spec close(binary()) :: :ok
  def close(container_ref) when is_binary(container_ref) do
    case whereis(container_ref) do
      {:ok, pid} -> GenServer.call(pid, :close)
      :error -> :ok
    end
  end

  @doc """
  Returns `{:ok, pid}` for the session open under `container_ref`, or
  `:error` if no session is currently open under that name.
  """
  @doc since: "0.1.0"
  @spec whereis(binary()) :: {:ok, pid()} | :error
  def whereis(container_ref) when is_binary(container_ref) do
    case Registry.lookup(Docker.Terminal.Registry, container_ref) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc false
  @spec start_link({binary(), keyword()}) :: GenServer.on_start()
  def start_link({container_ref, open_opts}) when is_binary(container_ref) do
    GenServer.start_link(__MODULE__, {container_ref, open_opts}, name: via(container_ref))
  end

  # ---------------------------------------------------------------------------
  # SESSION PROCESS
  # ---------------------------------------------------------------------------

  @impl true
  def init({container_ref, open_opts}) do
    Process.flag(:trap_exit, true)
    {defaults, exec_opts} = Keyword.split(open_opts, @default_keys)
    {shell, exec_opts} = Keyword.pop(exec_opts, :shell, ["/bin/sh"])
    exec_opts = Keyword.put_new(exec_opts, :tty, true)

    case Docker.Session.exec_session(container_ref, shell, exec_opts) do
      {:ok, session} ->
        state = %{
          name: container_ref,
          session: session,
          defaults: defaults,
          socket_ref: monitor_transport(session)
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:command, line, opts}, _from, server) do
    opts = Keyword.merge(server.defaults, opts)
    payload = [line, Keyword.get(opts, :newline, @default_newline)]
    recv_mode = Keyword.get(opts, :recv_mode, @default_recv_mode)
    recv_opts = Keyword.get(opts, :recv_opts, [])

    with :ok <- Session.send(server.session, payload),
         {:ok, output, session} <- Session.recv(server.session, recv_mode, recv_opts) do
      {:reply, {:ok, {output, server.name}}, %{server | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, {reason, server.name}}, server}

      {:error, reason, session} ->
        {:reply, {:error, {reason, server.name}}, %{server | session: session}}
    end
  end

  def handle_call(:close, _from, server), do: {:stop, :normal, :ok, server}

  @impl true
  def handle_info({:DOWN, ref, :process, _transport, _reason}, %{socket_ref: ref} = server) do
    {:stop, :normal, server}
  end

  # Daemon output that arrived outside a `command/3` call. `Session.recv/3`
  # drains the mailbox itself, so anything reaching the GenServer loop is
  # unsolicited and belongs to no pending read.
  def handle_info({:docker_stream, _conn, :data, _bytes}, server) do
    {:noreply, server}
  end

  def handle_info({:docker_stream, _conn, :closed}, server) do
    {:stop, :normal, server}
  end

  @impl true
  def terminate(_reason, server) do
    :ok = Session.close(server.session)
    :ok
  end

  # ---------------------------------------------------------------------------
  # INTERNAL
  # ---------------------------------------------------------------------------

  @spec via(binary()) :: {:via, Registry, {module(), binary()}}
  defp via(container_ref),
    do: {:via, Registry, {Docker.Terminal.Registry, container_ref}}

  @spec monitor_transport(Session.t()) :: reference()
  defp monitor_transport(%Session{socket: pid}) when is_pid(pid), do: Process.monitor(pid)
end
