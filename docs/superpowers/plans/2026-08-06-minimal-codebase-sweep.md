# Minimal Codebase Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the defensive branches that handle responses a docker daemon cannot send, delete the 655-line fake HTTP server that exists to manufacture those responses, and rewrite the test suite to drive the public API against a real daemon.

**Architecture:** One principle decides every case — the library handles what the daemon actually does, and tests it the way a caller uses it. `Docker.Sandbox` stays as product surface for downstream users; it stops being this library's way of testing itself. After the sweep there are two test-time constructs (the sandbox, and a real daemon) instead of three.

**Tech Stack:** Elixir 1.18, ExUnit, `error_message`, `sandbox_registry` (dev/test only), a local docker daemon over its unix socket.

## Global Constraints

- Design doc: `docs/superpowers/specs/2026-08-06-minimal-codebase-sweep-design.md`. Read it before starting.
- **CI requires a running docker daemon.** Tests that cannot run without one are expected and accepted.
- Test image is `alpine:3.19` throughout. Never hardcode a different tag.
- Every test that creates a container or image must clean it up with `on_exit/1`, including on failure.
- Real-daemon tests share global daemon state, so they run `async: false`. Pure-function tests (`util_test.exs`, `frame_test.exs`, `ndjson_test.exs`) stay `async: true`.
- Coverage will fall. That is the intended outcome, not a regression. Do not add tests to raise it.
- Never delete a branch that handles a *local* failure — disk full, bad permissions, `tar` exiting non-zero, a socket that isn't there. Only branches handling malformed *daemon responses* are in scope.
- Commit after every task. Run `mix format` before each commit.
- Existing commit style: imperative subject, no attribution trailers.

---

## File Structure

**Deleted**

| Path | Lines | Reason |
|---|---|---|
| `test/support/fake_http_server.ex` | 486 | manufactures impossible daemon responses |
| `test/support/fake_http_server/impl.ex` | 169 | same |

**Created**

| Path | Responsibility |
|---|---|
| `test/support/daemon_case.ex` | `ExUnit.CaseTemplate` giving every real-daemon test unique names, container/image creation with automatic cleanup, and `async: false` |

**Modified**

| Path | Change |
|---|---|
| `test/test_helper.exs` | drop dead tag exclusions; fail fast when no daemon; ensure `alpine:3.19` is present |
| `lib/docker/client.ex` | delete `daemon_message/2` fallback arms, `status_code/1` guard + rescue, `fallback_code/1` |
| `lib/docker/containers.ex` | delete `interpret_create_response/2` catch-all; collapse `decode_path_stat/3` |
| `lib/docker/network.ex` | delete the "created a network but returned no ID" arm |
| `lib/docker/exec.ex` | delete the "created an exec instance but returned no ID" arm |
| `test/docker/client_test.exs` | rewrite against a real daemon |
| `test/docker/containers_test.exs` | rewrite against a real daemon |
| `test/docker_test.exs` | rewrite 34 sandbox-stubbed describe blocks against a real daemon |
| `test/docker/engine/sandbox_test.exs` | reduce to sandbox-as-a-feature |
| `test/docker/engine/exec_test.exs` | rewrite against a real daemon |

---

### Task 1: Remove dead test tags

`test/test_helper.exs` excludes `:external_ssh` and `:pending`; no test carries either tag. The only real tag, `@tag :exhaustive`, is not excluded and so never changed what ran. All three are dead configuration.

**Files:**
- Modify: `test/test_helper.exs:1`
- Modify: `test/docker/engine/sandbox_test.exs:218`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Independent of every other task.

- [ ] **Step 1: Confirm no test carries the excluded tags**

Run:
```bash
grep -rn "@tag\|@moduletag" test/
```
Expected: exactly one hit, `test/docker/engine/sandbox_test.exs:218:  @tag :exhaustive`. If any test carries `:external_ssh` or `:pending`, stop and report — the premise is wrong.

- [ ] **Step 2: Drop the exclusions**

Replace line 1 of `test/test_helper.exs`:

```elixir
ExUnit.start()
Docker.Sandbox.start_link()
```

- [ ] **Step 3: Delete the decorative tag**

In `test/docker/engine/sandbox_test.exs`, delete the line `  @tag :exhaustive` (leave the test itself; Task 12 deals with it).

- [ ] **Step 4: Run the suite**

Run: `mix test`
Expected: same test count as before (178), 0 failures. The tag was inert, so removing it changes nothing.

- [ ] **Step 5: Commit**

```bash
mix format
git add test/test_helper.exs test/docker/engine/sandbox_test.exs
git commit -m "Remove dead test tags

test_helper excluded :external_ssh and :pending, which no test carries.
The one real tag, :exhaustive, was not in the exclude list and so never
changed what ran."
```

---

### Task 2: Real-daemon test support

Every rewrite task needs the same three things: a unique name, a container that cleans itself up, and a guarantee the daemon is reachable. Build it once.

**Files:**
- Create: `test/support/daemon_case.ex`
- Modify: `test/test_helper.exs`

**Interfaces:**
- Consumes: `Docker.ping/1`, `Docker.find_image/2`, `Docker.Image.pull_image/3`, `Docker.create_container/5`, `Docker.start_container/2`, `Docker.delete_container/3`.
- Produces, used by Tasks 3, 4, 7–12:
  - `DaemonCase` — `use DaemonCase` sets `async: false` and imports the helpers below.
  - `@image` — module attribute, `"alpine:3.19"`.
  - `unique_name(prefix :: binary()) :: binary()`
  - `create_container!(cmd :: [binary()], opts :: keyword()) :: binary()` — returns the container id, registers deletion via `on_exit/1`.
  - `start_container!(cmd :: [binary()], opts :: keyword()) :: binary()` — creates, starts, returns the container id.

- [ ] **Step 1: Write the case template**

Create `test/support/daemon_case.ex`:

```elixir
defmodule DaemonCase do
  @moduledoc """
  Case template for tests that drive the public API against a real docker
  daemon.

  Real-daemon tests share the daemon, so they are never async. Every helper
  here registers its own cleanup, so a failing test does not leave containers
  behind for the next run.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      import DaemonCase

      @image "alpine:3.19"
    end
  end

  @doc "A name no other test will collide with."
  def unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Creates a container running `cmd` and returns its id. The container is
  deleted when the test ends, whether it passed or failed.
  """
  def create_container!(cmd, opts \\ []) do
    name = unique_name("docker-ex-test")

    {:ok, id} =
      Docker.create_container(
        "docker-ex-test",
        name,
        "alpine:3.19",
        %{},
        Keyword.put_new(opts, :cmd, cmd)
      )

    ExUnit.Callbacks.on_exit(fn ->
      Docker.delete_container(id, %{force: true})
    end)

    id
  end

  @doc "Creates a container, starts it, and returns its id."
  def start_container!(cmd, opts \\ []) do
    id = create_container!(cmd, opts)
    {:ok, _} = Docker.start_container(id)
    id
  end
end
```

- [ ] **Step 2: Make test_helper fail fast without a daemon**

Replace `test/test_helper.exs` entirely:

```elixir
ExUnit.start()
Docker.Sandbox.start_link()

# The suite drives a real daemon. Failing here with one clear line beats
# every test failing with a socket error.
case Docker.ping() do
  {:ok, _} ->
    :ok

  {:error, error} ->
    IO.puts(:stderr, """

    The test suite requires a running docker daemon.

      #{error.message}

    Start Docker and run the suite again.
    """)

    System.halt(1)
end

# Pull the test image once rather than letting the first test pay for it.
case Docker.find_image("alpine:3.19") do
  {:ok, _} ->
    :ok

  {:error, _not_present} ->
    {:ok, stream} = Docker.Image.pull_image("alpine:3.19")
    Stream.run(stream)
end
```

- [ ] **Step 3: Prove the helper works**

Create a scratch file `/tmp/daemon_case_check.exs`:

```elixir
defmodule DaemonCaseCheck do
  use DaemonCase

  test "create_container! returns an id the daemon knows" do
    id = create_container!(["sleep", "30"])

    assert {:ok, container} = Docker.find_container(id)
    assert container["Id"] =~ id
  end

  test "start_container! leaves the container running" do
    id = start_container!(["sleep", "30"])

    assert Docker.container_running?(id)
  end
end
```

Run: `mix test /tmp/daemon_case_check.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 4: Confirm cleanup actually happened**

Run: `docker ps -a --filter name=docker-ex-test --format '{{.Names}}'`
Expected: no output. If names remain, `on_exit` is not firing — fix before continuing, or every later task leaks containers.

- [ ] **Step 5: Delete the scratch file and commit**

```bash
rm /tmp/daemon_case_check.exs
mix format
git add test/support/daemon_case.ex test/test_helper.exs
git commit -m "Add DaemonCase for real-daemon tests

Gives every real-daemon test a unique name, containers that delete
themselves on exit, and a suite that fails with one clear line rather
than a socket error per test when docker is not running."
```

---

### Task 3: Delete client.ex's impossible-response branches

`status_code/1` guards against `ErrorMessage` lacking a constructor for a status and rescues `ArgumentError` from `Plug.Conn.Status`; `daemon_message/2` handles a binary body, a body that will not decode, and a body that is neither. The daemon sends JSON carrying `"message"` and a status from a documented set.

**Files:**
- Modify: `lib/docker/client.ex:388-420`
- Modify: `test/docker/client_test.exs`

**Interfaces:**
- Consumes: `DaemonCase` from Task 2.
- Produces: `Docker.Client.request/4` returns `{:error, %ErrorMessage{}}` for daemon-sent statuses; malformed responses now raise rather than returning an error.

- [ ] **Step 1: Write the failing test for what survives**

Replace `test/docker/client_test.exs` entirely:

```elixir
defmodule Docker.ClientTest do
  @moduledoc """
  Error translation, driven through the public API against a real daemon.

  Only statuses the daemon actually sends are covered. Manufacturing a
  malformed response to exercise a defensive branch is what this suite used
  to do; those branches are gone.
  """

  use DaemonCase

  alias Docker.Config

  describe "a status the daemon sends" do
    test "a missing container is :not_found and lifts the daemon's message" do
      assert {:error, %ErrorMessage{code: :not_found} = error} =
               Docker.find_container("docker-ex-test-does-not-exist")

      assert error.message =~ "No such container"
    end

    test "a missing image is :not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.find_image("docker-ex-test-no-such-image:latest")
    end

    test "removing a running container without force is :conflict" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :conflict}} = Docker.delete_container(id)
    end

    test "starting an already-started container is :not_modified" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :not_modified}} = Docker.start_container(id)
    end
  end

  describe "a daemon that is not there" do
    setup do
      original = Application.fetch_env!(:docker, :socket_path)
      on_exit(fn -> Application.put_env(:docker, :socket_path, original) end)
      :ok
    end

    test "a missing socket is :service_unavailable" do
      missing = Path.join(System.tmp_dir!(), unique_name("docker-absent"))
      Application.put_env(:docker, :socket_path, missing)

      assert {:error, %ErrorMessage{code: :service_unavailable} = error} = Docker.ping()

      assert error.message =~ "Could not reach the Docker daemon"
      assert %{socket_path: ^missing} = error.details
    end
  end

  describe "the API version prefix" do
    test "requests carry the configured version" do
      assert {:ok, _} = Docker.ping()
      assert Config.version() =~ ~r/^\d+\.\d+$/
    end
  end
end
```

- [ ] **Step 2: Run it against the current code**

Run: `mix test test/docker/client_test.exs`
Expected: PASS. These behaviours already work — this step proves the new suite is green *before* the branches are removed, so a failure in Step 4 is caused by the deletion and nothing else.

- [ ] **Step 3: Delete the branches**

In `lib/docker/client.ex`, replace everything from the `# ErrorMessage.http_code_reason_atom/1 delegates...` comment through `defp daemon_message(_body, status), do: generic_message(status)` with:

