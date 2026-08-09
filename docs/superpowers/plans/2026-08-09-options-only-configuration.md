# Options-Only Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every read of the application and system environment from the library, replacing them with options and module-attribute defaults, and delete the speculative and defensive code the codebase has accumulated.

**Architecture:** `Docker.Client` becomes the single owner of the library's constants — two configuration defaults and two timeouts — exposed as functions for `Docker.Streaming` to call. Configuration resolves per call from the options keyword list that already threads through every public function; nothing caches a resolved config. `Docker.Config`, `config/config.exs`, and the `config/` directory are deleted.

**Tech Stack:** Elixir ~> 1.18, Req (HTTP over Unix socket), OneOhOne (connection upgrade for streaming), ErrorMessage, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-09-options-only-configuration-design.md`

## Global Constraints

- Default Engine API version is exactly `"1.45"`.
- Default socket path is exactly `"/var/run/docker.sock"`.
- Drain timeout is exactly `5_000`; stream idle timeout is exactly `60_000`.
- No module may call `Application.*` or `System.get_env`/`System.fetch_env` for configuration after Task 3. (`System.tmp_dir!/0` and `System.unique_integer/1` in tests are not configuration and stay.)
- The governing rule for guard removal: **a guard that selects between clauses is control flow and stays; a guard on a single-clause function is validation and goes.**
- Most tests require a running Docker daemon (`DaemonCase`). Verify Docker is running before starting: `docker info` should succeed.
- Full verification is `mix test`, `mix credo`, and `mix dialyzer`. The project runs Dialyzer with `:unmatched_returns`.
- Commit directly to `main`. No feature branches in this repo.

---

### Task 1: `Docker.Client` owns its constants and resolves from options

`Client` currently calls `Docker.Config.socket_path/0` and `Config.version()` in five places and inlines two timeout literals. This task moves all four constants into module attributes, exposes the two configuration defaults as functions, and threads `options` into the two error builders so an error names the socket the call actually used.

**Files:**
- Modify: `lib/docker/client.ex`
- Test: `test/docker/client_test.exs:54:71` (the "a daemon that is not there" describe block and the version-prefix test)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Docker.Client.default_version() :: String.t()` — returns `"1.45"`
  - `Docker.Client.default_socket_path() :: String.t()` — returns `"/var/run/docker.sock"`
  - Both are called by `Docker.Streaming` in Task 2.
  - `Client.request/4` and `Client.stream/4` accept `:socket_path` and `:version` in their options list.

- [ ] **Step 1: Write the failing test**

Replace the entire `describe "a daemon that is not there"` block (`test/docker/client_test.exs:54:71`) with the version below. The old block swapped `:socket_path` through `Application.put_env/3` and restored it in `on_exit`; the new one passes the path as a call option, so there is no global state to restore and no `setup` block at all.

```elixir
  describe "a daemon that is not there" do
    test "a missing socket is :service_unavailable" do
      missing = Path.join(System.tmp_dir!(), unique_name("docker-absent"))

      assert {:error, %ErrorMessage{code: :service_unavailable} = error} =
               Docker.ping(socket_path: missing)

      assert error.message =~ "Could not reach the Docker daemon"
      assert error.message =~ missing
      assert %{socket_path: ^missing} = error.details
    end
  end
```

In the same file, replace the version-prefix test body so it asserts against the new function instead of `Config.version()`:

```elixir
  describe "the API version prefix" do
    test "requests carry the default version" do
      assert {:ok, _} = Docker.ping()
      assert Docker.Client.default_version() =~ ~r/^\d+\.\d+$/
    end
  end
```

Also delete the `alias Docker.Config` line at `test/docker/client_test.exs:12`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/docker/client_test.exs`
Expected: FAIL. The `default_version` test fails with `UndefinedFunctionError` for `Docker.Client.default_version/0`. The missing-socket test fails on `assert error.message =~ missing` — the message still names `/var/run/docker.sock` because `:socket_path` is ignored today.

- [ ] **Step 3: Add the module attributes and accessor functions**

In `lib/docker/client.ex`, delete the `alias Docker.Config` line and add the attributes and accessors immediately after the `@type response` line (around line 51):

```elixir
  @default_version "1.45"
  @default_socket_path "/var/run/docker.sock"

  # A partial error body is better than hanging: this drain only ever runs to
  # populate the body of an already-failed (non-2xx) response.
  @drain_timeout 5_000

  # `receive` without `after` blocks forever, and a Stream.resource consumer has
  # no supervisor above it to break a deadlock.
  @stream_idle_timeout 60_000

  @doc """
  The Docker Engine API version used when `:version` is not given.
  """
  @spec default_version() :: String.t()
  def default_version, do: @default_version

  @doc """
  The daemon socket used when `:socket_path` is not given.
  """
  @spec default_socket_path() :: String.t()
  def default_socket_path, do: @default_socket_path
