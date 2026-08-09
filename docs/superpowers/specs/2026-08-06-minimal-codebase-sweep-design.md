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

## Post-sweep coverage

Captured from `mix coveralls` immediately after the twelve sweep tasks, before
the final review's fixes (140 tests, 3 doctests, 0
failures):

```
COV    FILE                                                                           LINES RELEVANT   MISSED
100.0% lib/docker.ex                                                                    369        0        0
100.0% lib/docker/application.ex                                                         14        2        0
 62.3% lib/docker/client.ex                                                             435      101       38
 75.0% lib/docker/config.ex                                                              34        4        1
 75.6% lib/docker/containers.ex                                                        1068      119       29
 73.0% lib/docker/exec.ex                                                               424       52       14
100.0% lib/docker/frame.ex                                                              352       17        0
 62.8% lib/docker/image.ex                                                              741       97       36
 88.8% lib/docker/info.ex                                                                86        9        1
 85.1% lib/docker/instance.ex                                                           164       27        4
100.0% lib/docker/log.ex                                                                 84       16        0
100.0% lib/docker/ndjson.ex                                                              74        7        0
 74.0% lib/docker/network.ex                                                            407       50       13
 24.2% lib/docker/sandbox.ex                                                           1092      305      231
 22.2% lib/docker/session.ex                                                              88       18       14
  0.0% lib/docker/stream_error.ex                                                        44        4        4
 35.0% lib/docker/streaming.ex                                                          125       20       13
 75.0% lib/docker/streaming/session.ex                                                  286       60       15
100.0% lib/docker/streaming/session_handler.ex                                           78       10        0
 72.0% lib/docker/terminal.ex                                                           312       50       14
 85.3% lib/docker/util.ex                                                               201       41        6
100.0% test/support/daemon_case.ex                                                       57       10        0
[TOTAL]  57.5%
```

The TOTAL fell 61.0% → 57.5%, but that fall is dominated by one file:
`lib/docker/sandbox.ex` (1092 lines, 305 relevant) dropped 61.3% → 24.2%. The
sandbox used to be exercised as a stand-in by 136 tests that stubbed the
daemon through it; now it is exercised only by its own thin feature suite.
That is the intended outcome of shrinking the sandbox's role, not a
regression.

Set that one file aside and the picture reverses: the endpoint modules a
caller actually reaches climbed sharply — `network.ex` 27.4% → 74.0%,
`exec.ex` 45.2% → 73.0%, `containers.ex` 64.6% → 75.6%, `info.ex` 55.5% →
88.8%. These are now driven end to end against a real daemon instead of
through canned sandbox responses.

`lib/docker/client.ex` fell, 71.9% → 62.3% (missed lines 30 → 38). This one
is worth stating plainly: the deleted `FakeHttpServer` could manufacture
error responses a real docker daemon will not send, so some surviving error
paths — the transport-failure clauses and the `Docker.StreamError` raises —
are no longer exercised by anything. `lib/docker/stream_error.ex` remains at
0.0% for the same reason. This is a real, accepted trade of synthetic
coverage for honest coverage, not an oversight.

### After the final review

The whole-branch review found two of the gaps above were not trade-offs but
oversights, and they were fixed. Final figures, 139 tests / 3 doctests / 0
failures:

```
 70.2% lib/docker/client.ex       77.3% lib/docker/containers.ex
 76.0% lib/docker/network.ex      73.0% lib/docker/exec.ex
100.0% lib/docker/info.ex         65.9% lib/docker/image.ex
 24.2% lib/docker/sandbox.ex       0.0% lib/docker/stream_error.ex
[TOTAL] 59.0%
```

`client.ex` recovered to 70.2% because `stream/4`'s non-2xx path got the test
it deserved. That path is not hypothetical — every streaming call
(`pull_image`, `build_image`, following logs) returns its errors through it,
and one `pull_image` of a nonexistent repository reaches it. Its only test
had been collateral damage when `FakeHttpServer` went.

The endpoint modules rose again — `containers.ex` to 77.3%, `network.ex` to
76.0%, `image.ex` to 65.9%, `info.ex` to 100% — because the sandbox suite was
rewritten to drive the public facade with `sandbox: [enabled: true]`, the way
the README documents the feature, instead of calling the dispatch layer
directly. Those 29 dispatch sites live in the endpoint modules, which is why
`sandbox.ex` itself stays at 24.2%: its remaining 231 missed lines are the
actions the focused suite deliberately does not exercise, and covering them
would mean one test per action — the thing this sweep set out to stop doing.

`stream_error.ex` stays at 0.0%, and that one really is the accepted trade:
reaching a mid-stream `raise` needs a transport failure, which cannot be
provoked against a healthy daemon without the fake this sweep deleted. It was
0.0% before the sweep too.
5. Reduce `sandbox_test.exs` to the sandbox-as-feature suite.
