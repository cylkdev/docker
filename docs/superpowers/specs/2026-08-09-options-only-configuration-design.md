# Options-Only Configuration

**Date:** 2026-08-09
**Status:** Approved

## Goal

Remove every read of the application and system environment from the library.
Configuration arrives through the options keyword list that already flows
through every public function; defaults live in module attributes. Alongside
this, delete speculative and defensive code.

## Motivation

`Docker.Config` reads two values — `:version` and `:socket_path` — from
`config/config.exs` via `Application.fetch_env!/2`. For a library this is the
wrong mechanism twice over. A library's own `config/config.exs` does not apply
to projects that depend on it, so the values are unconfigurable by the people
who need to configure them. And reading them from a global makes every call
site depend on process-external state that tests must mutate to exercise.

Options are already threaded everywhere. Using them removes a module, a
config file, a directory, and a dependency without losing a capability.

## Part 1: Configuration

### Deletions

- `lib/docker/config.ex`
- `config/config.exs` and the `config/` directory
- `nimble_options` from `mix.exs` — declared but never referenced

### Defaults

`Docker.Client` owns both defaults and exposes them as functions:

```elixir
@default_version "1.45"
@default_socket_path "/var/run/docker.sock"

@doc "Docker Engine API version used when `:version` is not given."
@spec default_version() :: String.t()
def default_version, do: @default_version

@doc "Daemon socket used when `:socket_path` is not given."
@spec default_socket_path() :: String.t()
def default_socket_path, do: @default_socket_path
```

The two timeout literals already in the module join them, so every constant in
`Client` has one home:

```elixir
@drain_timeout 5_000
@stream_idle_timeout 60_000
```

`@drain_timeout` bounds `drain_async_body_loop/3`; `@stream_idle_timeout`
bounds `next_event/2`. Both are kept deliberately: `receive` without `after`
blocks forever, and a `Stream.resource` consumer has no supervisor above it to
break a deadlock. The 60-second idle timeout is part of the documented
behavior of `stream/4` under a stalled body.

### Resolution

Values resolve per call, at the point of use. No struct carries a resolved
configuration around — that would reconstruct `Docker.Config` with extra
steps.

Every `Config.socket_path()` becomes
`Keyword.get(options, :socket_path, @default_socket_path)`.

`prepend_version/2` collapses to
`Keyword.get(options, :version, @default_version)`. Its
`v when is_binary(v) and v !== ""` clause goes: a caller passing `version: ""`
is a caller bug, and the resulting `/v/containers/...` 404 reports it.

### Streaming

`Docker.Streaming` calls `Client.default_socket_path/0` and
`Client.default_version/0` rather than duplicating the literals.

This is the one change that is more than substitution. `open_attach/3` and
`open_exec_start/3` accept `opts` today but never pass it down.
`open_upgrade/4` gains an `opts` parameter so that `build_attach_path/2`, the
exec start path, the `OneOhOne.Endpoint`, and all three `upgrade_error`
clauses resolve from the same options list.

### Errors name the socket actually used

`Client.transport_error/3` and the `Streaming.upgrade_error` clauses
interpolate the resolved socket path, so a call made with a custom
`socket_path:` produces an error naming that socket rather than the default.
Both gain the options list as a parameter.

### Documentation

`Docker`'s moduledoc options table gains `:socket_path`. The `@typedoc` on
`t:options/0` changes from "Common keys: `:version`" to name both keys.

## Part 2: Unused surface

Criterion: a function whose only caller is the test written to cover it is
speculative, and both go. This applies to helper and glue surface, not to
Engine API endpoint coverage — "no internal caller" is the normal state for a
client library's public functions, not a smell.

### Deleted

| Item | Evidence |
|---|---|
| `Containers.container_running?/1,/2` and both `Docker` defdelegates | No callers in `lib` or `test` |
| `Log.log_build_event/1` | One-line alias for `log_pull_event/1`; only its own test calls it |
| `Log.warning/2` | Only `Log.debug/2` is used, by `SessionHandler` |
| `Log.error/2` | Same |

Their tests are deleted with them.

### Made private

`Exec.resize_path/3` becomes `defp`. It is public only so `exec_test.exs` can
assert its query string; it has a real caller inside `Exec`. The test that
pokes at it is deleted — `resize/4` is the contract.

### Explicitly kept

`put_archive/4`, `download_archive/4`, `stat_archive/3`,
`materialize_image/4`, `Util.create_tar/3`, `Session.send_message/4` and
`Docker.send_message/4`. Only tests call them, but they are documented Engine
API coverage and public convenience surface — the product, not speculation.