```

- [ ] **Step 4: Resolve the socket path from options**

In `build_req_opts/5`, replace `unix_socket: Config.socket_path(),` with:

```elixir
        unix_socket: Keyword.get(options, :socket_path, @default_socket_path),
```

- [ ] **Step 5: Thread options into the transport error builders**

`transport_error/3` and `classify_transport/1` interpolate the socket path, so both need the options list. Change the two call sites in `do_request/4` and `do_stream/4` from `transport_error(exception, method, full_path)` to `transport_error(exception, method, full_path, options)`, then rewrite the functions:

```elixir
  @spec transport_error(Exception.t(), method(), String.t(), keyword()) :: ErrorMessage.t()
  defp transport_error(exception, method, path, options) do
    socket_path = Keyword.get(options, :socket_path, @default_socket_path)
    {code, message} = classify_transport(exception, socket_path)

    apply(ErrorMessage, code, [
      message,
      %{reason: exception, method: method, path: path, socket_path: socket_path}
    ])
  end

  # Req wraps the POSIX reason; the reason is what distinguishes "Docker isn't
  # running" from "the daemon hung up mid-request", and both are worth telling
  # apart at the call site.
  defp classify_transport(%{reason: reason}, _socket_path) when reason in [:timeout, :etimedout] do
    {:gateway_timeout, "Timed out waiting for the Docker daemon"}
  end

  defp classify_transport(%{reason: reason}, socket_path) when reason in [:eacces, :eperm] do
    {:forbidden,
     "Permission denied opening the Docker socket at #{socket_path}. " <>
       "Check that the current user may access it."}
  end

  defp classify_transport(%{reason: reason}, socket_path)
       when reason in [:econnrefused, :enoent] do
    {:service_unavailable,
     "Could not reach the Docker daemon at #{socket_path}. " <>
       "Check that Docker is running."}
  end

  defp classify_transport(%{reason: reason}, _socket_path)
       when reason in [:closed, :econnreset, :epipe] do
    {:bad_gateway, "The connection to the Docker daemon closed unexpectedly"}
  end

  # Everything above carries a POSIX reason, so it really was the connection.
  # What is left is an exception raised while processing a response the daemon
  # did send — a body that would not decode, most often — which is a bad
  # upstream reply rather than an unreachable daemon.
  defp classify_transport(exception, _socket_path) do
    {:bad_gateway,
     "The Docker daemon returned a response this client could not read: " <>
       Exception.message(exception)}
  end
```

Note the guards here stay: they dispatch between five clauses.

- [ ] **Step 6: Resolve the version from options**

Replace `prepend_version/2` entirely. The `v when is_binary(v) and v !== ""` clause goes — a caller passing `version: ""` is a caller bug, and the resulting `/v/containers/...` 404 reports it:

```elixir
  @spec prepend_version(String.t(), keyword()) :: String.t()
  defp prepend_version(path, options) do
    if Regex.match?(~r{^/v\d}, path) do
      path
    else
      "/v" <> Keyword.get(options, :version, @default_version) <> path
    end
  end
```

- [ ] **Step 7: Replace the two inline timeout literals**

In `drain_async_body_loop/3`, replace the `after` clause — the justifying comment moves to the attribute definition in Step 3, so it is not duplicated here:

```elixir
    after
      @drain_timeout -> IO.iodata_to_binary(acc)
    end
```

In `next_event/2`, replace its `after` clause:

```elixir
    after
      @stream_idle_timeout ->
        raise RuntimeError, "Docker stream stalled: no data received within the idle timeout"
    end
```

- [ ] **Step 8: Update the moduledoc**

In the `Docker.Client` moduledoc, replace the sentence reading `over Req's `:unix_socket` option at `Docker.Config.socket_path/0`.` with:

