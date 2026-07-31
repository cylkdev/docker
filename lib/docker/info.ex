defmodule Docker.Info do
  @moduledoc """
  Connection health checks for the Docker daemon.

  Use this module to verify the daemon is reachable before making other
  calls. Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.ping/1`).

  ## Example

      # Check the daemon is up
      {:ok, "OK"} = Docker.Info.ping()

  See `Docker` for the full client overview.
  """

  alias Docker.Client

  @doc """
  Asks the Docker daemon whether it is alive and responsive.

  This sends the smallest possible HTTP request (`GET /_ping`). Use it as a
  quick sanity check before making other calls.

  ## Parameters

    - `options` — optional keyword list. See `Docker` for the options
      table.

  ## Returns

    - `{:ok, "OK"}` — the daemon is reachable and answered.
    - `{:error, reason}` — the daemon could not be reached or returned an
      error. `reason` is typically an exception struct, an atom like
      `:timeout`, or a map `%{status: code, body: body}`.

  ## Examples

      # Connect to the local Docker daemon
      {:ok, "OK"} = Docker.Info.ping()

      # Connect to a remote daemon
      {:ok, "OK"} = Docker.Info.ping(host: "tcp://10.0.0.1:2375")
  """
  @spec ping(Docker.options()) :: Docker.result(binary())
  def ping(options \\ []) do
    if sandbox?(options) do
      sandbox_ping_response(options)
    else
      do_ping(options)
    end
  end

  defp do_ping(options) do
    case Client.request(:get, "/_ping", nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

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
    defdelegate sandbox_ping_response(options),
      to: Docker.Sandbox,
      as: :ping_response

  else
    defp sandbox_disabled?, do: true

    defp sandbox_ping_response(options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      options: #{inspect(options)}
      """
    end
  end
end
