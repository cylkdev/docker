# Docker

An Elixir client for the Docker Engine HTTP API. Reaches a Docker daemon over
Unix domain sockets or TCP (with optional mTLS), honoring the same
`DOCKER_HOST`, `DOCKER_TLS_VERIFY`, and `DOCKER_CERT_PATH` environment variables
as the Docker CLI.

## Installation

Add `docker` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:docker, "~> 0.1.0"}
  ]
end
```

## Quick start

By default, the client talks to the daemon on the standard Unix socket
(`/var/run/docker.sock` or `~/.docker/run/docker.sock`):

```elixir
{:ok, "OK"} = Docker.ping()

{:ok, %{"Version" => version}} = Docker.version()

{:ok, containers} = Docker.list_containers()
```

Every call accepts an optional keyword list of options. The same keys (see
"Configuration" below) work for every function.

## Talking to a remote daemon

To reach a remote Docker daemon over TCP with mTLS, set the standard Docker CLI
environment variables before starting your app:

```sh
export DOCKER_HOST=tcp://10.0.0.1:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=$HOME/.docker/certs
```

`DOCKER_CERT_PATH` must contain `ca.pem`, `cert.pem`, and `key.pem`. With those
set, every `Docker.*` call routes to the remote daemon over TLS:

```elixir
{:ok, "OK"} = Docker.ping()
```

You can also override per-call without touching the environment:

```elixir
{:ok, "OK"} =
  Docker.ping(
    host: "tcp://10.0.0.1:2376",
    tls: %{
      verify: :verify_peer,
      cacertfile: "/path/to/ca.pem",
      certfile: "/path/to/cert.pem",
      keyfile: "/path/to/key.pem"
    }
  )
```

Endpoint values are cheap to build and contain no live connection — use
`Docker.endpoint/1` to inspect what a given options list will resolve to:

```elixir
{:ok, endpoint} = Docker.endpoint(host: "tcp://10.0.0.1:2376")
```

## Streaming endpoints

`Docker.pull_image/3` and `Docker.build_image/5` return `{:ok, Enumerable.t()}`
of decoded NDJSON event maps. Consume them with the standard `Stream` and
`Enum` modules. Discarding the stream early cancels the in-flight HTTP request:

```elixir
{:ok, events} = Docker.pull_image("alpine:3.19")

events
|> Stream.each(&Docker.Log.log_pull_event/1)
|> Stream.run()
```

To collect all events as a list (useful in tests):

```elixir
{:ok, events} = Docker.pull_image("alpine:3.19")
all_events = Enum.to_list(events)
```

## Attach and exec

For long-lived, full-duplex byte streams, `Docker.attach/2` and
`Docker.exec_session/3` return a `Docker.Streaming.Session`. The session is
pull-based: write with `send/2`, read with `recv/3`.

```elixir
{:ok, session} = Docker.attach("my-container", stdin: true, stdout: true, stderr: true)

Docker.Streaming.Session.send(session, "echo hello\n")

{:ok, frames} = Docker.Streaming.Session.recv(session, 5_000)

Docker.Streaming.Session.close(session)
```

Each frame is a `Docker.Frame` tagged with `:stdout`, `:stderr`, or `:stdin`,
plus the raw bytes the daemon emitted.

## Testing without a daemon

`Docker.Sandbox` lets tests register canned responses per-process so they
can run async without touching a real daemon. Pass `sandbox: [enabled: true]`
to opt a call into sandbox mode:

```elixir
defmodule MyAppTest do
  use ExUnit.Case, async: true

  alias Docker.Minty.Sandbox

  test "reports daemon as up" do
    Sandbox.set_ping_responses([fn -> {:ok, "OK"} end])

    assert {:ok, "OK"} = Docker.ping(sandbox: [enabled: true])
  end

  test "lists running containers" do
    Sandbox.set_list_containers_responses([
      fn -> {:ok, [%{"Id" => "abc", "Names" => ["/web"]}]} end
    ])

    assert {:ok, [%{"Id" => "abc"}]} =
             Docker.list_containers(sandbox: [enabled: true])
  end
end
```

Each `set_<action>_responses/1` accepts a list of zero-arg functions; the
sandbox calls them in order on each invocation. See `Docker.Sandbox` for
the full registration API.

## Configuration

Defaults can be set in `config/config.exs`:

```elixir
config :docker,
  # Default endpoint (a Docker.Endpoint struct):
  endpoint: %Docker.Endpoint{
    minty: %OneOhOne.Endpoint{
      transport: :unix,
      socket_path: "/var/run/docker.sock"
    },
    version: "1.45"
  },
  # ...or just a unix socket path for the legacy default:
  socket_path: "/var/run/docker.sock",
  # Default Docker Engine API version:
  version: "1.45"
```

### Endpoint resolution precedence

For each call, the client picks the first source that yields an endpoint:

1. The `:endpoint` option (a `Docker.Minty.Endpoint` value).
2. The `:host` option (URL string).
3. The `:socket` option (unix socket path).
4. The `DOCKER_HOST` environment variable.
5. `Application.get_env(:docker, :endpoint)`.
6. `Application.get_env(:docker, :socket_path)`.
7. The standard filesystem socket paths (`~/.docker/run/docker.sock`,
   `/var/run/docker.sock`).

See `Docker.Endpoint.from_options/1` for the authoritative rules.

## SSH daemons

`ssh://` URLs work only with the streaming session API (`attach/2`,
`exec_session/3`, `send_message/4`), which routes through
[OneOhOne](https://github.com/cylkdev/oneoone). Unary HTTP calls
(`ping`, `version`, `list_containers`, etc.) use `Req`, which does not
speak SSH — passing `ssh://` to those returns
`{:error, :ssh_not_supported_for_unary}`. Build the endpoint struct
directly (carrying a pre-built `%OneOhOne.Endpoint{transport: :ssh, ...}`
with `:target` and `:ssh` auth) and pass it via `options[:endpoint]`.

## Documentation

Full API docs are generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/docker).