```
  over Req's `:unix_socket` option, at `options[:socket_path]` or
  `default_socket_path/0` when that is not given.
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `mix test test/docker/client_test.exs`
Expected: PASS, all tests in the file.

- [ ] **Step 10: Verify nothing else in Client still references Config**

Run: `grep -n "Config" lib/docker/client.ex`
Expected: no output.

- [ ] **Step 11: Commit**

```bash
git add lib/docker/client.ex test/docker/client_test.exs
git commit -m "refactor(client): resolve socket path and version from options"
```

---

### Task 2: `Docker.Streaming` threads options through the upgrade

`open_attach/3` and `open_exec_start/3` accept `opts` today but never pass it below `build_attach_path/2`. The endpoint, the exec path, and all three `upgrade_error` clauses read globals instead. This task threads one options list through the whole module.

**Files:**
- Modify: `lib/docker/streaming.ex`
- Test: `test/docker/streaming/session_test.exs` (no changes expected — verification only)

**Interfaces:**
- Consumes: `Docker.Client.default_version/0` and `Docker.Client.default_socket_path/0` from Task 1.
- Produces: `Streaming.open_attach/3` and `Streaming.open_exec_start/3` keep their arity and signature; their `opts` argument now also accepts `:socket_path` and `:version`.

- [ ] **Step 1: Write the failing test**

Create `test/docker/streaming_test.exs`:

```elixir
defmodule Docker.StreamingTest do
  @moduledoc "Option threading through the streaming upgrade."

  use ExUnit.Case, async: true

  test "a missing socket names the socket the call was given" do
    missing = Path.join(System.tmp_dir!(), "docker-absent-#{System.unique_integer([:positive])}")

    assert {:error, %ErrorMessage{code: :service_unavailable} = error} =
             Docker.Streaming.open_attach("nonexistent", false, socket_path: missing)

    assert error.message =~ missing
    assert %{socket_path: ^missing} = error.details
  end

  test "the attach path carries the version the call was given" do
    missing = Path.join(System.tmp_dir!(), "docker-absent-#{System.unique_integer([:positive])}")

    assert {:error, %ErrorMessage{details: %{path: path}}} =
             Docker.Streaming.open_attach("nonexistent", false,
               socket_path: missing,
               version: "1.99"
             )

    assert path =~ "/v1.99/containers/nonexistent/attach"
  end
end
```

This test needs no daemon: it points at a socket that does not exist and asserts on the resulting error, so it uses `ExUnit.Case` rather than `DaemonCase`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/docker/streaming_test.exs`
Expected: FAIL. Both tests fail because the error names `/var/run/docker.sock` and the path carries `/v1.45/`, since `opts` never reaches `open_upgrade/4` or `build_attach_path/2`.

- [ ] **Step 3: Thread opts into open_upgrade**

In `lib/docker/streaming.ex`, delete the `alias Docker.Config` line and add `alias Docker.Client`. Then rewrite the two public functions and `open_upgrade` — note the guards are removed here per the Task 6 rule, since this task rewrites these heads anyway:

```elixir
  def open_attach(container_ref, tty, opts) do
    open_upgrade(:post, build_attach_path(container_ref, opts), "", tty, opts)
  end

  def open_exec_start(exec_id, tty, opts) do
    body = JSON.encode!(%{"Detach" => false, "Tty" => tty})
    path = "/v#{version(opts)}/exec/#{exec_id}/start"

    open_upgrade(:post, path, body, tty, opts)
  end

  # `OneOhOne` sends only `host` and `content-length` for us; the upgrade
  # headers the Engine API expects have to come from the caller.
  defp open_upgrade(method, path, body, tty, opts) do
    upgrade = %{
      method: method,
      path: path,
      body: body,
      headers: [
        {"upgrade", "tcp"},
        {"connection", "Upgrade"},
        {"content-type", "application/json"}
      ]
    }

    start_opts = [
      endpoint: %OneOhOne.Endpoint{transport: :unix, socket_path: socket_path(opts)},
      upgrade: upgrade,
      params: %{owner: self()}
    ]

    case OneOhOne.start_link(SessionHandler, start_opts) do
      {:ok, conn_pid} ->
        {:ok, Session.from_connection(conn_pid, tty)}

      {:error, reason} ->
        {:error, upgrade_error(reason, path, opts)}
    end
  end

  defp socket_path(opts), do: Keyword.get(opts, :socket_path, Client.default_socket_path())
  defp version(opts), do: Keyword.get(opts, :version, Client.default_version())
```

- [ ] **Step 4: Thread opts into the upgrade error builders**

Replace all four `upgrade_error` clauses:

