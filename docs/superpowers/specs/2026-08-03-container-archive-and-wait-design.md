# Design: container archive reads and `/wait`

Date: 2026-08-03

## Goal

Add three Docker Engine container endpoints to `Docker.Containers`:

- `GET /containers/{id}/archive` — download a path from a container as a tar
  archive. The read counterpart to the existing `put_archive/4`.
- `HEAD /containers/{id}/archive` — stat a path inside a container without
  transferring its contents.
- `POST /containers/{id}/wait` — block until a container stops and report its
  exit status.

Plus one convenience function, `download_archive/4`, that writes a downloaded
archive to the local filesystem.

Every function follows the shape already established by `put_archive/4` and
`delete_container/3`: a public function that checks `sandbox?(options)` and
dispatches either to a sandbox stub or to a private `do_*` implementation, with
`Docker` delegating to it.

## `get_archive(container_ref, src_path, options \\ [])`

```elixir
@spec get_archive(Docker.container_ref(), binary(), Docker.options()) ::
        Docker.result(binary())
```

Issues `GET /containers/#{container_ref}/archive?path=#{src_path}` with a `nil`
request body and returns `{:ok, tar_binary}`.

The daemon responds with `Content-Type: application/x-tar`, which
`Docker.Client` does not decode — the body arrives as a raw binary and is
returned unchanged. No changes to `Docker.Client` are required.

**The returned tar is the daemon's outer archive, verbatim.** Docker always
wraps the requested path in a tar, so `get_archive("c1", "/release.tar.gz")`
returns a tar containing one entry named `release.tar.gz`. This function does
not unwrap it; extracting is the caller's step and behaves identically whether
`src_path` named a file or a directory.

```elixir
{:ok, tar} = Docker.get_archive("c1", "/app/build")
{:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
```

Errors come from the existing `Docker.Client` mapping:

- `:bad_request` — `src_path` is not absolute, or the daemon otherwise rejects
  the request.
- `:not_found` — the container does not exist, or the path does not exist
  inside it.

## `download_archive(container_ref, src_path, dest_path, options \\ [])`

```elixir
@spec download_archive(
        Docker.container_ref(),
        binary(),
        binary(),
        Docker.options()
      ) :: Docker.result(binary())
```

Calls `get_archive/3` and puts the result on the local filesystem at
`dest_path`, returning `{:ok, dest_path}`. The argument order mirrors
`put_archive/4`: container ref, then the remote path, then the local path.

`options` accepts `:extract` (boolean, default `false`) in addition to the
standard options. **`:extract` changes what `dest_path` means**, because one
path argument cannot be both a file to create and a directory to populate:

- `extract: false` (default) — `dest_path` is the tar file to write. The bytes
  are written verbatim; the file is the daemon's outer archive, unmodified.

  ```elixir
  {:ok, "/tmp/build.tar"} =
    Docker.download_archive("my-container", "/app/build", "/tmp/build.tar")
  ```

- `extract: true` — `dest_path` is a directory to extract into. It is created
  with `File.mkdir_p/1` if absent, then the archive is unpacked there with
  `:erl_tar.extract({:binary, tar}, [{:cwd, dest_path}])`. Entries land relative
  to `dest_path`, so downloading `/app/build` yields `<dest_path>/build/...` —
  the inverse of how `put_archive/4` extracts relative to its `dest_path`.

  ```elixir
  {:ok, "/tmp/out"} =
    Docker.download_archive("my-container", "/app/build", "/tmp/out", extract: true)
  ```

No intermediate tar file is written in either mode; extraction reads the
in-memory binary directly. The outer archive is never gzipped, so `:compressed`
is not passed to `:erl_tar`.

Any error from `get_archive/3` propagates unchanged. A failed write, `mkdir_p`,
or extraction becomes `{:error, ErrorMessage.internal_server_error(...)}`
carrying `dest_path` and the underlying reason in its details, worded to match
`Docker.Util.create_tar/3`'s existing "Could not write the tar archive"
failures. Extraction failures reuse `create_tar/3`'s two-clause handling of
`:erl_tar`'s `{:error, {name, reason}}` and `{:error, reason}` shapes.

Because `download_archive/4` is a thin wrapper over `get_archive/3`, it gets no
sandbox stub of its own — under sandbox mode the inner `get_archive/3` call is
intercepted, and the write still happens. Registering a `get_archive` response
is therefore enough to test callers of either function.

## `stat_archive(container_ref, src_path, options \\ [])`

```elixir
@spec stat_archive(Docker.container_ref(), binary(), Docker.options()) ::
        Docker.result(map())
```

Issues `HEAD` against the same URL as `get_archive/3`. The daemon returns an
empty body and encodes the file metadata in the `x-docker-container-path-stat`
response header as base64-encoded JSON. `stat_archive/3` decodes that header and
returns `{:ok, stat_map}`.

