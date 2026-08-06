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
    - `{:error, error}` — an `t:ErrorMessage.t/0`. A daemon that is not
      running gives `:service_unavailable`; a socket the current user may
      not open gives `:forbidden`.

  ## Examples

      {:ok, "OK"} = Docker.Info.ping()
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
      {:ok, %{body: body}} -> {:ok, body}
      {:error, %ErrorMessage{} = error} -> {:error, error}
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