```elixir
  # The upgrade never completed, so there is no HTTP status to read a code
  # from — only the reason OneOhOne failed with.
  defp upgrade_error(%ErrorMessage{} = error, _path, _opts), do: error

  defp upgrade_error({:shutdown, reason}, path, opts), do: upgrade_error(reason, path, opts)

  defp upgrade_error(reason, path, opts) when reason in [:enoent, :econnrefused] do
    ErrorMessage.service_unavailable(
      "Could not reach the Docker daemon at #{socket_path(opts)}. " <>
        "Check that Docker is running.",
      %{reason: reason, path: path, socket_path: socket_path(opts)}
    )
  end

  defp upgrade_error(reason, path, opts) when reason in [:eacces, :eperm] do
    ErrorMessage.forbidden(
      "Permission denied opening the Docker socket at #{socket_path(opts)}. " <>
        "Check that the current user may access it.",
      %{reason: reason, path: path, socket_path: socket_path(opts)}
    )
  end

  defp upgrade_error(reason, path, opts) do
    ErrorMessage.bad_gateway(
      "Could not open a streaming session with the Docker daemon: #{inspect(reason)}",
      %{reason: reason, path: path, socket_path: socket_path(opts)}
    )
  end
```

- [ ] **Step 5: Resolve the version in the attach path**

In `build_attach_path/2`, replace the final line:

```elixir
    "/v#{version(opts)}/containers/#{container_ref}/attach?#{query}"
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/docker/streaming_test.exs test/docker/streaming/session_test.exs`
Expected: PASS.

- [ ] **Step 7: Verify Streaming no longer references Config**

Run: `grep -n "Config" lib/docker/streaming.ex`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add lib/docker/streaming.ex test/docker/streaming_test.exs
git commit -m "refactor(streaming): thread options through the upgrade"
```

---

### Task 3: Delete `Docker.Config`, `config/`, and `nimble_options`

Nothing reads them after Tasks 1 and 2. This task removes them and fixes the documentation that describes the old mechanism.

**Files:**
- Delete: `lib/docker/config.ex`, `config/config.exs`, `config/`
- Modify: `mix.exs`, `lib/docker.ex`, `README.md:83:92`

**Interfaces:**
- Consumes: Tasks 1 and 2 must be complete — `Docker.Config` must have no callers.
- Produces: nothing new.

- [ ] **Step 1: Verify Config has no remaining callers**

Run: `grep -rn "Docker.Config\|Config\." lib test --include="*.ex" --include="*.exs" | grep -v "^lib/docker/config.ex" | grep -v "HostConfig\|Config.User"`
Expected: no output. (The `grep -v` filters out `Docker.Instance`'s documentation table, which references the Docker Engine's own `HostConfig`/`Config.User` API fields — unrelated to `Docker.Config`.)

If this produces output, stop: an earlier task is incomplete.

- [ ] **Step 2: Delete the module, the config file, and the dependency**

```bash
git rm lib/docker/config.ex config/config.exs
rmdir config
```

In `mix.exs`, delete this line from `defp deps do`:

```elixir
      {:nimble_options, "~> 1.1"}
```

The preceding line `{:elixir_exec, github: "cylkdev/elixir_exec", branch: "main"},` must lose its trailing comma so the list stays valid.

- [ ] **Step 3: Verify nimble_options was genuinely unused, then refresh the lock**

Run: `grep -rn "NimbleOptions" lib test`
Expected: no output.

Run: `mix deps.unlock nimble_options && mix deps.get`
Expected: succeeds; `mix.lock` loses its `nimble_options` entry.

- [ ] **Step 4: Update the `Docker` moduledoc**

In `lib/docker.ex`, replace the "Connecting to a daemon" section (around line 184) — the current text claims "There is nothing to configure per call", which is now the opposite of true:

```
  ## Connecting to a daemon

  Every call reaches the local daemon over a Unix socket. By default that
  is `/var/run/docker.sock`; pass `:socket_path` to use another:

      Docker.ping()
      Docker.ping(socket_path: "/run/user/1000/docker.sock")

  The Engine API version prefixed onto request paths defaults to `"1.45"`
  and is overridden the same way, with `:version`. Both defaults are
  readable as `Docker.Client.default_socket_path/0` and
  `Docker.Client.default_version/0`.
```

Then replace the `t:options/0` typedoc (around line 219):

```elixir
  @typedoc """
  Options keyword list accepted by every public function. Common keys:
  `:socket_path` (defaults to `/var/run/docker.sock`) and `:version`
  (defaults to `"1.45"`).
  """
  @type options :: keyword()
```

- [ ] **Step 5: Update the README**

In `README.md`, replace the whole `## Configuration` section (lines 83-92) — the `config :docker` block it shows would no longer do anything:

````markdown
## Configuration

There is no application configuration. Both configurable values are call
options, with these defaults:

