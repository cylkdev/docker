# How to use Docker Terminal

This guide shows how to send text into a process running inside a Docker
container and read back what that process writes in reply. You will see two
ways to do it:

1. **One-shot** — send a single command, get its output back, done.
2. **Persistent session** — open a connection once, exchange several
   messages over it, then close it.

Both ways are part of the same small API on the `Docker` module:

- `Docker.terminal_run/2`
- `Docker.terminal_open/2`
- `Docker.terminal_command/2`
- `Docker.terminal_close/1`

## Mental model

Think of every example as three actors:

```
  Your Elixir code  ──send──▶  process inside container  ──reply──▶  Your Elixir code
```

The process inside the container can be anything that reads from standard
input and writes to standard output. In this guide it will be a tiny shell
script that just echoes back whatever you send it, prefixed with `got:`.
That script stands in for any program you might eventually want to talk to
the same way — the API does not care what's on the other end.

## Prerequisites

You need:

- A running Docker daemon. If `docker ps` works in your shell, you're set.
- This project checked out, with dependencies installed (`mix deps.get`).
- The example container image built (one command — see below).

### Open an IEx session

From the repository root:

```sh
iex -S mix
```

Every snippet from here on is run inside that IEx session.

### Build the example image

```elixir
:ok = Docker.run_build_image("examples/terminal-example", "Dockerfile", "terminal-demo")
```

`run_build_image/5` builds the image and prints the build output to the
console as it streams in, the same way `docker build` does on the command
line. It's a thin wrapper around `Docker.build_image/5` — reach for that
one directly if you want the raw event stream instead.

The resulting image contains a single script, `/repl.sh`, which reads
lines from standard input and writes `got: <the line>` back for each one.
The container's entrypoint is `sleep infinity`, so once it's running it
just sits there waiting for you to talk to it.

### Start a container from the image

```elixir
{:ok, _id} = Docker.create_container("term-demo", "terminal-demo", %{})
{:ok, _}   = Docker.start_container("term-demo")
```

`"term-demo"` is the name you'll use in every call below.

## Pattern 1 — One-shot

Use this when you just need to run a command and read its output. Nothing
is remembered between calls — each `terminal_run` is its own self-contained
round trip.

```elixir
{:ok, output} = Docker.terminal_run("term-demo", "echo hello")
IO.puts(output)
# hello
```

The second argument can be either a string or an argv list:

- **String** — `"echo hello"` is run through `/bin/sh -c`, so shell
  features like pipes, redirects, and globbing all work.
- **Argv list** — `["echo", "hello"]` is executed directly. No shell is
  involved, so no shell features apply. Use this when you want to be sure
  the input isn't reinterpreted.

```elixir
{:ok, output} = Docker.terminal_run("term-demo", ["echo", "hello"])
# output => "hello\n"
```

If you also need the exit code (for example, to tell success from failure),
use the `_with_status` variant:

```elixir
{:ok, %{output: out, exit_code: code}} =
  Docker.terminal_run_with_status("term-demo", "ls /nope")

code  # => 1
out   # => "ls: /nope: No such file or directory\n"
```

## Pattern 2 — Persistent session

Use this when the thing on the other side keeps state between messages, or
when you want a single open connection to handle several exchanges. You
open it once, send and receive as many times as you need, then close it.

The example container ships with `/repl.sh`, which loops forever reading
one line and echoing `got: <line>` back. We open the session pointing the
shell at that script instead of `/bin/sh`. The recommended way is to
address the session by **the container name** — once you've opened it,
every subsequent call is just the name and the line:

```elixir
{:ok, _state} = Docker.terminal_open("term-demo", shell: ["/repl.sh"])

{:ok, reply1, "term-demo"} = Docker.terminal_command("term-demo", "ping")
{:ok, reply2, "term-demo"} = Docker.terminal_command("term-demo", "pong")

IO.puts(reply1)  # got: ping
IO.puts(reply2)  # got: pong

:ok = Docker.terminal_close("term-demo")
```

Under the hood `terminal_open/2` starts a `Docker.Terminal.Server` and
registers it in `Docker.Terminal.Registry` keyed by the container name.
Subsequent calls look up that registered process. Only one session per
container name may be open at a time; a second `terminal_open` for the
same name returns `{:error, {:already_started, pid}}`.

**The library decides a reply is "done" when the process goes quiet.** By
default it waits for 200 ms of silence after the process last wrote
something, then returns whatever it has. That's why the snippets above
just work for a simple echo — the script writes one line and then idles
waiting for the next input. If the process you're talking to is slower,
or if it has a recognisable end-of-reply marker, pass `:recv_mode` to
either `Docker.terminal_open/2` (to set a default for the whole session) or to
`Docker.terminal_command/3` (to override for a single call). See `Docker.Terminal`
for the full list of options.

### Alternative — thread the state struct

`terminal_open/2` also returns a `Docker.Terminal.State` value. You can
thread that through every call instead of using the container name. This
is the older form of the API; it is still fully supported.

```elixir
{:ok, state} = Docker.terminal_open("term-demo", shell: ["/repl.sh"])

{:ok, reply1, state} = Docker.terminal_command(state, "ping")
{:ok, reply2, state} = Docker.terminal_command(state, "pong")

:ok = Docker.terminal_close(state)
```

The state is immutable; each `terminal_command/3` returns an updated value
as the third element of the tuple. Use that returned value for the next
call. Don't mix the two forms against the same session — pick one or the
other, since they both drive the same underlying socket.

## Cleanup

When you're done, stop the container and remove it:

```elixir
Docker.stop_container("term-demo")
Docker.delete_container("term-demo")
```

## Where to go next

- `Docker.Terminal` — full docs for the API used in this guide, including
  all the options on `Docker.terminal_open/2` and `Docker.terminal_command/2`.
- `Docker.Exec` — the lower-level building block used by `Docker.terminal_run/2`.
  Reach for it only if `Docker.Terminal` doesn't fit.
- `Docker.Session` — the raw bidirectional streaming layer used by
  `Docker.terminal_open/2`. Useful when you need finer control over how bytes are
  sent and received.
