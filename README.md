# Docker

An Elixir client for the Docker Engine HTTP API. Reaches the local Docker
daemon over its Unix domain socket.

## Installation

Add `docker` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:docker, "~> 0.1.0"}
  ]
end
```

### The `SHELL` environment variable

`docker` depends on `:erlexec`, which refuses to start unless `SHELL` is set
to a non-empty value, so the whole application fails to boot without it. Your
own shell sets it, but Docker images, systemd units and cron jobs do not — set
it there yourself:

```dockerfile
ENV SHELL=/bin/sh
```

The value only has to be non-empty; it does not change how any command runs.
The systemd equivalent is `Environment=SHELL=/bin/sh`, and the cron equivalent
is a `SHELL=/bin/sh` line in the crontab.

## Quick start

The client talks to the daemon on the standard Unix socket
(`/var/run/docker.sock`):

```elixir
{:ok, "OK"} = Docker.ping()

{:ok, containers} = Docker.list_containers()
```

Every call accepts an optional keyword list of options.

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

  alias Docker.Sandbox

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
  # Default Docker Engine API version:
  version: "1.45",
  # The local daemon socket:
  socket_path: "/var/run/docker.sock"
```

## Documentation

Full API docs are generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/docker).