```elixir
  @spec status_code(integer()) :: ErrorMessage.code()
  defp status_code(status), do: ErrorMessage.http_code_reason_atom(status)

  # The Engine API puts its human-readable text at `body["message"]`.
  defp daemon_message(%{"message" => message}, status) when is_binary(message) do
    presence(message) || generic_message(status)
  end

  # `stream/4` drains error bodies as raw bytes rather than decoding them, so
  # the same 404 that `request/4` hands over as a map arrives here as JSON
  # text. Both paths should produce the same message.
  defp daemon_message(body, status) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) ->
        presence(message) || generic_message(status)

      _not_a_daemon_error_body ->
        generic_message(status)
    end
  end
```

Note: the binary clause stays — `stream/4` genuinely delivers error bodies as text, which is a real daemon path, not a manufactured one. What goes is the plain-text/empty-body fallback inside it, the non-binary catch-all, and all of `status_code/1`'s defensive machinery.

- [ ] **Step 4: Run the suite**

Run: `mix test test/docker/client_test.exs`
Expected: PASS, same as Step 2.

- [ ] **Step 5: Verify nothing else referenced the deleted helper**

Run: `grep -n "fallback_code" lib/`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/docker/client.ex test/docker/client_test.exs
git commit -m "Delete client.ex's impossible-response handling

status_code/1 guarded against ErrorMessage lacking a constructor and
rescued ArgumentError; daemon_message/2 had arms for a plain-text body,
an empty body, and a body that is neither. The daemon sends JSON with a
message key and a documented status.

client_test now drives real statuses through the public API: 404 from a
missing container, 409 from removing a running one, 304 from starting a
started one, and service_unavailable from a socket that is not there."
```

---

### Task 4: Collapse containers.ex's stat and create defensive branches

`decode_path_stat/3` is a four-stage pipeline reporting `:missing_header`, `:invalid_base64`, `:invalid_json` and `:not_an_object` for a header the daemon always sends as valid base64 JSON. `interpret_create_response/2` has a catch-all for a create response that is neither a success nor a warning.

**Files:**
- Modify: `lib/docker/containers.ex:421-432` (create catch-all)
- Modify: `lib/docker/containers.ex:759-795` (stat pipeline)
- Modify: `test/docker/containers_test.exs`

**Interfaces:**
- Consumes: `DaemonCase` from Task 2.
- Produces: `Docker.stat_archive/3` returns `{:ok, map}` or a daemon-sent `{:error, %ErrorMessage{}}`; a malformed stat header now raises.

- [ ] **Step 1: Write the replacement test suite**

Replace `test/docker/containers_test.exs` entirely:

```elixir
defmodule Docker.ContainersTest do
  @moduledoc """
  Archive and wait endpoints against a real daemon.

  The malformed-header cases this suite used to carry are gone with the
  branches that handled them: the daemon always sends a valid base64 JSON
  stat header.
  """

  use DaemonCase

  describe "get_archive/3" do
    test "returns the tar bytes for a path in the container" do
      id = start_container!(["sleep", "30"])

      assert {:ok, tar} = Docker.get_archive(id, "/etc/hostname")
      assert is_binary(tar)
      # A tar member header carries the file name in its first 100 bytes.
      assert binary_part(tar, 0, 100) =~ "hostname"
    end

    test "a path that does not exist is :not_found" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.get_archive(id, "/no/such/path")
    end
  end

  describe "stat_archive/3" do
    test "returns the daemon's decoded path stat" do
      id = start_container!(["sleep", "30"])

      assert {:ok, stat} = Docker.stat_archive(id, "/etc/hostname")
      assert stat["name"] === "hostname"
      assert is_integer(stat["size"])
    end

    test "a path that does not exist is :not_found" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.stat_archive(id, "/no/such/path")
    end
  end

  describe "wait_container/3" do
    test "returns the exit status once the container stops" do
      id = start_container!(["/bin/sh", "-c", "exit 0"])

      assert {:ok, %{"StatusCode" => 0}} = Docker.wait_container(id)
    end

    test "a non-zero exit is still a successful call" do
      id = start_container!(["/bin/sh", "-c", "exit 7"])

      assert {:ok, %{"StatusCode" => 7}} = Docker.wait_container(id)
    end

    test "an elapsed :receive_timeout is :gateway_timeout" do
      id = start_container!(["sleep", "30"])

      assert {:error, %ErrorMessage{code: :gateway_timeout}} =
               Docker.wait_container(id, %{}, receive_timeout: 100)
    end
  end

  describe "put_archive/4" do
    test "a tar written into the container is readable back out" do
      id = start_container!(["sleep", "30"])
      tar_path = Path.join(System.tmp_dir!(), unique_name("put-archive") <> ".tar")
      on_exit(fn -> File.rm(tar_path) end)

      source = Path.join(System.tmp_dir!(), unique_name("payload"))
      File.write!(source, "hello from the test")
      on_exit(fn -> File.rm(source) end)

      :ok = Docker.Util.create_tar(tar_path, source, verbose: false)

      assert {:ok, _} = Docker.put_archive(id, "/tmp", File.read!(tar_path))
      assert {:ok, tar} = Docker.get_archive(id, "/tmp/#{Path.basename(source)}")
      assert tar =~ "hello from the test"
    end
  end
end
```

- [ ] **Step 2: Run it against the current code**

Run: `mix test test/docker/containers_test.exs`
Expected: PASS. Proves the suite is green before the deletion.

- [ ] **Step 3: Collapse the stat pipeline**

In `lib/docker/containers.ex`, replace `decode_path_stat/3`, `fetch_stat_header/3`, `decode_stat_base64/3` and `decode_stat_json/3` with:

```elixir
  # The daemon sends this header as base64-encoded JSON on every 2xx. A
  # response that is not that shape is a broken daemon, not a case to handle.
  defp decode_path_stat(headers, _container_ref, _src_path) do
    {_key, encoded} = List.keyfind(headers, @stat_header, 0)
    {:ok, json} = Base.decode64(encoded)

    JSON.decode(json)
  end
