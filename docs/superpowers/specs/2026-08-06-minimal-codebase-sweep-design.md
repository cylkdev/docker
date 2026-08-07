# Minimal codebase sweep — design

The library handles what the Docker daemon actually does, and tests it the way
a caller uses it. Responses the daemon cannot produce are not handled, and the
test infrastructure that exists only to manufacture those responses goes with
them.

## Why

`mix coveralls` reports 61% overall, but the number hides the shape of the
problem rather than showing it:

    network.ex     27.4%      exec.ex        45.2%
    session.ex     22.2%      image.ex       54.6%
    stream_error   0.0%       containers.ex  64.6%

136 of 178 tests register a canned response through `Docker.Sandbox` and then
assert that same value comes back. Those tests pass without the library's URL
building, query encoding, status handling, or response decoding ever running,
which is why the modules that do that work sit between 22% and 65%.

`test/docker/containers_test.exs` already says so in its own moduledoc —
*"covering the request-building and response-decoding that sandbox mode
bypasses"*.

Meanwhile `test/support/` holds a second mock, 655 lines of it. Reading what it
is used for is the finding that drives this sweep:

| Test | Response being manufactured |
|---|---|
| `client_test.exs:95` | a plain-text error body |
| `client_test.exs:102` | an empty error body |
| `client_test.exs:111` | a status outside `ErrorMessage`'s table |
| `client_test.exs:118` | a body that will not decode |
| `containers_test.exs:118` | an undecodable base64 stat header |
| `containers_test.exs:127` | valid base64 that is not JSON |
| `containers_test.exs:136` | JSON that is not an object |

A docker daemon sends none of these. `FakeHttpServer` exists to reach defensive
branches that handle impossible input, and those branches exist because the
fake makes them look testable. The two hold each other up.

## The two mocks

They are not duplicates, which is why both survived this long. Naming their
jobs settles which one stays:

| | Purpose | Verdict |
|---|---|---|
| `Docker.Sandbox` | downstream users stub docker in **their** tests | product surface — stays |
| `FakeHttpServer` | manufacture responses the daemon cannot send | scaffolding — deleted |
| real daemon | what deployd's `tools_test.exs` already does | the library's own test strategy |

After this sweep there are two test-time constructs, not three, and each has
one job.

## What gets deleted

**Test scaffolding.** `test/support/fake_http_server.ex` (486 lines),
`test/support/fake_http_server/impl.ex` (169), and the tests that exist only to
drive them.

**Defensive branches in `client.ex`.** The plain-text-body and empty-body arms
of `daemon_message/2` and its non-binary catch-all; `status_code/1`'s
`function_exported?` guard, its `rescue ArgumentError`, and `fallback_code/1`.
The daemon sends JSON carrying a `"message"` key and a status from a documented
set.

**Defensive branches in `containers.ex`.** `decode_path_stat/3` is a four-stage
pipeline reporting `:missing_header`, `:invalid_base64`, `:invalid_json` and
`:not_an_object` for a header the daemon always sends as valid base64 JSON. It
collapses to a direct decode.

### The failure-mode change

Deleting these branches means an unexpected daemon response raises a
`MatchError` instead of returning an `ErrorMessage`. This is deliberate and was
chosen over keeping a single catch-all per boundary. A crash on input that
cannot occur is a bug report; an `ErrorMessage` for it is a guess dressed as
handling. Anyone reconsidering this should reconsider it here rather than
re-adding branches one at a time.

## Test strategy

Tests drive the public `Docker.*` facade against a real daemon on `alpine`,
each cleaning up the containers and images it creates, following
`deployd/test/deployd/backends/docker/tools_test.exs`. **CI requires a running
docker daemon.**

The 136 sandbox-stubbed tests split two ways:

- **Behaviour tests** — the 64 tests across 34 `describe` blocks in
  `test/docker_test.exs` — get rewritten against the daemon. `list_containers`
  asserts that containers come back and that filters narrow them, not that a
  registered map is returned verbatim.
- **Sandbox tests** shrink to a focused suite proving the sandbox feature
  works, because it is product surface: registering responses, matching a regex
  against a ref, and raising clearly on an arity mismatch. Tested as a
  downstream user would use it.

Deleted outright: the `@tag :exhaustive` test at `sandbox_test.exs:218`, which
reads `Docker.Sandbox.__info__(:functions)` to assert every action exports the
right helper names. Introspecting a module's own export table is the clearest
case of a test written from the implementation's point of view. The cost is
losing an automatic check that no action is missing its helpers; actions are
covered by being used instead.

Error paths stay reachable without a fake:

- 404, 409 and 304 — ask the daemon for something that does not exist.
- `:service_unavailable` — point `socket_path` at a nonexistent file, which is
  already how `client_test.exs:129` works.

## Tags

`test/test_helper.exs` excludes `:external_ssh` and `:pending`. No test carries
either tag, so both exclusions are dead configuration. The only real tag,
`@tag :exhaustive`, is not in the exclude list and therefore never changed what
ran. All three go, leaving `ExUnit.start()` and the sandbox registry start.

## Backwards compatibility

`lib/` contains no `deprecated`, `legacy` or `compat` markers. Two candidates
are false positives and stay:

- `label: ["env=prod"]` is the Engine's required wire format and what the
  Python and Go SDKs emit. Not a shim.
- `exec_run_with_status/3`'s atom-keyed `%{output:, exit_code:, running:}` is a
  map this library constructs from literals, not a daemon response passed
  through.

## What stays

Every module: `Terminal`, `Session`, `Streaming`, `Network` and `Info` are kept
whole, including the parts deployd never calls. `Docker.Frame` is load-bearing
in `client.ex` and `containers.ex`. `Docker.StreamError` is raised on three
real paths in `client.ex` — untested rather than dead, and reachable from the
real-daemon suite.

## Expected outcome

`lib/` loses roughly 60–80 lines of branches. `test/` loses 655 lines of
infrastructure, and about 178 tests become 60–80 that each prove more.

Coverage percentages will fall, and that is the intended result rather than a
regression. Today's figure counts sandbox-stubbed tests that execute none of
the code they name; tomorrow's will count only paths a caller actually reaches.
The streaming and network paths deployd never exercises will read as uncovered,
which is accurate.

## Order

1. Tags — `test_helper.exs` and `@tag :exhaustive`. Independent of everything
   else.
2. Delete the defensive branches in `client.ex` and `containers.ex` together
   with the tests that manufacture their inputs.
3. Delete `FakeHttpServer` and rewrite what remains of `client_test.exs` and
   `containers_test.exs` against the daemon.
4. Rewrite `docker_test.exs` against the daemon, one `describe` block at a
   time.
5. Reduce `sandbox_test.exs` to the sandbox-as-feature suite.
