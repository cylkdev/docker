defmodule Docker.Terminal do
  @moduledoc """
  Unified entry point for running commands against a Docker container.

  Three forms of API, each handled by its own collaborator:

    * **One-shot exec** (`run/3`, `run_with_status/3`) — fire-and-forget
      command. Implemented here, no session.
    * **Name-based persistent session (recommended)** — `open/2` starts
      a `Docker.Terminal.Server` registered in
      `Docker.Terminal.Registry` under the container name. Subsequent
      calls pass the container name to `command/3` and `close/1` and
      this module looks up the registered server.
    * **Controller persistent session** — pass the
      `Docker.Streaming.Session.t/0` returned by `open/2` (or by
      `Docker.Terminal.Controller.open/2`) to `command/3` and `close/1`.
      This module delegates straight to `Docker.Terminal.Controller`.

  This module is the only dispatcher. `Docker.Terminal.Controller` and
  `Docker.Terminal.Server` do not know about each other or about this
  module; both operate on `Docker.Streaming.Session.t/0`.

  See `Docker` for the full client overview. Every function in this
  module is also exposed on the `Docker` facade
  (e.g. `Docker.terminal_run/3`, `Docker.terminal_open/2`).

  ## Examples

      # Name-based — recommended
      iex> {:ok, _state} = Docker.Terminal.open("my-container")
      iex> {:ok, {_, "my-container"}} = Docker.Terminal.command("my-container", "pwd")
      iex> :ok = Docker.Terminal.close("my-container")

      # Controller (struct-threading) — still supported
      iex> {:ok, state} = Docker.Terminal.open("my-container")
      iex> {:ok, {_, state}} = Docker.Terminal.command(state, "pwd")
      iex> :ok = Docker.Terminal.close(state)
  """
  @moduledoc since: "0.1.0"

  alias Docker.Exec
  alias Docker.Streaming.Session
  alias Docker.Terminal.Controller
  alias Docker.Terminal.Server

  @typedoc """
  A handle to a persistent session — either the container name (when
  the session was opened with `open/2` and is registered) or the
  inline `Docker.Streaming.Session.t/0`.
  """
  @typedoc since: "0.1.0"
  @type handle :: Session.t() | binary()

  # ---------------------------------------------------------------------------
  # ONE-SHOT
  # ---------------------------------------------------------------------------

  @doc """
  Runs a single command in `container_ref` and returns the combined
  stdout+stderr as a binary.
  """
  @doc since: "0.1.0"
  @spec run(Docker.container_ref(), [binary()] | binary(), Docker.options()) ::
          Docker.result(binary())
  def run(container_ref, cmd, opts \\ []),
    do: Exec.exec_run(container_ref, normalize_cmd(cmd), opts)

  @doc """
  Runs a single command in `container_ref` and returns its output plus
  the inner process's exit status.
  """
  @doc since: "0.1.0"
  @spec run_with_status(Docker.container_ref(), [binary()] | binary(), Docker.options()) ::
          Docker.result(Docker.exec_result())
  def run_with_status(container_ref, cmd, opts \\ []),
    do: Exec.exec_run_with_status(container_ref, normalize_cmd(cmd), opts)

  # ---------------------------------------------------------------------------
  # PERSISTENT — dispatcher
  # ---------------------------------------------------------------------------

  @doc """
  Opens a persistent shell against `container_ref` and registers it
  under the container name so subsequent `command/2,3` and `close/1`
  calls can address it by name.

  Stands up a `Docker.Terminal.Server` under
  `Docker.Terminal.Supervisor` that owns the resulting session and
  registers in `Docker.Terminal.Registry` keyed by `container_ref`.
  Only one session per container name may be open at a time.

  The returned `Docker.Streaming.Session.t/0` is also accepted by
  `command/2,3` and `close/1`, but the recommended form is to pass
  the container name instead.

  Returns `{:error, {:already_started, pid}}` if a session under
  `container_ref` is already open, or `{:error, reason}` if the
  underlying exec instance could not be created or started.

  See `Docker.Terminal.Controller.open/2` for recognised options.
  """
  @doc since: "0.1.0"
  @spec open(Docker.container_ref(), keyword()) :: Docker.result(Session.t())
  def open(container_ref, opts \\ []) when is_binary(container_ref) and is_list(opts) do
    spec = %{
      id: {Server, container_ref},
      start: {Server, :start_link, [{container_ref, opts}]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Docker.Terminal.Supervisor, spec) do
      {:ok, pid} -> Server.fetch_session(pid)
      {:error, {:already_started, _pid}} = err -> err
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a single line to the open shell and reads the reply.

  Dispatches by `handle` shape:

    * binary — looks up the session registered under that container
      name in `Docker.Terminal.Registry` and calls into its
      `Docker.Terminal.Server`. Returns `{:ok, {output, name}}`.
    * `Docker.Streaming.Session.t/0` — delegates to
      `Docker.Terminal.Controller.command/3`. Returns
      `{:ok, {output, session}}` with the updated handle.

  When no session is registered under a binary `handle`, returns
  `{:error, {:not_found, handle}}`.
  """
  @doc since: "0.1.0"
  @spec command(handle(), iodata(), keyword()) ::
          {:ok, {binary(), handle()}}
          | {:ok, {{binary(), binary()}, handle()}}
          | {:error, {term(), handle()}}
  def command(handle, line, opts \\ [])

  def command(name, line, opts) when is_binary(name) do
    case Server.whereis(name) do
      {:ok, pid} -> Server.command(pid, line, opts)
      :error -> {:error, {:not_found, name}}
    end
  end

  def command(%Session{} = session, line, opts), do: Controller.command(session, line, opts)

  @doc """
  Closes a persistent session. Idempotent.

  Dispatches by `handle` shape:

    * binary — stops the `Docker.Terminal.Server` registered under
      that container name. Returns `:ok` even if no session is
      registered.
    * `Docker.Streaming.Session.t/0` — closes the inline session via
      `Docker.Terminal.Controller.close/1`.
  """
  @doc since: "0.1.0"
  @spec close(handle()) :: :ok
  def close(name) when is_binary(name) do
    case Server.whereis(name) do
      {:ok, pid} -> Server.close(pid)
      :error -> :ok
    end
  end

  def close(%Session{} = session), do: Controller.close(session)

  # ---------------------------------------------------------------------------
  # INTERNAL
  # ---------------------------------------------------------------------------

  defp normalize_cmd(cmd) when is_list(cmd), do: cmd
  defp normalize_cmd(cmd) when is_binary(cmd), do: ["/bin/sh", "-c", cmd]
end