```

Then delete `stat_error/3`, which now has no callers.

- [ ] **Step 4: Delete the create catch-all**

In `lib/docker/containers.ex`, delete this clause entirely:

```elixir
  defp interpret_create_response(body, name) do
    {:error,
     ErrorMessage.internal_server_error(
       "The Docker daemon returned an unrecognised create response",
       %{body: body, name: name}
     )}
  end
```

Leave the `%{"Id" => id, "Warnings" => []}` and `%{"Id" => id, "Warnings" => warnings}` clauses: warnings are a real daemon behaviour.

- [ ] **Step 5: Run the suite**

Run: `mix test test/docker/containers_test.exs`
Expected: PASS.

- [ ] **Step 6: Verify the deleted helpers have no callers**

Run: `grep -n "stat_error\|fetch_stat_header\|decode_stat_base64\|decode_stat_json" lib/`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
mix format
git add lib/docker/containers.ex test/docker/containers_test.exs
git commit -m "Collapse containers.ex's impossible-response handling

decode_path_stat/3 reported four distinct errors for a header the daemon
always sends as valid base64 JSON, and interpret_create_response/2 had a
catch-all for a create body that is neither a success nor a warning.

containers_test now reads a real path stat, writes and reads back a real
archive, and waits on a real container."
```

---

### Task 5: Delete the "2xx with no ID" branches

`network.ex` and `exec.ex` each handle a 2xx that carries no ID. The daemon returns `{"Id": "..."}` on both endpoints.

**Files:**
- Modify: `lib/docker/network.ex:195-203`
- Modify: `lib/docker/exec.ex:89-97`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Docker.create_network/3` and `Docker.exec_create/3` return `{:ok, id}` or a daemon-sent error.

- [ ] **Step 1: Write the failing test**

Create `test/docker/engine/create_id_test.exs`:

```elixir
defmodule Docker.Engine.CreateIdTest do
  @moduledoc "Both create endpoints return an id the daemon then recognises."

  use DaemonCase

  test "create_network returns an id the daemon knows" do
    name = unique_name("docker-ex-test-net")

    assert {:ok, id} = Docker.create_network(name, %{})
    on_exit(fn -> Docker.delete_network(id) end)

    assert {:ok, network} = Docker.find_network(id)
    assert network["Name"] === name
  end

  test "exec_create returns an id exec_inspect recognises" do
    container_id = start_container!(["sleep", "30"])

    assert {:ok, exec_id} = Docker.exec_create(container_id, ["/bin/echo", "hi"])
    assert {:ok, %{"Running" => false}} = Docker.exec_inspect(exec_id)
  end
end
```

- [ ] **Step 2: Run it against the current code**

Run: `mix test test/docker/engine/create_id_test.exs`
Expected: PASS.

- [ ] **Step 3: Delete the network branch**

In `lib/docker/network.ex`, delete this clause from the `case` in `create_network/3`:

```elixir
        # A 2xx that carries no ID leaves the caller no handle on the network.
        {:ok, %{body: body}} ->
          {:error,
           ErrorMessage.internal_server_error(
             "The Docker daemon created a network but returned no ID",
             %{body: body, name: name}
           )}
```

- [ ] **Step 4: Delete the exec branch**

In `lib/docker/exec.ex`, delete this clause:

```elixir
      # A 2xx that carries no exec ID leaves nothing to start.
      {:ok, %{body: body}} ->
        {:error,
         ErrorMessage.internal_server_error(
           "The Docker daemon created an exec instance but returned no ID",
           %{body: body, container_ref: container_ref}
         )}
```

- [ ] **Step 5: Run the suite**

Run: `mix test test/docker/engine/create_id_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/docker/network.ex lib/docker/exec.ex test/docker/engine/create_id_test.exs
git commit -m "Delete the 2xx-with-no-ID branches

