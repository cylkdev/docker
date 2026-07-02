defmodule Docker.Terminal.Server do
  @moduledoc """
  Per-session GenServer that owns a `Docker.Streaming.Session` handle
  and is registered in `Docker.Terminal.Registry` under the container
  name.

  Callers do not interact with this module directly; use
  `Docker.Terminal.open/2`, `Docker.Terminal.command/3`, and
  `Docker.Terminal.close/1` with the container name.
  """
  @moduledoc since: "0.1.0"

  use GenServer

  alias Docker.Streaming.Session
  alias Docker.Terminal.Controller

  @type server_state :: %{
          name: binary(),
          session: Session.t(),
          defaults: keyword(),
          socket_ref: reference() | nil
        }

  @default_keys [:recv_mode, :recv_opts, :newline]

  @doc """
  Start a session server for `container_name` with the given open
  options and register it in `Docker.Terminal.Registry` under the
  container name.
  """
  @spec start_link({binary(), keyword()}) :: GenServer.on_start()
  def start_link({container_name, open_opts}) when is_binary(container_name) do
    GenServer.start_link(__MODULE__, {container_name, open_opts}, name: via(container_name))
  end

  @doc """
  Resolve the registered pid for `container_name`, or `:error` if no
  session is currently open under that name.
  """
  @spec whereis(binary()) :: {:ok, pid()} | :error
  def whereis(container_name) when is_binary(container_name) do
    case Registry.lookup(Docker.Terminal.Registry, container_name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Return the underlying session held by the server. Useful when the
  caller wants to fall back to direct struct-threading after opening
  by name.
  """
  @spec fetch_session(pid()) :: {:ok, Session.t()}
  def fetch_session(pid), do: GenServer.call(pid, :get_session)

  @doc """
  Run a command on the session held by `pid`. Mirrors the inline-path
  return shape, with the container name in place of an updated state.
  """
  @spec command(pid(), iodata(), keyword()) ::
          {:ok, {binary(), binary()}}
          | {:ok, {{binary(), binary()}, binary()}}
          | {:error, {term(), binary()}}
  def command(pid, line, opts \\ []), do: GenServer.call(pid, {:command, line, opts}, :infinity)

  @doc """
  Close the session held by `pid` and stop the server.
  """
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  defp via(container_name),
    do: {:via, Registry, {Docker.Terminal.Registry, container_name}}

  @impl true
  def init({container_name, open_opts}) do
    Process.flag(:trap_exit, true)
    {defaults, exec_opts} = Keyword.split(open_opts, @default_keys)

    case Controller.open(container_name, exec_opts) do
      {:ok, session, _exec_id} ->
        ref = monitor_transport(session)

        {:ok, %{name: container_name, session: session, defaults: defaults, socket_ref: ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_session, _from, server), do: {:reply, {:ok, server.session}, server}

  def handle_call({:command, line, opts}, _from, server) do
    merged_opts = Keyword.merge(server.defaults, opts)

    case Controller.command(server.session, line, merged_opts) do
      {:ok, {output, session}} ->
        {:reply, {:ok, {output, server.name}}, %{server | session: session}}

      {:error, {reason, session}} ->
        {:reply, {:error, {reason, server.name}}, %{server | session: session}}
    end
  end

  def handle_call(:close, _from, server) do
    :ok = Controller.close(server.session)
    {:stop, :normal, :ok, server}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{socket_ref: ref} = server) do
    {:stop, :normal, %{server | socket_ref: nil}}
  end

  def handle_info(_msg, server), do: {:noreply, server}

  @impl true
  def terminate(_reason, server) do
    _ = Controller.close(server.session)
    :ok
  end

  defp monitor_transport(session) do
    case Controller.transport(session) do
      pid when is_pid(pid) -> Process.monitor(pid)
      _ -> nil
    end
  end
end
