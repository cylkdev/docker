defmodule Docker.Instance do
  @moduledoc """
  https://docs.docker.com/reference/api/engine/version/v1.51/

  ## Publishing ports

  Publishing a port provides the ability to break through a little bit of networking
  isolation by setting up a forwarding rule. As an example, you can indicate that
  requests on your host’s port 8080 should be forwarded to the container’s port 80.

  Publishing ports happens during container creation using the option
  `:port_bindings`.

  Example — forward host port 8080 to port 80 inside the container:

  ```elixir
  Docker.create_container("web", "nginx:alpine", %{},
    port_bindings: [
      %{
        protocol: "tcp",
        container_port: 80,
        host_port: 8080,
        host_ip: "0.0.0.0"
      }
    ]
  )
  ```

  * `:host_ip` - The port number on your host machine where you want to receive traffic.
   `"0.0.0.0"` means every interface, so the container is reachable from other machines;
   `"127.0.0.1"` keeps it on the local machine only.

  * `:container_port` - The port number within the container that's listening for connections.

  ```
  Your browser or another machine
              |
              | http://YOUR_MACHINE_IP:8080
              v
  +------------------------------------------------+
  | Your machine                                   |
  |                                                |
  |  Docker                                        |
  |  +------------------------------------------+  |
  |  | Docker's Published port rule             |  |
  |  |                                          |  |
  |  | Your machine:8080                        |  |
  |  |          |                               |  |
  |  |          | Docker forwards traffic       |  |
  |  |          v                               |  |
  |  |  +------------------------------------+  |  |
  |  |  | Docker container                   |  |  |
  |  |  |                                    |  |  |
  |  |  | Port 80 → nginx                    |  |  |
  |  |  +------------------------------------+  |  |
  |  +------------------------------------------+  |
  +------------------------------------------------+

  # or

  Your machine:8080 -> Docker -> Container:80
  ```
  """

  defstruct [
    :image,
    :name,
    :labels,
    :cmd,
    :env,
    :exposed_ports,
    :networking_config,
    :host_config,
    :tty,
    :open_stdin,
    :attach_stdin,
    :attach_stdout,
    :attach_stderr
  ]

  @group_label "elixir.docker.app"

  def new(group, name, image, labels, opts \\ []) when is_map(labels) and not is_struct(labels) do
    stdin? = Keyword.get(opts, :open_stdin, false)

    %__MODULE__{
      name: name,
      image: image,
      labels: Map.put(labels, @group_label, group),
      cmd: Keyword.get(opts, :cmd),
      env: Keyword.get(opts, :env),
      tty: Keyword.get(opts, :tty, false),
      open_stdin: stdin?,
      attach_stdin: stdin?,
      attach_stdout: stdin?,
      attach_stderr: stdin?,
      exposed_ports: build_exposed_ports(opts),
      networking_config: %{
        endpoints_config: build_endpoints_config(opts)
      },
      host_config: %{
        auto_remove: Keyword.get(opts, :auto_remove, false),
        binds: Keyword.get(opts, :binds),
        mounts: Keyword.get(opts, :mounts),
        network_mode: Keyword.get(opts, :network_mode),
        port_bindings: build_port_bindings(opts)
      }
    }
  end

  def to_map(%__MODULE__{} = spec) do
    %{
      "Image" => spec.image,
      "Name" => spec.name,
      "Labels" => spec.labels,
      "Cmd" => spec.cmd,
      "Env" => spec.env,
      "Tty" => spec.tty,
      "OpenStdin" => spec.open_stdin,
      "AttachStdin" => spec.attach_stdin,
      "AttachStdout" => spec.attach_stdout,
      "AttachStderr" => spec.attach_stderr,
      "ExposedPorts" => spec.exposed_ports,
      "NetworkingConfig" => %{
        "EndpointsConfig" => spec.networking_config.endpoints_config
      },
      "HostConfig" => %{
        "AutoRemove" => spec.host_config.auto_remove,
        "Binds" => spec.host_config.binds,
        "Mounts" => spec.host_config.mounts,
        "NetworkMode" => spec.host_config.network_mode,
        "PortBindings" => spec.host_config.port_bindings
      }
    }
  end

  defp build_endpoints_config(opts) do
    opts
    |> Keyword.get(:networks, [])
    |> Map.new(&{&1, %{}})
  end

  defp port_key(port, protocol) when is_integer(port) and protocol in ["tcp", "udp"] do
    "#{port}/#{protocol}"
  end

  defp build_exposed_ports(opts) do
    opts
    |> Keyword.get(:exposed_ports, [])
    |> Map.new(fn %{port: port, protocol: protocol} ->
      {port_key(port, protocol), %{}}
    end)
  end

  defp build_port_bindings(opts) do
    opts
    |> Keyword.get(:port_bindings, [])
    |> Enum.reduce(%{}, fn config, acc ->
      %{protocol: protocol, container_port: port, host_port: host_port, host_ip: host_ip} = config
      binding = %{"HostPort" => Integer.to_string(host_port), "HostIp" => host_ip}
      Map.update(acc, port_key(port, protocol), [binding], &(&1 ++ [binding]))
    end)
  end
end