```elixir
# Defaults: socket_path: "/var/run/docker.sock", version: "1.45"
Docker.ping()

# Override either per call
Docker.ping(socket_path: "/run/user/1000/docker.sock", version: "1.44")
```

Every public function accepts them, since they flow through the same
options list as every other option.
````

- [ ] **Step 6: Verify the whole suite still passes**

Run: `mix test`
Expected: PASS. No compile warning about an undefined `Docker.Config`.

- [ ] **Step 7: Verify no application or system environment reads remain**

Run: `grep -rn "Application.get_env\|Application.fetch_env\|Application.compile_env\|Application.put_env\|System.get_env\|System.fetch_env" lib test`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: delete Docker.Config, config/, and nimble_options"
```

---

### Task 4: Delete unused surface

Four functions whose only callers are the tests written to cover them, plus one that is public only so a test can reach it.

**Files:**
- Modify: `lib/docker/containers.ex:735:783`, `lib/docker.ex:338:339`, `lib/docker/log.ex`, `lib/docker/exec.ex:285:289`
- Test: `test/docker/logger_test.exs`, `test/docker/engine/exec_test.exs:6:10`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Docker.Exec.resize_path/3` is no longer public. `Docker.Containers.container_running?/1,/2`, `Docker.container_running?/1,/2`, `Docker.Log.warning/2`, `Docker.Log.error/2`, and `Docker.Log.log_build_event/1` no longer exist.

- [ ] **Step 1: Confirm each deletion target has no caller**

Run:

```bash
grep -rn "container_running?\|log_build_event\|Log\.warning\|Log\.error" lib test README.md examples
```

Expected: only the definitions themselves, their `@doc`/`@spec` lines, the two `defdelegate` lines in `lib/docker.ex`, cross-references inside their own docstrings, and the tests being deleted in Step 3. No production call site.

Note `Logger.warning` and `Logger.error` (capital-L, inside `log.ex`'s private functions) are a different thing and must survive — the grep pattern above will not match them.

- [ ] **Step 2: Delete `container_running?`**

In `lib/docker/containers.ex`, delete both `container_running?` clauses together with their `@doc` and `@spec` blocks — the whole span from the `@doc` opening the `container_running?/1` documentation through the closing `end` of `container_running?/2` (approximately lines 733-783).

In `lib/docker.ex`, delete both lines:

```elixir
  defdelegate container_running?(container), to: Docker.Containers
  defdelegate container_running?(container_ref, options), to: Docker.Containers
```

Then check for dangling cross-references — `find_container/2`'s docstring or others may point at the deleted function:

Run: `grep -rn "container_running" lib`
Expected: no output. If any docstring still mentions it, delete that sentence.

- [ ] **Step 3: Delete `Log.warning/2`, `Log.error/2`, and `log_build_event/1`**

In `lib/docker/log.ex`, delete the `@spec`/`def` pairs for `warning/2` and `error/2`, and the `@doc`/`@spec`/`def` for `log_build_event/1`. `debug/2`, `log_pull_event/1`, `format_message/2`, and every private helper stay.

`log_build_event/1` is referenced from `Docker.Image`'s documentation. Check and fix:

Run: `grep -rn "log_build_event" lib`
Expected: no output. If `image.ex` mentions it, repoint that sentence at `Docker.Log.log_pull_event/1`, which handles build events identically.

In `test/docker/logger_test.exs`, delete the two tests for `warning/2` and `error/2` inside the `describe "debug/2, warning/2, error/2"` block, rename that describe to `"debug/2"`, and delete the entire `describe "log_build_event/1"` block.

- [ ] **Step 4: Make `resize_path/3` private**

In `lib/docker/exec.ex`, change the definition (around line 285) from:

```elixir
  @doc false
  @spec resize_path(binary(), pos_integer(), pos_integer()) :: String.t()
  def resize_path(exec_id, rows, cols) do
```

to:

```elixir
  @spec resize_path(binary(), pos_integer(), pos_integer()) :: String.t()
  defp resize_path(exec_id, rows, cols) do
```

Elixir requires private functions to be defined before use in some orderings — verify compilation in Step 5 and, if the compiler objects, move the `defp resize_path/3` block above `resize/4`.

In `test/docker/engine/exec_test.exs`, delete the entire `describe "resize_path/3"` block (lines 6-10). `resize/4` is the contract; the query string is an implementation detail.

- [ ] **Step 5: Run the tests**

Run: `mix test`
Expected: PASS, with no "function is unused" or "undefined function" warnings.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: delete unused public surface"
```

---

### Task 5: Delete unreachable clauses and hand-rolled input validators

**Files:**
- Modify: `lib/docker/client.ex`, `lib/docker/streaming/session.ex:147:153`, `lib/docker/network.ex:178:205`

**Interfaces:**
- Consumes: Task 1's `Client` changes (this task edits the same functions).
- Produces: nothing new. `Network.create_network/3` now returns the daemon's own 400 for a non-string `:ipam_subnet` or `:ipam_gateway` instead of a locally built `bad_request`.

- [ ] **Step 1: Delete `Client.decode_events/3`'s unreachable catch-all**

`into_mode` is only ever `:frame`, `:ndjson`, or `:raw` — set in `do_request/4` and `do_stream/4` and nowhere else — so the three preceding clauses are total. In `lib/docker/client.ex`, delete:

```elixir
  defp decode_events(chunk, buffer, _other) do
    NDJSON.decode_chunk(chunk, buffer)
  end
```

- [ ] **Step 2: Delete `Client.presence/1` and its two call sites**

It exists to handle the daemon sending a blank `"message"`, which it does not do. Replace the two `daemon_message/2` clauses:

```elixir
  # The Engine API puts its human-readable text at `body["message"]`.
  defp daemon_message(%{"message" => message}, _status) when is_binary(message), do: message

  # `stream/4` drains error bodies as raw bytes rather than decoding them, so
  # the same 404 that `request/4` hands over as a map arrives here as JSON
  # text. Both paths should produce the same message.
  defp daemon_message(body, status) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) ->
        message

      _not_a_daemon_error_body ->
        generic_message(status)
    end
  end