Both create endpoints return {\"Id\": \"...\"}. A 2xx without one is a
broken daemon, not a case to translate into an ErrorMessage."
```

---

### Task 6: Delete FakeHttpServer

Nothing references it once Tasks 3 and 4 land.

**Files:**
- Delete: `test/support/fake_http_server.ex`
- Delete: `test/support/fake_http_server/impl.ex`

**Interfaces:**
- Consumes: Tasks 3 and 4 must be complete.
- Produces: nothing.

- [ ] **Step 1: Confirm there are no remaining references**

Run:
```bash
grep -rn "FakeHttpServer" test/ lib/
```
Expected: hits only inside `test/support/fake_http_server.ex` and `test/support/fake_http_server/impl.ex`. If any test still references it, that test belongs to Task 3 or 4 — finish those first.

- [ ] **Step 2: Delete the files**

```bash
git rm test/support/fake_http_server.ex test/support/fake_http_server/impl.ex
```

- [ ] **Step 3: Run the whole suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 4: Check whether its dependencies are now unused**

Run:
```bash
grep -rn "Plug\|Bandit\|ThousandIsland" lib/ test/ mix.exs
```
If a dependency in `mix.exs` is now referenced nowhere, remove it from `deps/0` and run `mix deps.unlock <dep>`. If everything is still referenced, skip this step.

- [ ] **Step 5: Commit**

```bash
mix format
git add -A
git commit -m "Delete FakeHttpServer

655 lines whose main job was manufacturing responses a docker daemon
cannot send, so that branches handling those responses looked testable.
Both are gone."
```

---

### Task 7: Rewrite docker_test.exs — container lifecycle

`test/docker_test.exs` has 64 tests across 34 describe blocks, nearly all registering a canned response and asserting it comes back. Rewrite in five tasks, by area. This one covers `ping`, `list_containers`, `find_container`, `create_container`, `start_container`, `stop_container`, `delete_container`, `container_logs`, `container_running?`.

**Files:**
- Create: `test/docker/containers_lifecycle_test.exs`
- Modify: `test/docker_test.exs` (delete the rewritten describe blocks)

**Interfaces:**
- Consumes: `DaemonCase` from Task 2.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the new suite**

Create `test/docker/containers_lifecycle_test.exs`:

```elixir
defmodule Docker.ContainersLifecycleTest do
  @moduledoc "The container lifecycle, driven the way a caller drives it."

  use DaemonCase

  describe "ping/1" do
    test "reaches the daemon" do
      assert {:ok, _} = Docker.ping()
    end
  end

  describe "create_container/5 and find_container/2" do
    test "a created container is findable by the id it returned" do
      id = create_container!(["sleep", "30"])

      assert {:ok, container} = Docker.find_container(id)
      assert container["Id"] =~ id
      assert container["State"]["Running"] === false
    end

    test "labels given at creation come back on inspect" do
      name = unique_name("docker-ex-test")

      {:ok, id} =
        Docker.create_container(
          "docker-ex-test",
          name,
          "alpine:3.19",
          %{"tier" => "worker"},
          cmd: ["sleep", "30"]
        )

      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)

      assert {:ok, container} = Docker.find_container(id)
      assert container["Config"]["Labels"]["tier"] === "worker"
    end
  end

  describe "start_container/2 and stop_container/2" do
    test "a started container is running, and a stopped one is not" do
      id = create_container!(["sleep", "30"])

      assert {:ok, _} = Docker.start_container(id)
      assert Docker.container_running?(id)

      assert {:ok, _} = Docker.stop_container(id)
      refute Docker.container_running?(id)
    end
  end

  describe "container_running?/1 (map clause)" do
    test "reads the state out of an inspect response" do
      id = start_container!(["sleep", "30"])
      {:ok, container} = Docker.find_container(id)

      assert Docker.container_running?(container)
    end
  end

  describe "delete_container/3" do
    test "a deleted container is no longer findable" do
      name = unique_name("docker-ex-test")

      {:ok, id} =
        Docker.create_container("docker-ex-test", name, "alpine:3.19", %{},
          cmd: ["sleep", "30"]
        )

      assert {:ok, _} = Docker.delete_container(id)
      assert {:error, %ErrorMessage{code: :not_found}} = Docker.find_container(id)
    end
  end

  describe "container_logs/3" do
    test "returns what the container printed" do
      id = start_container!(["/bin/sh", "-c", "echo hello-from-logs"])

      {:ok, _} = Docker.wait_container(id)

      assert {:ok, logs} = Docker.container_logs(id, %{stdout: true})
      assert logs =~ "hello-from-logs"
    end
  end

  describe "list_containers/2" do
    test "lists a running container" do
      id = start_container!(["sleep", "30"])

      assert {:ok, containers} = Docker.list_containers()
      assert Enum.any?(containers, &(&1["Id"] =~ id))
    end

    test "a label filter narrows the list to matching containers" do
      name = unique_name("docker-ex-test")
      tier = unique_name("tier")

      {:ok, id} =
        Docker.create_container("docker-ex-test", name, "alpine:3.19", %{"tier" => tier},
          cmd: ["sleep", "30"]
        )

      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)
      {:ok, _} = Docker.start_container(id)

      other = start_container!(["sleep", "30"])

      assert {:ok, containers} =
               Docker.list_containers(%{filters: [label: %{"tier" => tier}]})

      ids = Enum.map(containers, & &1["Id"])
      assert Enum.any?(ids, &(&1 =~ id))
      refute Enum.any?(ids, &(&1 =~ other))
    end

    test "all: true includes a stopped container that the default hides" do
      id = create_container!(["sleep", "30"])

      {:ok, running_only} = Docker.list_containers()
      refute Enum.any?(running_only, &(&1["Id"] =~ id))

      {:ok, all} = Docker.list_containers(%{all: true})
      assert Enum.any?(all, &(&1["Id"] =~ id))
    end
  end
end
```

- [ ] **Step 2: Run the new suite**

Run: `mix test test/docker/containers_lifecycle_test.exs`
Expected: PASS, 10 tests.

- [ ] **Step 3: Delete the replaced describe blocks**

From `test/docker_test.exs`, delete these describe blocks in full: `"ping/1"`, `"list_containers/2"`, `"find_container/2"`, `"create_container/5"`, `"start_container/2"`, `"stop_container/2"`, `"delete_container/3"`, `"container_logs/3"`, `"container_running?/2 (binary clause)"`, `"container_running?/1 (map clause)"`.

The filter-encoding assertions inside `"list_containers/2"` are already covered by `test/docker/util_test.exs`, which tests `encode_filters/1` directly — do not port them.

- [ ] **Step 4: Run the whole suite**

Run: `mix test`
Expected: 0 failures, total count lower than before.

- [ ] **Step 5: Commit**

```bash
mix format
git add test/docker/containers_lifecycle_test.exs test/docker_test.exs
git commit -m "Rewrite the container lifecycle tests against a real daemon

These asserted that a registered map came back. They now create, start,
stop, inspect, log and delete real containers, and check that a label
filter narrows the list to the container carrying the label.

The filter-encoding assertions are not ported: util_test covers
encode_filters/1 directly."
```

---

### Task 8: Rewrite docker_test.exs — images

Covers `list_images`, `find_image`, `delete_image`, `pull_image`, `materialize_image`.

**Files:**
- Create: `test/docker/images_test.exs`
- Modify: `test/docker_test.exs`

**Interfaces:**
- Consumes: `DaemonCase` from Task 2.
- Produces: nothing.

- [ ] **Step 1: Write the new suite**

Create `test/docker/images_test.exs`:

```elixir
defmodule Docker.ImagesTest do
  @moduledoc "Image reads against a real daemon."

  use DaemonCase

  describe "find_image/2" do
    test "returns the image by name and tag" do
      assert {:ok, image} = Docker.find_image("alpine:3.19")
      assert image["Id"] =~ "sha256:"
      assert "alpine:3.19" in image["RepoTags"]
    end

    test "returns the same image by its id" do
      {:ok, by_tag} = Docker.find_image("alpine:3.19")

      assert {:ok, by_id} = Docker.find_image(by_tag["Id"])
      assert by_id["Id"] === by_tag["Id"]
    end

    test "an image that is not present is :not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.find_image("docker-ex-test-absent:latest")
    end
  end

  describe "list_images/2" do
    test "includes the test image" do
      assert {:ok, images} = Docker.list_images()

      assert Enum.any?(images, fn image ->
               is_list(image["RepoTags"]) and "alpine:3.19" in image["RepoTags"]
             end)
    end

    test "a reference filter narrows the list" do
      assert {:ok, images} = Docker.list_images(%{filters: [reference: ["alpine*"]]})
      refute images === []

      assert Enum.all?(images, fn image ->
               Enum.any?(image["RepoTags"] || [], &String.starts_with?(&1, "alpine"))
             end)
    end
  end

  describe "materialize_image/4" do
    # No default arguments: all four are required.
    test "an image already present is returned without pulling" do
      assert {:ok, image} = Docker.materialize_image("alpine:3.19", "alpine:3.19", %{}, [])
      assert image["Id"] =~ "sha256:"
    end
  end

  describe "pull_image/3" do
    test "streams progress events and leaves the image present" do
      assert {:ok, stream} = Docker.pull_image("alpine:3.19")

      events = Enum.to_list(stream)

      assert Enum.any?(events, &Map.has_key?(&1, "status"))
      assert {:ok, _} = Docker.find_image("alpine:3.19")
    end
  end