## Part 3: Speculative and defensive code

### The governing distinction

A guard that selects between clauses is control flow and stays. A guard on a
single-clause function is validation and goes.

`body_opts(body) when is_binary(body) or is_list(body)` dispatches — it stays.
`Terminal.close(container_ref) when is_binary(container_ref)` restates the
spec — it goes.

### Unreachable clauses

- `Client.decode_events/3`'s trailing `_other` clause. `into_mode` is only
  ever `:frame`, `:ndjson`, or `:raw`; the three preceding clauses are total.
- `Session.close/1`'s third clause `def close(%__MODULE__{}), do: :ok`, and
  the `when not is_nil(socket)` guard on the clause above it.
  `from_connection/2` always sets `socket` to a pid, so a struct with a nil
  socket cannot exist.
- `Client.presence/1` and the `|| generic_message(status)` at both of its call
  sites. It handles the daemon sending a blank `"message"`, which it does not
  do.

### Runtime re-validation of caller input

`Network.build_ipam_config/2`'s error clause and the matching `:ipam_subnet`
type check both return a hand-rolled `bad_request` for a non-string subnet or
gateway. Both are deleted. A bad value reaches the daemon, which returns its
own 400, which `Client` already converts to an `ErrorMessage` — same outcome,
one less hand-maintained validator, and the error comes from the authority on
what the Engine accepts.

### Single-clause validation guards

Removed from:

`Session.attach/2`, `Session.exec_session/3`, `Exec.exec_create/3`,
`Terminal.open/2` (both guards), `Terminal.command/3`, `Terminal.close/1`,
`Terminal.whereis/1`, `Terminal.start_link/1`, `Network.find_network/2`,
`Network.create_network/3`, `Network.delete_network/2`, `Util.create_tar/3`,
`Image.build_image/5`, `Instance.new/5`, `Frame.demux/1`, `Frame.demux_all/1`,
`Frame.decode_chunk/2`, `NDJSON.decode_chunk/2`, `Session.from_connection/2`,
`SessionHandler.connect/2`, `SessionHandler.handle_in/2`,
`Streaming.open_attach/3`, `Streaming.open_exec_start/3`.

### Kept

- `Client.classify_transport/1`'s final catch-all — reachable via exceptions
  raised while decoding a response the daemon did send.
- `Client.daemon_message/2`'s binary clause and its `JSON.decode` — `stream/4`
  drains error bodies as raw bytes, so the same 404 arrives here as text.
- `Image.build_context_tar/1`'s `_other_os` clause — real dispatch on
  `:os.type()`.
- OTP callbacks with unused parameters (`Application.start/2`,
  `Terminal.terminate/2`, `SessionHandler.terminate/2`).

## Scope

In: `lib/`, `test/`, `README.md`, and the `Docker` moduledoc.

`README.md`'s "Configuration" section shows a `config :docker, version:,
socket_path:` block. It is rewritten to show the same two values passed as
call options, with the defaults named.

Out: `docs/superpowers/` — a record of past work, not retconned. `docs/cve.md`
and `examples/` need no changes; neither references deleted surface or the
config file.

## Testing

`test/docker/client_test.exs` currently swaps `:socket_path` through
`Application.put_env/3` with an `on_exit` restore to assert the transport
error path. It is rewritten to pass `socket_path:` as a call option. This is
the change in miniature: the test stops mutating global state and starts
exercising the public interface, and no cleanup is needed because nothing
global was touched.

The assertion that `Config.version()` matches `~r/^\d+\.\d+$/` becomes the
same assertion against `Client.default_version/0`.

Tests for deleted functions are deleted. Everything else — the daemon-backed
suites under `DaemonCase` — should pass unchanged; they exercise the public
API, which keeps its shape.

Verification is `mix test`, `mix credo`, and `mix dialyzer`. Dialyzer matters
here: removing guards changes inferred types, and the project runs with
`:unmatched_returns`, so any clause that became genuinely unreachable in a way
this design did not anticipate will surface there.

## Risks

Removing public functions and guards is breaking. The library is at `0.1.0`
and unreleased, so the cost is low, but `container_running?/1,/2`,
`Log.warning/2`, and `Log.error/2` disappear from the public API.

Removing validation guards means bad arguments fail later and less legibly —
inside `Req`, or as a daemon 400, rather than as a `FunctionClauseError` at
the boundary. This is the accepted trade: the daemon is the authority on what
it accepts, and the library stops maintaining a second opinion.