```

Then delete the `presence/1` function:

```elixir
  defp presence(string) do
    case String.trim(string) do
      "" -> nil
      trimmed -> trimmed
    end
  end
```

`generic_message/1` stays — it is still the fallback for a body with no `"message"` key.

The guards in both `daemon_message/2` clauses stay: they dispatch between a decoded map and a raw binary.

- [ ] **Step 3: Delete `Session.close/1`'s unreachable clause**

`from_connection/2` always sets `socket` to a pid, so a struct with a nil socket cannot exist. In `lib/docker/streaming/session.ex`, replace all three clauses (lines 147-153) with two:

```elixir
  def close(%__MODULE__{closed: true}), do: :ok

  def close(%__MODULE__{socket: socket}) do
    transport_close(socket)
  end
```

The `when not is_nil(socket)` guard goes with the clause it was protecting against.

- [ ] **Step 4: Delete the IPAM validators**

A bad value now reaches the daemon, which returns its own 400 that `Client` already converts to an `ErrorMessage`. In `lib/docker/network.ex`, replace `put_network_ipam/2`:

```elixir
  defp put_network_ipam(payload, options) do
    case Keyword.get(options, :ipam_subnet, "172.28.0.0/20") do
      nil ->
        {:ok, payload}

      subnet ->
        config = build_ipam_config(subnet, Keyword.get(options, :ipam_gateway))
        {:ok, Map.put(payload, "IPAM", %{"Config" => [config]})}
    end
  end

  defp build_ipam_config(subnet, nil), do: %{"Subnet" => subnet}
  defp build_ipam_config(subnet, gateway), do: %{"Subnet" => subnet, "Gateway" => gateway}
```

`build_ipam_config/2` no longer returns a tuple, so the `with` that consumed it is gone. Its two remaining clauses dispatch on `nil` vs. present, which is control flow and stays. The `nil` case of `:ipam_subnet` also stays — it is a documented way to opt out of IPAM, not a validator.

- [ ] **Step 5: Check for tests asserting the deleted validators**

Run: `grep -rn "ipam" test`
Expected: if any test asserts `{:error, %ErrorMessage{code: :bad_request}}` for a non-string subnet or gateway, delete that test — it covers behavior this task removes by design. Tests that create networks with a valid `:ipam_subnet` stay and must still pass.

- [ ] **Step 6: Run the tests**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Run Dialyzer**

Run: `mix dialyzer`
Expected: no new warnings. This step matters here specifically: removing clauses changes inferred types, and `:unmatched_returns` is enabled. If Dialyzer reports a newly-unreachable clause elsewhere, that is a real finding — delete that clause too and note it in the commit message.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: delete unreachable clauses and hand-rolled validators"
```

---

### Task 6: Remove single-clause validation guards

The governing rule: a guard that selects between clauses is control flow and stays; a guard on a single-clause function is validation and goes. Bad arguments now fail inside `Req` or as a daemon 400 rather than as a `FunctionClauseError` at the boundary — the accepted trade, since the daemon is the authority on what it accepts.