end
```

- [ ] **Step 2: Run the new suite**

Run: `mix test test/docker/images_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 3: Delete the replaced describe blocks**

From `test/docker_test.exs`, delete: `"list_images/2"`, `"find_image/2"`, `"delete_image/3"`, `"pull_image/3"`, `"materialize_image/4"`.

`delete_image` gets no real-daemon test: deleting a shared base image would break every other test in the run, and building a throwaway image to delete is Task 10's `build_image` coverage. Note this gap in the commit message rather than leaving it silent.

- [ ] **Step 4: Run the whole suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
mix format
git add test/docker/images_test.exs test/docker_test.exs
git commit -m "Rewrite the image tests against a real daemon

find_image, list_images, materialize_image and pull_image now read real
images and assert a reference filter narrows the list.

delete_image is deliberately left uncovered: deleting a shared base image
would break the rest of the run, and building a throwaway image to delete
belongs with the build tests."
```

---

### Task 9: Rewrite docker_test.exs — networks and exec

Covers `list_networks`, `find_network`, `create_network`, `connect_network`, `delete_network`, `exec_create`, `exec_start`, `exec_inspect`, `exec_run`, `exec_run_with_status`.

**Files:**
- Create: `test/docker/networks_test.exs`
- Modify: `test/docker/engine/exec_test.exs`
- Modify: `test/docker_test.exs`

**Interfaces:**
- Consumes: `DaemonCase` from Task 2.
- Produces: nothing.

- [ ] **Step 1: Write the network suite**

Create `test/docker/networks_test.exs`:

```elixir
defmodule Docker.NetworksTest do
  @moduledoc "Network lifecycle against a real daemon."

  use DaemonCase

  # create_network/3 requires labels; there is no arity-1 form.
  defp create_network! do
    name = unique_name("docker-ex-test-net")
    {:ok, id} = Docker.create_network(name, %{})
    on_exit(fn -> Docker.delete_network(id) end)
    {id, name}
  end

  describe "create_network/3 and find_network/2" do
    test "a created network is findable by the id it returned" do
      {id, name} = create_network!()

      assert {:ok, network} = Docker.find_network(id)
      assert network["Name"] === name
      assert network["Driver"] === "bridge"
    end
  end

  describe "list_networks/2" do
    test "includes a created network" do
      {id, _name} = create_network!()

      assert {:ok, networks} = Docker.list_networks()
      assert Enum.any?(networks, &(&1["Id"] === id))
    end

    test "a driver filter narrows the list" do
      assert {:ok, networks} = Docker.list_networks(%{filters: [driver: ["bridge"]]})
      assert Enum.all?(networks, &(&1["Driver"] === "bridge"))
    end
  end

  describe "connect_network/3" do
    test "a connected container appears in the network's container map" do
      {id, _name} = create_network!()
      container_id = start_container!(["sleep", "30"])

      assert {:ok, _} = Docker.connect_network(id, container_id)

      assert {:ok, network} = Docker.find_network(id)
      assert Map.has_key?(network["Containers"], container_id)
    end
  end

  describe "delete_network/2" do
    test "a deleted network is no longer findable" do
      name = unique_name("docker-ex-test-net")
      {:ok, id} = Docker.create_network(name, %{})

      # delete_network/2 returns bare :ok, NOT {:ok, _}.
      assert :ok = Docker.delete_network(id)
      assert {:error, %ErrorMessage{code: :not_found}} = Docker.find_network(id)
    end
  end
end
```

- [ ] **Step 2: Write the exec suite**

Replace `test/docker/engine/exec_test.exs` entirely:

```elixir
defmodule Docker.Engine.ExecTest do
  @moduledoc "Exec against a real daemon."

  use DaemonCase

  describe "resize_path/3" do
    test "builds the exec resize path with h and w query params" do
      assert Docker.Exec.resize_path("abc123", 40, 120) === "/exec/abc123/resize?h=40&w=120"
    end
  end

  describe "exec_run/3" do
    test "runs an argv list and returns its output" do
      id = start_container!(["sleep", "30"])

      assert {:ok, output} = Docker.exec_run(id, ["/bin/echo", "hello"])
      assert output =~ "hello"
    end

    test "runs a string command under /bin/sh -c" do
      id = start_container!(["sleep", "30"])

      assert {:ok, output} = Docker.exec_run(id, "echo one && echo two")
      assert output =~ "one"
      assert output =~ "two"
    end
  end

  describe "exec_run_with_status/3" do
    test "reports a zero exit code and the output" do
      id = start_container!(["sleep", "30"])

      assert {:ok, %{output: output, exit_code: 0, running: false}} =
               Docker.exec_run_with_status(id, "echo done")

      assert output =~ "done"
    end

    test "reports a non-zero exit code" do
      id = start_container!(["sleep", "30"])

      assert {:ok, %{exit_code: 7, running: false}} =
               Docker.exec_run_with_status(id, "exit 7")
    end
  end

  describe "exec_create/3, exec_start/2 and exec_inspect/2" do
    test "the three steps compose into one run" do
      id = start_container!(["sleep", "30"])

      assert {:ok, exec_id} = Docker.exec_create(id, ["/bin/echo", "composed"])
      assert {:ok, output} = Docker.exec_start(exec_id)
      assert output =~ "composed"

      assert {:ok, %{"ExitCode" => 0, "Running" => false}} = Docker.exec_inspect(exec_id)
    end

    test "exec_inspect on an unknown id is :not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.exec_inspect("0123456789abcdef0123456789abcdef0123456789abcdef")
    end
  end
