defmodule Docker.Network do
  @moduledoc """
  Network management for Docker containers.

  A Docker network is a private virtual switch. Containers joined to the same
  network can reach each other by container name as a hostname. Containers on
  different networks are isolated from each other unless you explicitly connect
  them.

  Use this module to create isolated networks for groups of containers,
  connect containers to those networks, and clean up networks after use.
  Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.create_network/3`). See `Docker` for the full client overview.

  ## Example

      # Create a network
      {:ok, net_id} = Docker.Network.create_network("my-net", %{})

      # Connect two containers to it so they can reach each other
      {:ok, _} = Docker.Network.connect_network("my-net", "app-server")
      {:ok, _} = Docker.Network.connect_network("my-net", "database")

      # Inside "app-server", the database is reachable at hostname "database"

      # Clean up
      :ok = Docker.Network.delete_network("my-net")
  """

  alias Docker.Client
  alias Docker.Util

  @doc """
  Returns a list of all networks currently known to the daemon.

  ## Parameters

    - `params` — optional map of Docker Engine query parameters.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, [map]}` — list of network maps with string keys including
      `"Id"`, `"Name"`, `"Driver"`, and `"Containers"`.
    - `{:error, reason}` — daemon not reachable or returned an error.

  ## Examples

      {:ok, networks} = Docker.Network.list_networks()
      Enum.map(networks, & &1["Name"])
  """
  @spec list_networks(Docker.params(), Docker.options()) :: Docker.result(Docker.json_list())
  def list_networks(params \\ %{}, options \\ []) do
    if sandbox?(options) do
      sandbox_list_networks_response(params, options)
    else
      do_list_networks(params, options)
    end
  end

  defp do_list_networks(params, options) do
    url = Util.append_query_string("/networks", params)

    case Client.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a single network by name or ID.

  ## Parameters

    - `network_id` — the network name (e.g. `"my-net"`) or its full ID.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, map}` — network details map with string keys including `"Id"`,
      `"Name"`, `"Driver"`, and `"Containers"` (a map of container IDs
      currently connected).
    - `{:error, %{status: 404, body: _}}` — no network matched.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      {:ok, net} = Docker.Network.find_network("my-net")
      net["Id"]      # full network ID
      net["Driver"]  # e.g. "bridge"
  """
  @spec find_network(Docker.network_ref(), Docker.options()) :: Docker.result(Docker.json_map())
  def find_network(network_id, options \\ []) when is_binary(network_id) do
    if sandbox?(options) do
      sandbox_find_network_response(network_id, options)
    else
      do_find_network(network_id, options)
    end
  end

  defp do_find_network(network_id, options) do
    url = "/networks/#{network_id}"

    case Client.request(:get, url, nil, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new Docker network.

  `name` is required. `labels` is a map of string key-value pairs you can use
  to tag the network with metadata and find it later. Most callers pass `%{}`
  for `labels` unless they need filtering.

  ## Parameters

    - `name` — the name to give the network. Must be unique on the daemon.
    - `labels` — a `%{binary() => binary()}` map of metadata. Example:
      `%{"env" => "staging", "project" => "my-app"}`. Pass `%{}` for none.
    - `options` — optional keyword list. Recognised keys:

  ## Options

    * `:driver` — network driver (default `"bridge"`). Other values depend
      on what plugins the daemon has installed.
    * `:internal` — boolean. When `true`, the network has no outbound
      internet access (default `false`).
    * `:attachable` — boolean. When `true`, standalone containers can
      attach (default `false`).
    * `:ipam_subnet` — CIDR subnet string (default `"172.28.0.0/20"`).
      Pass `nil` to omit IPAM config entirely.
    * `:ipam_gateway` — gateway IP string within the subnet. Optional.

  ## Returns

    - `{:ok, network_id}` — the full ID of the newly created network.
    - `{:error, reason}` — daemon not reachable or returned an error.

  ## Examples

      # Minimal — bridge network, no labels
      {:ok, net_id} = Docker.Network.create_network("my-net", %{})

      # With labels for later filtering
      {:ok, net_id} =
        Docker.Network.create_network("staging-net", %{"env" => "staging"})

      # Custom subnet
      {:ok, net_id} =
        Docker.Network.create_network("my-net", %{},
          ipam_subnet: "192.168.100.0/24",
          ipam_gateway: "192.168.100.1"
        )
  """
  @spec create_network(binary(), Docker.labels(), Docker.options()) :: Docker.result(binary())
  def create_network(name, labels, options \\ []) when is_binary(name) do
    if sandbox?(options) do
      sandbox_create_network_response(name, labels, options)
    else
      do_create_network(name, labels, options)
    end
  end

  defp do_create_network(name, labels, options) do
    url = "/networks/create"

    payload = %{
      "Name" => name,
      "Driver" => Keyword.get(options, :driver, "bridge"),
      "Internal" => Keyword.get(options, :internal, false),
      "Attachable" => Keyword.get(options, :attachable, false),
      "Labels" => labels
    }

    payload = put_network_ipam(payload, options)

    case Client.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: %{"Id" => id}}} when code in 200..299 ->
        {:ok, id}

      {:ok, %{status: code, body: body}} ->
        {:error, %{status: code, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_network_ipam(payload, options) do
    case Keyword.get(options, :ipam_subnet, "172.28.0.0/20") do
      nil ->
        payload

      subnet when is_binary(subnet) ->
        ipam_config = build_ipam_config(subnet, Keyword.get(options, :ipam_gateway))
        Map.put(payload, "IPAM", %{"Config" => [ipam_config]})

      other ->
        raise "Expected ipam_subnet to be a string, got: #{inspect(other)}"
    end
  end

  defp build_ipam_config(subnet, nil), do: %{"Subnet" => subnet}

  defp build_ipam_config(subnet, gateway) when is_binary(gateway),
    do: %{"Subnet" => subnet, "Gateway" => gateway}

  defp build_ipam_config(_subnet, other),
    do: raise("Expected ipam_gateway to be a string, got: #{inspect(other)}")

  @doc """
  Connects a running container to a network.

  Once connected, the container can reach other containers on the same
  network by their container name as a hostname.

  ## Parameters

    - `network_id` — the network name or ID.
    - `container_ref` — the container name or ID to connect.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `{:ok, _}` — container is now connected to the network.
    - `{:error, %{status: 404, body: _}}` — network or container not found.
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      {:ok, _} = Docker.Network.connect_network("my-net", "my-container")
  """
  @spec connect_network(Docker.network_ref(), Docker.container_ref(), Docker.options()) ::
          Docker.result(Docker.json_map() | binary())
  def connect_network(network_id, container_ref, options \\ [])
      when is_binary(network_id) and is_binary(container_ref) do
    if sandbox?(options) do
      sandbox_connect_network_response(network_id, container_ref, options)
    else
      do_connect_network(network_id, container_ref, options)
    end
  end

  defp do_connect_network(network_id, container_ref, options) do
    url = "/networks/#{network_id}/connect"

    payload = %{"Container" => container_ref}

    case Client.request(:post, url, {:json, payload}, options) do
      {:ok, %{status: code, body: body}} when code in 200..299 -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, %{status: code, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a Docker network by name or ID.

  The network must have no containers connected to it. Disconnect all
  containers first with `connect_network/3` or by stopping and removing them.

  ## Parameters

    - `network_id` — the network name or ID to remove.
    - `options` — optional keyword list for daemon selection. See `Docker`.

  ## Returns

    - `:ok` — network removed.
    - `{:error, %{status: 404, body: _}}` — network not found.
    - `{:error, %{status: 409, body: _}}` — network still has active
      endpoints (containers connected).
    - `{:error, reason}` — daemon not reachable or returned another error.

  ## Examples

      :ok = Docker.Network.delete_network("my-net")
  """
  @spec delete_network(Docker.network_ref(), Docker.options()) ::
          :ok | {:error, Docker.error_reason()}
  def delete_network(network_id, options \\ []) when is_binary(network_id) do
    if sandbox?(options) do
      sandbox_delete_network_response(network_id, options)
    else
      do_delete_network(network_id, options)
    end
  end

  defp do_delete_network(network_id, options) do
    url = "/networks/#{network_id}"

    case Client.request(:delete, url, nil, options) do
      {:ok, %{status: code}} when code in 200..299 -> :ok
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
    defdelegate sandbox_list_networks_response(params, options),
      to: Docker.Sandbox,
      as: :list_networks_response

    @doc false
    defdelegate sandbox_find_network_response(network_id, options),
      to: Docker.Sandbox,
      as: :find_network_response

    @doc false
    defdelegate sandbox_create_network_response(name, labels, options),
      to: Docker.Sandbox,
      as: :create_network_response

    @doc false
    defdelegate sandbox_connect_network_response(network_id, container_ref, options),
      to: Docker.Sandbox,
      as: :connect_network_response

    @doc false
    defdelegate sandbox_delete_network_response(network_id, options),
      to: Docker.Sandbox,
      as: :delete_network_response
  else
    defp sandbox_disabled?, do: true

    defp sandbox_list_networks_response(params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_find_network_response(network_id, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      network_id: #{inspect(network_id)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_create_network_response(name, labels, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      name: #{inspect(name)}
      labels: #{inspect(labels)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_connect_network_response(network_id, container_ref, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      network_id: #{inspect(network_id)}
      container_ref: #{inspect(container_ref)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_delete_network_response(network_id, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      network_id: #{inspect(network_id)}
      options: #{inspect(options)}
      """
    end
  end
end