Keys are the raw daemon keys — `"name"`, `"size"`, `"mode"`, `"mtime"`,
`"linkTarget"` — left untouched, consistent with `find_container/2` returning
`"State"`/`"Running"` as the daemon spells them.

A missing header, invalid base64, or JSON that does not decode to an object
becomes `{:error, ErrorMessage.internal_server_error(...)}` with the container
ref and path in the details map. Transport and HTTP status errors are unchanged
from `get_archive/3`.

`stat_archive/3` is the cheap way to check whether a path exists before pulling
down a potentially large directory.

## `wait_container(container_ref, params \\ %{}, options \\ [])`

```elixir
@spec wait_container(Docker.container_ref(), map(), Docker.options()) ::
        Docker.result(map())
```

Issues `POST /containers/#{container_ref}/wait` with a `nil` body, building the
URL with `Util.append_query_string/2` from `params` exactly as
`delete_container/3` does.

`params` carries `:condition` — `"not-running"` (the daemon's default when
omitted), `"next-exit"`, or `"removed"`. Values pass through unvalidated; an
unknown condition gets the daemon's own 400, which `Docker.Client` already maps
to `:bad_request`.

```elixir
{:ok, %{"StatusCode" => 0}} = Docker.wait_container("c1")
{:ok, %{"StatusCode" => 137}} = Docker.wait_container("c1", %{condition: "next-exit"})
```

**Timeout.** This endpoint long-polls: the daemon holds the connection open
until the container stops, potentially for hours. `wait_container/3` therefore
applies `Keyword.put_new(options, :receive_timeout, :infinity)` before calling
`Docker.Client`, which already accepts `:receive_timeout` as `:infinity` or a
millisecond integer (`lib/docker/client.ex:288`). A caller passing an explicit
`:receive_timeout` wins, and a bound that elapses surfaces as `:gateway_timeout`
(`lib/docker/client.ex:357`). No client changes are needed.

**Exit codes are data, not errors.** A container exiting non-zero is a
successful `/wait` call reporting a failed container, so it returns
`{:ok, %{"StatusCode" => n}}`. `{:error, _}` continues to mean the Docker call
itself failed. This also keeps the daemon's `"Error" => %{"Message" => ...}`
field reachable, which reports why the wait ended rather than why the process
did. Body decoding is automatic under the default `:auto` mode.

Errors: `:not_found` (no such container), `:bad_request` (bad condition),
`:gateway_timeout` (only reachable with an explicit bounded
`:receive_timeout`).

## Sandbox support

`get_archive/3`, `stat_archive/3`, and `wait_container/3` each gain full sandbox
parity with `put_archive/4`. `download_archive/4` does not, per above.

- `Docker.Sandbox.get_archive_response/3`, `stat_archive_response/3`, and
  `wait_container_response/3`, using the existing `find!` +
  `:erlang.fun_info` arity-dispatch pattern so registered stubs may take 0..3
  arguments.
- `set_get_archive_responses/1`, `set_stat_archive_responses/1`, and
  `set_wait_container_responses/1`.
- Matching `sandbox_*_response/3` `defdelegate`s in `Docker.Containers` under
  the dev/test branch, plus the corresponding `raise` clauses in the `else`
  branch for other environments.

## Testing

- `test/docker_test.exs` — sandbox-mode tests per function: a successful
  response, and an error response (`:not_found`) propagating unchanged.
- `stat_archive/3` — a test covering the malformed-header path, asserting
  `:internal_server_error`.
- `download_archive/4` — a test writing to a temp path, asserting the file
  contents match the registered `get_archive` response byte-for-byte; a test
  with `extract: true` against a real `:erl_tar`-built archive, asserting the
  expected files exist on disk with the expected contents and that no tar file
  is left behind; and tests asserting an unwritable `dest_path` yields
  `:internal_server_error` in each mode.
- `wait_container/3` — a test asserting a non-zero `"StatusCode"` still returns
  `{:ok, _}`.
- `test/docker/engine/sandbox_test.exs` — add `{:get_archive, 3}`,
  `{:stat_archive, 3}`, and `{:wait_container, 3}` to the list of expected
  exported functions.

## Out of scope

- Unwrapping the outer tar in `get_archive/3`. It always returns the raw
  archive; extraction is available only through `download_archive/4`'s
  `:extract` option, or by calling `:erl_tar` directly.
- In-memory extraction. `:extract` writes to disk; there is no option that
  returns `[{name, bytes}]` without touching the filesystem. Callers wanting
  that use `:erl_tar.extract({:binary, tar}, [:memory])` on `get_archive/3`'s
  result.
- Streaming the tar body. `get_archive/3` buffers the whole archive in memory,
  matching `put_archive/4` reading the whole file with `File.read/1`. A
  streaming variant can be added later if large downloads need it.
- Any helper that starts a container and waits on it, or that converts a
  non-zero exit code into an error.
- Any change to `Docker.Client`, `Docker.Util`, or `Docker.Frame`.