**Files:**
- Modify: `lib/docker/session.ex:17,29`, `lib/docker/exec.ex:63`, `lib/docker/terminal.ex:87,157,173,194,210`, `lib/docker/network.ex:97,156,270`, `lib/docker/util.ex:6`, `lib/docker/image.ex:259`, `lib/docker/instance.ex:129`, `lib/docker/frame.ex:223,269,335`, `lib/docker/ndjson.ex:50`, `lib/docker/streaming/session.ex:86`, `lib/docker/streaming/session_handler.ex:41,47`

**Interfaces:**
- Consumes: Task 2 already removed the guards on `Streaming.open_attach/3` and `open_exec_start/3`; they are not repeated here.
- Produces: nothing new. Every signature and arity is unchanged.

- [ ] **Step 1: Remove the guards, one file at a time**

Delete only the `when ...` clause from each head below. Do not change parameter names, default arguments, bodies, or `@spec`s.

| File | Function | Guard to delete |
|---|---|---|
| `lib/docker/session.ex` | `attach/2` | `when is_binary(container_ref)` |
| `lib/docker/session.ex` | `exec_session/3` | `when is_list(cmd)` |
| `lib/docker/exec.ex` | `exec_create/3` | `when is_list(cmd)` |
| `lib/docker/terminal.ex` | `open/2` | `when is_binary(container_ref) and is_list(opts)` |
| `lib/docker/terminal.ex` | `command/3` | `when is_binary(container_ref)` |
| `lib/docker/terminal.ex` | `close/1` | `when is_binary(container_ref)` |
| `lib/docker/terminal.ex` | `whereis/1` | `when is_binary(container_ref)` |
| `lib/docker/terminal.ex` | `start_link/1` | `when is_binary(container_ref)` |
| `lib/docker/network.ex` | `find_network/2` | `when is_binary(network_id)` |
| `lib/docker/network.ex` | `create_network/3` | `when is_binary(name)` |
| `lib/docker/network.ex` | `delete_network/2` | `when is_binary(network_id)` |
| `lib/docker/util.ex` | `create_tar/3` | `when is_binary(dest_path)` |
| `lib/docker/image.ex` | `build_image/5` | `when is_binary(tag) and is_binary(context_path)` |
| `lib/docker/instance.ex` | `new/5` | `when is_map(labels) and not is_struct(labels)` |
| `lib/docker/frame.ex` | `demux/1` | `when is_binary(buffer)` |
| `lib/docker/frame.ex` | `demux_all/1` | `when is_binary(body)` |
| `lib/docker/frame.ex` | `decode_chunk/2` | `when is_binary(chunk) and is_binary(buffer)` |
| `lib/docker/ndjson.ex` | `decode_chunk/2` | `when is_binary(chunk) and is_binary(buffer)` |
| `lib/docker/streaming/session.ex` | `from_connection/2` | `when is_pid(conn_pid) and is_boolean(tty)` |
| `lib/docker/streaming/session_handler.ex` | `connect/2` | `when is_pid(owner)` |
| `lib/docker/streaming/session_handler.ex` | `handle_in/2` | `when is_binary(bytes)` |

For example, `lib/docker/session.ex:17` goes from:

```elixir
  def attach(container_ref, options \\ []) when is_binary(container_ref) do
```

to:

```elixir
  def attach(container_ref, options \\ []) do
```

Note `SessionHandler.connect/2` and `handle_in/2` keep their `%Socket{} = socket` pattern match — that is destructuring, not a guard, and the callbacks need the struct.

- [ ] **Step 2: Confirm the multi-clause guards were left alone**

These dispatch and MUST still be present. Run:

```bash
grep -n "cmd_or_wrap_sh\|def exec_run" lib/docker/exec.ex
grep -n "body_opts\|classify_transport\|daemon_message" lib/docker/client.ex
grep -n "log_pull_event" lib/docker/log.ex
grep -n "def send\|def close" lib/docker/streaming/session.ex
grep -n "build_ipam_config" lib/docker/network.ex
```

Expected: `cmd_or_wrap_sh/1` still has its `is_list`/`is_binary` pair; `exec_run/3` keeps `when is_list(cmd) or is_binary(cmd)` (it selects between wrapping and not); `body_opts/1` keeps `when is_binary(body) or is_list(body)` and its `{:tar, tar}` guard; `classify_transport/2` keeps all five; `daemon_message/2` keeps both; `log_pull_event/1` keeps `when is_map(event)`; `Session.send/2` and `close/1` keep their `closed: true` pattern clauses.

