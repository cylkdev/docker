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

`SHELL` must be set to a non-empty value wherever the application runs, or it
will not start. Set it in Docker images, systemd units and cron jobs:

```dockerfile
ENV SHELL=/bin/sh
```

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

## Configuration

There is no application configuration. Both configurable values are call
options:

```elixir
Docker.ping(version: "1.45", socket_path: "/var/run/docker.sock")
```

The defaults are Docker Engine API version `"1.45"` and socket path
`"/var/run/docker.sock"`.

## Documentation

Full API docs are generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/docker).