end
```

- [ ] **Step 3: Run both suites**

Run: `mix test test/docker/networks_test.exs test/docker/engine/exec_test.exs`
Expected: PASS.

- [ ] **Step 4: Delete the replaced describe blocks**

From `test/docker_test.exs`, delete: `"list_networks/2"`, `"find_network/2"`, `"create_network/3"`, `"connect_network/3"`, `"delete_network/2"`, `"exec_create/3"`, `"exec_start/2"`, `"exec_inspect/2"`, `"exec_run/3"`, `"exec_run_with_status/3"`.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
mix format
git add test/docker/networks_test.exs test/docker/engine/exec_test.exs test/docker_test.exs
git commit -m "Rewrite the network and exec tests against a real daemon

Networks are created, listed, connected to a container and deleted for
real. Exec runs real commands and reports real exit codes, including the
three-step create/start/inspect path."
```

---

### Task 10: Rewrite docker_test.exs — archives and build

Covers `put_archive`, `get_archive`, `download_archive`, `stat_archive`, `wait_container`, `Util.create_tar`, `build_image`, `run_build_image`, `Instance.to_map`.

**Files:**
- Create: `test/docker/build_test.exs`
- Create: `test/fixtures/Dockerfile`
- Modify: `test/docker_test.exs`

**Interfaces:**
- Consumes: `DaemonCase` from Task 2.
- Produces: nothing.

- [ ] **Step 1: Create the build fixture**

Create `test/fixtures/Dockerfile`:

```dockerfile
FROM alpine:3.19
RUN echo "built by the test suite" > /built.txt
```

- [ ] **Step 2: Write the build suite**

Create `test/docker/build_test.exs`:

```elixir
defmodule Docker.BuildTest do
  @moduledoc "Image building against a real daemon."

  use DaemonCase

  @context Path.expand("../fixtures", __DIR__)

  defp unique_tag, do: unique_name("docker-ex-test-build") <> ":latest"

  describe "build_image/5" do
    test "streams build output and leaves a tagged image" do
      tag = unique_tag()
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)

      assert {:ok, stream} = Docker.build_image(@context, "Dockerfile", tag)

      events = Enum.to_list(stream)
      assert Enum.any?(events, &Map.has_key?(&1, "stream"))

      assert {:ok, image} = Docker.find_image(tag)
      assert tag in image["RepoTags"]
    end

    test "an empty tag is :bad_request" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               Docker.build_image(@context, "Dockerfile", "")
    end

    test "a context path that is not a directory is :bad_request" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               Docker.build_image("/no/such/context", "Dockerfile", unique_tag())
    end
  end

  describe "run_build_image/5" do
    # run_build_image/5 drains the stream itself and returns bare :ok, NOT {:ok, _}.
    test "builds and returns the tag without the caller draining a stream" do
      tag = unique_tag()
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)

      assert :ok = Docker.run_build_image(@context, "Dockerfile", tag)
      assert {:ok, _image} = Docker.find_image(tag)
    end
  end

  describe "delete_image/3" do
    test "a deleted image is no longer findable" do
      tag = unique_tag()
      :ok = Docker.run_build_image(@context, "Dockerfile", tag)

      assert {:ok, _} = Docker.delete_image(tag, %{force: true})
      assert {:error, %ErrorMessage{code: :not_found}} = Docker.find_image(tag)
    end
  end

  describe "the built image" do
    test "carries what the Dockerfile put in it" do
      tag = unique_tag()
      on_exit(fn -> Docker.delete_image(tag, %{force: true}) end)
      :ok = Docker.run_build_image(@context, "Dockerfile", tag)

      name = unique_name("docker-ex-test")
      {:ok, id} = Docker.create_container("docker-ex-test", name, tag, %{}, cmd: ["sleep", "30"])
      on_exit(fn -> Docker.delete_container(id, %{force: true}) end)
      {:ok, _} = Docker.start_container(id)

      assert {:ok, output} = Docker.exec_run(id, ["/bin/cat", "/built.txt"])
      assert output =~ "built by the test suite"
    end
  end
end
```

- [ ] **Step 3: Run the build suite**

Run: `mix test test/docker/build_test.exs`
Expected: PASS, 6 tests. Builds are slow; this suite may take a minute.

- [ ] **Step 4: Delete the replaced describe blocks**

From `test/docker_test.exs`, delete: `"put_archive/4"`, `"get_archive/3"`, `"download_archive/4"`, `"stat_archive/3"`, `"wait_container/3"`, `"Util.create_tar/3"`, `"build_image/5"`, `"run_build_image/5"`, `"Instance.to_map/1 (labels)"`.

The archive and wait blocks are already covered by `test/docker/containers_test.exs` from Task 4 — do not port them.

`Util.create_tar/3` and `Instance.to_map/1` are pure functions with no daemon involvement. Move them, unchanged, into `test/docker/util_test.exs` and a new `test/docker/instance_test.exs` respectively, both `async: true`. They already test the public behaviour of a public function, so their content does not change.

- [ ] **Step 5: Confirm docker_test.exs is now empty**

Run: `grep -c "describe" test/docker_test.exs`
Expected: `0`. If any describe blocks remain, they were missed by Tasks 7–10; port or delete them before continuing.

- [ ] **Step 6: Delete the empty file**

```bash
git rm test/docker_test.exs
```

- [ ] **Step 7: Run the whole suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
mix format
git add -A
git commit -m "Rewrite the build tests against a real daemon and drop docker_test

Builds a real image from a fixture Dockerfile, runs a container from it,
and reads back what the Dockerfile wrote. delete_image is covered here,
where a throwaway image exists to delete.

