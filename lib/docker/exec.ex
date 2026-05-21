defmodule Docker.Exec do
  @moduledoc """
  Running commands inside Docker containers via exec instances.

  An exec instance is a command that runs inside an already-running container,
  sharing its filesystem and network. You create it, start it, and optionally
  inspect its exit code when it finishes.

  **Most callers should use `Docker.Terminal` instead.** `Docker.Terminal.run/3`
  wraps the three steps below into a single call. Use this module directly
  when you need to control the create/start/inspect steps individually.

  Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.exec_run/3`). See `Docker` for the full client overview.

  ## Typical use

      # Run a command and get its output in one call (recommended)
      {:ok, output} = Docker.Exec.exec_run("my-container", ["ls", "/etc"])

      # Run and get exit code too
      {:ok, %{output: out, exit_code: code}} =
        Docker.Exec.exec_run_with_status("my-container", ["grep", "ERROR", "/var/log/app.log"])
  """

  alias Docker.Client
  alias Docker.Serializer

  @doc """
  Creates an exec instance in a running container but does not start it yet.

  Returns an exec ID that you pass to `exec_start/2` to actually run the
  command, or to `exec_inspect/2` to check its state. Most callers prefer
  `exec_run/3`, which does create + start in one call.

  ## Parameters

    - `container_ref` — the container name or ID. The container must be
      running.
    - `cmd` — the command as a list of strings. Each element is one token:
      `["ls", "-la", "/etc"]`, not `["ls -la /etc"]`.
    - `options` — optional keyword list. Recognised keys:
      - `:env` — list of `"KEY=VALUE"` strings to set in the exec process.
      - `:user` — string username or UID to run as.
      - `:workdir` — working directory inside the container.
      - `:tty` — boolean, allocate a pseudo-terminal (default `false`).
      - `:attach_stdin` — boolean (default `false`).

  ## Returns

    - `{:ok, exec_id}` — a string ID for the new exec instance. Pass it
      to `exec_start/2`.
    - `{:error, reason}` — container not found, not running, or daemon
      returned an error.

  ## Examples

      {:ok, exec_id} = Docker.Exec.exec_create("my-container", ["cat", "/etc/hostname"])
      {:ok, output}  = Docker.Exec.exec_start(exec_id)
  """
  @spec exec_create(Docker.container_ref(), [binary()], Docker.options()) ::
          Docker.result(Docker.exec_id())
  def exec_create(container_ref, cmd, options \\ []) when is_list(cmd) do
    if sandbox?(options) do
      sandbox_exec_create_response(container_ref, cmd, options)
    else
      do_exec_create(container_ref, cmd, options)
    end
  end

  defp do_exec_create(container_ref, cmd, options) do
    url = "/containers/#{container_ref}/exec"

    payload =
      %{
        "AttachStdout" => true,
        "AttachStderr" => true,
        "AttachStdin" => Keyword.get(options, :attach_stdin, false),
        "Tty" => Keyword.get(options, :tty, false),
        "Cmd" => cmd
      }
      |> put_exec_option_if_present("Env", Keyword.get(options, :env))
      |> put_exec_option_if_present("User", Keyword.get(options, :user))
      |> put_exec_option_if_present("WorkingDir", Keyword.get(options, :workdir))

    case Client.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: %{"Id" => exec_id}}} when code in 200..299 ->
        {:ok, exec_id}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a previously created exec instance and returns its combined
  stdout and stderr output.

  Blocks until the exec process exits. For long-running commands or when
  you need a persistent shell, use `Docker.Terminal.open/2` instead.

  ## Parameters

    - `exec_id` — the ID returned by `exec_create/3`.
    - `options` — optional keyword list for daemon selection. See `Docker`.
      Also accepts `:detach` (boolean) to start without waiting for output.

  ## Returns

    - `{:ok, output}` — combined stdout and stderr as a binary, untrimmed.
      Trailing newlines and ANSI escape sequences are preserved.
    - `{:error, reason}` — exec instance not found or daemon returned an
      error.

  ## Examples

      {:ok, exec_id} = Docker.Exec.exec_create("my-container", ["echo", "hello"])
      {:ok, output}  = Docker.Exec.exec_start(exec_id)
      output  # => "hello\\n"
  """
  @spec exec_start(Docker.exec_id(), Docker.options()) :: Docker.result(binary())
  def exec_start(exec_id, options \\ []) do
    if sandbox?(options) do
      sandbox_exec_start_response(exec_id, options)
    else
      do_exec_start(exec_id, options)
    end
  end

  defp do_exec_start(exec_id, options) do
    options = Keyword.put_new(options, :receive_timeout, :infinity)
    options = Keyword.put_new(options, :into, :frame)
    url = "/exec/#{exec_id}/start"

    payload = %{
      "Detach" => Keyword.get(options, :detach, false),
      "Tty" => false
    }

    case Client.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, body}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current state of an exec instance.

  Use this after `exec_start/2` to find out whether the command has finished
  and what its exit code was. `exec_run_with_status/3` does create + start +
  inspect in one call — prefer it when you need the exit code.

  ## Parameters

    - `exec_id` — the ID returned by `exec_create/3`.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, map}` — a map with atom keys:
      - `:exit_code` — integer exit code, or `nil` if not yet exited.
      - `:running` — `true` if the exec process is still running.
    - `{:error, reason}` — exec instance not found or daemon returned an
      error.

  ## Examples

      {:ok, info} = Docker.Exec.exec_inspect(exec_id)
      info.exit_code  # 0 means success, anything else means failure
      info.running    # false once the command has finished
  """
  @spec exec_inspect(Docker.exec_id(), Docker.options()) :: Docker.result(Docker.json_map())
  def exec_inspect(exec_id, options \\ []) do
    if sandbox?(options) do
      sandbox_exec_inspect_response(exec_id, options)
    else
      do_exec_inspect(exec_id, options)
    end
  end

  defp do_exec_inspect(exec_id, options) do
    url = "/exec/#{exec_id}/json"

    case Client.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, Serializer.deserialize(body, options)}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates and starts an exec instance in one call and returns the combined
  stdout and stderr output.

  This is the function to reach for when you want to run a command and
  get its output without caring about the exit code. For the exit code,
  use `exec_run_with_status/3`. For an interactive shell, use
  `Docker.Terminal.open/2`.

  ## Parameters

    - `container_ref` — the container name or ID. Must be running.
    - `cmd` — the command as a list of strings: `["ls", "-la", "/etc"]`.
    - `options` — optional keyword list. Accepts the same keys as
      `exec_create/3` (`:env`, `:user`, `:workdir`, `:tty`). See `Docker`
      for daemon-selection keys.

  ## Returns

    - `{:ok, output}` — combined stdout and stderr, untrimmed.
    - `{:error, reason}` — container not found, not running, exec failed,
      or daemon returned an error.

  ## Examples

      {:ok, output} = Docker.Exec.exec_run("my-container", ["cat", "/etc/hostname"])

      # With environment variables
      {:ok, output} =
        Docker.Exec.exec_run("my-container", ["printenv", "MY_VAR"],
          env: ["MY_VAR=hello"])
  """
  @spec exec_run(Docker.container_ref(), [binary()], Docker.options()) ::
          Docker.result(binary())
  def exec_run(container_ref, cmd, options \\ []) when is_list(cmd) do
    if sandbox?(options) do
      sandbox_exec_run_response(container_ref, cmd, options)
    else
      do_exec_run(container_ref, cmd, options)
    end
  end

  defp do_exec_run(container_ref, cmd, options) do
    with {:ok, exec_id} <- exec_create(container_ref, cmd, options) do
      exec_start(exec_id, options)
    end
  end

  @doc """
  Creates and starts an exec instance in one call and returns the output
  plus the exit code.

  Like `exec_run/3` but also inspects the exec instance after it exits
  so callers can check whether the command succeeded.

  ## Parameters

    - `container_ref` — the container name or ID. Must be running.
    - `cmd` — the command as a list of strings.
    - `options` — optional keyword list. Same keys as `exec_run/3`.

  ## Returns

    - `{:ok, result}` — a map matching `t:Docker.exec_result/0`:
      - `:output` — combined stdout and stderr binary, untrimmed.
      - `:exit_code` — integer exit code (`0` = success), or `nil` if
        the daemon did not yet report one.
      - `:running` — `true` if the exec is still running at inspect time.
    - `{:error, reason}` — create, start, or inspect failed.

  ## Examples

      {:ok, %{output: out, exit_code: code}} =
        Docker.Exec.exec_run_with_status(
          "my-container",
          ["grep", "-r", "ERROR", "/var/log/app.log"]
        )

      if code == 0 do
        IO.puts("Found errors:\\n" <> out)
      else
        IO.puts("No errors found")
      end
  """
  @spec exec_run_with_status(Docker.container_ref(), [binary()], Docker.options()) ::
          Docker.result(Docker.exec_result())
  def exec_run_with_status(container_ref, cmd, options \\ []) when is_list(cmd) do
    if sandbox?(options) do
      sandbox_exec_run_with_status_response(container_ref, cmd, options)
    else
      do_exec_run_with_status(container_ref, cmd, options)
    end
  end

  defp do_exec_run_with_status(container_ref, cmd, options) do
    with {:ok, exec_id} <- exec_create(container_ref, cmd, options),
         {:ok, output} <- exec_start(exec_id, options),
         {:ok, inspect} <- exec_inspect(exec_id, options) do
      {:ok,
       %{
         output: output,
         exit_code: Map.get(inspect, :exit_code),
         running: Map.get(inspect, :running)
       }}
    end
  end

  defp put_exec_option_if_present(payload, _key, nil), do: payload
  defp put_exec_option_if_present(payload, _key, []), do: payload
  defp put_exec_option_if_present(payload, key, value), do: Map.put(payload, key, value)

  # ---------------------------------------------------------------------------
  # SANDBOX HELPERS
  # ---------------------------------------------------------------------------

  defp sandbox?(options) do
    sandbox_options = options[:sandbox] || []
    enabled = Keyword.get(sandbox_options, :enabled, false)
    enabled and not sandbox_disabled?()
  end

  if Code.ensure_loaded?(SandboxRegistry) do
    @doc false
    defdelegate sandbox_disabled?, to: Docker.Sandbox

    @doc false
    defdelegate sandbox_exec_create_response(container_ref, cmd, options),
      to: Docker.Sandbox,
      as: :exec_create_response

    @doc false
    defdelegate sandbox_exec_start_response(exec_id, options),
      to: Docker.Sandbox,
      as: :exec_start_response

    @doc false
    defdelegate sandbox_exec_inspect_response(exec_id, options),
      to: Docker.Sandbox,
      as: :exec_inspect_response

    @doc false
    defdelegate sandbox_exec_run_response(container_ref, cmd, options),
      to: Docker.Sandbox,
      as: :exec_run_response

    @doc false
    defdelegate sandbox_exec_run_with_status_response(container_ref, cmd, options),
      to: Docker.Sandbox,
      as: :exec_run_with_status_response
  else
    defp sandbox_disabled?, do: true

    defp sandbox_exec_create_response(container_ref, cmd, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      cmd: #{inspect(cmd)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_exec_start_response(exec_id, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      exec_id: #{inspect(exec_id)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_exec_inspect_response(exec_id, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      exec_id: #{inspect(exec_id)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_exec_run_response(container_ref, cmd, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      cmd: #{inspect(cmd)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_exec_run_with_status_response(container_ref, cmd, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      container_ref: #{inspect(container_ref)}
      cmd: #{inspect(cmd)}
      options: #{inspect(options)}
      """
    end
  end
end