- [ ] **Step 3: Compile and check for warnings**

Run: `mix compile --force --warnings-as-errors`
Expected: succeeds. A guard removal that leaves an unused variable or an unreachable clause surfaces here.

- [ ] **Step 4: Run the tests**

Run: `mix test`
Expected: PASS. If a test asserts a `FunctionClauseError` for a bad argument type, delete that test — it covers a guard this task removes by design.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove single-clause validation guards"
```

---

### Task 7: Full verification

**Files:**
- Modify: none expected. Fix whatever the checks surface.

**Interfaces:**
- Consumes: Tasks 1-6.
- Produces: a green build.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, zero failures. Confirm the reported test count dropped by roughly the number of deleted tests (the `resize_path` test, two `Log` level tests, two `log_build_event` tests) and gained the two new `Docker.StreamingTest` tests.

- [ ] **Step 2: Run Credo**

Run: `mix credo`
Expected: no issues. `blitz_credo_checks` is configured; a moduledoc that still references a deleted function may surface here.

- [ ] **Step 3: Run Dialyzer**

Run: `mix dialyzer`
Expected: no warnings. `:unmatched_returns` is on, so any clause that became unreachable in a way this plan did not anticipate appears here. Treat each as a real finding: delete the clause, do not add an ignore entry.

- [ ] **Step 4: Confirm the spec's invariants hold**

```bash
# No application or system environment reads
grep -rn "Application\.\(get\|fetch\|put\|compile\)_env\|System.get_env\|System.fetch_env" lib test

# No Docker.Config
grep -rn "Docker.Config" lib test README.md

# The config directory is gone
ls config 2>&1

# Both defaults exist and are exact
grep -n "@default_version\|@default_socket_path\|@drain_timeout\|@stream_idle_timeout" lib/docker/client.ex
```

Expected: the first two greps produce no output; `ls config` reports no such file or directory; the last grep shows exactly `"1.45"`, `"/var/run/docker.sock"`, `5_000`, and `60_000`.

- [ ] **Step 5: Verify the docs match the code**

Read `README.md`'s Configuration section and `Docker`'s moduledoc "Connecting to a daemon" section. Both must describe options, not `config/config.exs`. Run the exact snippets they show:

Run: `mix run -e 'IO.inspect(Docker.ping()); IO.inspect(Docker.Client.default_socket_path()); IO.inspect(Docker.Client.default_version())'`
Expected: `{:ok, "OK"}`, then `"/var/run/docker.sock"`, then `"1.45"`.

- [ ] **Step 6: Commit any fixes**

```bash
git add -A
git commit -m "fix: address verification findings"
```

Skip this step if Steps 1-5 required no changes.

- [ ] **Step 7: Push**

```bash
git push origin main
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Part 1 — delete `config.ex`, `config/`, `nimble_options` | Task 3 |
| Part 1 — four module attributes in `Client` | Task 1, Steps 3 and 7 |
| Part 1 — per-call resolution, no config struct | Task 1, Steps 4 and 6 |
| Part 1 — `Streaming` threads `opts` through `open_upgrade/4` | Task 2 |
| Part 1 — errors name the socket actually used | Task 1 Step 5, Task 2 Step 4 |
| Part 1 — moduledoc options table and typedoc | Task 3, Step 4 |
| Part 2 — four deletions plus `resize_path` made private | Task 4 |
| Part 2 — explicitly kept functions | Untouched by every task; guarded by Task 4's Step 1 grep |
| Part 3 — unreachable clauses | Task 5, Steps 1-3 |
| Part 3 — IPAM validators | Task 5, Step 4 |
| Part 3 — 21 single-clause guards (+2 from Task 2) | Task 6 |
| Part 3 — kept clauses | Task 6, Step 2 verifies each |
| Scope — README | Task 3, Step 5 |
| Testing — `client_test.exs` rewrite | Task 1, Step 1 |
| Testing — `mix test`, `mix credo`, `mix dialyzer` | Task 7 |

No gaps.

**Type consistency:** `default_version/0` and `default_socket_path/0` are defined in Task 1 Step 3 and consumed under those exact names in Task 2 Step 3 and Task 7 Step 5. `transport_error/4` and `classify_transport/2` gain their fourth and second parameters together in Task 1 Step 5. `upgrade_error/3` gains its third parameter across all four clauses in Task 2 Step 4, matching the call site in Step 3. `build_ipam_config/2` changes from returning `{:ok, map}` to returning `map`, and its only caller changes in the same step.