docker_test.exs is gone: its 34 describe blocks are now spread across
suites named for what they test, and its pure-function tests moved to
util_test and instance_test."
```

---

### Task 11: Reduce sandbox_test.exs to the sandbox as a feature

The sandbox stays as product surface, so it gets tested the way a downstream user uses it — registering responses, matching a ref, and getting a clear error on a bad registration. It stops being tested by introspecting its own export table.

**Files:**
- Modify: `test/docker/engine/sandbox_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Delete the export-introspection test**

From `test/docker/engine/sandbox_test.exs`, delete the whole test beginning `test "every action in the canonical table is exported with the right arity"`, together with the comment block above it and the `@actions` module attribute if nothing else uses it.

Run: `grep -n "@actions" test/docker/engine/sandbox_test.exs`
If there are no remaining references, delete the attribute too.

- [ ] **Step 2: Confirm what remains is user-facing**

Run: `grep -n "__info__\|:functions\|Code.ensure_loaded" test/docker/engine/sandbox_test.exs`
Expected: no output. Any hit is a test reaching into the implementation — delete it.

- [ ] **Step 3: Run the suite**

Run: `mix test test/docker/engine/sandbox_test.exs`
Expected: PASS. The remaining tests register responses and call the public API through `sandbox: [enabled: true]`, which is exactly how a downstream user uses the feature.

- [ ] **Step 4: Run the whole suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
mix format
git add test/docker/engine/sandbox_test.exs
git commit -m "Test the sandbox as a feature, not by introspection

The exhaustive test read Docker.Sandbox.__info__(:functions) to assert
every action exports the right helper names, which is a test written from
the implementation's point of view. What remains registers responses and
calls the public API, the way a downstream user uses the sandbox.

The lost guarantee is that no action is missing its helpers; actions are
covered by being used."
```

---

### Task 12: Final sweep and honest reporting

**Files:**
- Modify: `README.md` if it documents the removed behaviour

**Interfaces:**
- Consumes: every earlier task.
- Produces: nothing.

- [ ] **Step 1: Confirm the deletions are complete**

Run:
```bash
grep -rn "FakeHttpServer\|fallback_code\|stat_error\|@tag :exhaustive\|:external_ssh\|:pending" lib/ test/ mix.exs
```
Expected: no output.

- [ ] **Step 2: Confirm no leftover containers or images**

Run:
```bash
docker ps -a --filter name=docker-ex-test --format '{{.Names}}'
docker images --filter reference='docker-ex-test-build*' --format '{{.Repository}}'
```
Expected: no output from either. Any leftovers mean a test is missing its `on_exit`.

- [ ] **Step 3: Run the full suite from clean**

Run:
```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix test
```
Expected: all three clean.

- [ ] **Step 4: Record the before and after**

Run: `mix coveralls`

Write down the new total and the per-file figures. Compare against the pre-sweep baseline recorded in the design doc:

```
network.ex 27.4%   exec.ex 45.2%   session.ex 22.2%
image.ex   54.6%   containers.ex 64.6%   TOTAL 61.0%
```

The modules deployd exercises should climb. `terminal.ex`, `session.ex` and `streaming.ex` will fall, because nothing exercises them any more and the sandbox tests that used to inflate them are gone. Both movements are correct.

- [ ] **Step 5: Check the docs for statements that are no longer true**

Run:
```bash
grep -rn "sandbox\|Sandbox" README.md
```
If the README describes the sandbox as the way to test this library, correct it: the sandbox is for downstream users testing *their* code against this library.

- [ ] **Step 6: Commit**

```bash
mix format
git add -A
git commit -m "Record the post-sweep coverage baseline

Coverage falls where sandbox-stubbed tests used to execute none of the
code they named, and rises on the paths a caller actually reaches. Both
movements are the intended outcome."
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| Delete FakeHttpServer | 6 |
| Delete `client.ex` defensive branches | 3 |
| Collapse `containers.ex` stat pipeline | 4 |
| Real-daemon test strategy | 2, 7–10 |
| Sandbox shrinks to a feature suite | 11 |
| Delete the `@tag :exhaustive` introspection test | 11 |
| Remove dead tags | 1 |
| Backwards-compat: nothing to remove | no task needed — the spec records both candidates as false positives that stay |
| Every module stays | no task — verified by the absence of any deletion task touching `terminal.ex`, `network.ex`, `session.ex`, `streaming.ex`, `info.ex` |
| Coverage will fall, honestly reported | 12 |

**Additions beyond the spec's explicit list**

The spec named `client.ex` and `containers.ex`'s stat pipeline. Applying the same principle turned up three more sites, all added to this plan:

- `containers.ex` `interpret_create_response/2` catch-all (Task 4)
- `network.ex` "created a network but returned no ID" (Task 5)
- `exec.ex` "created an exec instance but returned no ID" (Task 5)

Left alone deliberately, because they handle *local* failures rather than malformed daemon responses: `containers.ex:705` (writing a tar to disk), `image.ex:572` (`tar` exiting non-zero), `util.ex:15,22` (`:erl_tar` failures), `client.ex:374` (the connection closing).

**Placeholder scan:** no TBD, no "similar to Task N", no "add error handling". Every code step carries the code.

**Type consistency:** `create_container!/2` and `start_container!/2` return a bare container id binary in Task 2 and are used that way in Tasks 3, 4, 5, 7, 9, 10. `Docker.create_container/5` returns `{:ok, id}` where `id` is a binary, matching `interpret_create_response/2`. `Docker.wait_container/3` returns a string-keyed map, so tests match `%{"StatusCode" => 0}`. `Docker.exec_inspect/2` returns string keys (`"ExitCode"`, `"Running"`), while `Docker.exec_run_with_status/3` returns the atom-keyed map this library builds — both used accordingly in Task 9.

**Known gap, stated rather than hidden:** `download_archive/4` loses its dedicated coverage. Tasks 4 and 10 cover `get_archive`, `put_archive` and `stat_archive`, but `download_archive` writes a tar to a local path and its old tests were sandbox-stubbed. Add a test for it in Task 4 if the reviewer wants it covered; it is otherwise exercised only by deployd.
