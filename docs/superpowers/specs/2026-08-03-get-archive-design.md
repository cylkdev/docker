# Design: `get_archive` and `stat_archive`

Date: 2026-08-03

## Goal

Add read support for the Docker Engine container archive endpoint, the
counterpart to the existing `Docker.Containers.put_archive/4`:

- `GET /containers/{id}/archive` — download a path from a container as a tar
  archive.
- `HEAD /containers/{id}/archive` — stat a path inside a container without
  transferring its contents.

## Public API

Both functions live in `Docker.Containers` and are delegated from `Docker`,
following the existing `put_archive` pattern.

### `get_archive(container_ref, src_path, options \\ [])`

```elixir
@spec get_archive(Docker.container_ref(), binary(), Docker.options()) ::
        Docker.result(binary())
```

Issues `GET /containers/#{container_ref}/archive?path=#{src_path}` with a `nil`
request body and returns `{:ok, tar_binary}`.

The daemon responds with `Content-Type: application/x-tar`, which
`Docker.Client` does not decode — the body arrives as a raw binary and is
returned unchanged. No changes to `Docker.Client` are required.

Callers decide what to do with the bytes:

```elixir
{:ok, tar} = Docker.get_archive("c1", "/app/build")
{:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
```

Errors come from the existing `Docker.Client` mapping:

- `:bad_request` — `src_path` is not absolute, or the daemon otherwise rejects
  the request.
- `:not_found` — the container does not exist, or the path does not exist
  inside it.

### `stat_archive(container_ref, src_path, options \\ [])`

```elixir
@spec stat_archive(Docker.container_ref(), binary(), Docker.options()) ::
        Docker.result(map())
```

Issues `HEAD` against the same URL. The daemon returns an empty body and encodes
the file metadata in the `x-docker-container-path-stat` response header as
base64-encoded JSON. `stat_archive/3` decodes that header and returns
`{:ok, stat_map}`.

Keys are the raw daemon keys — `"name"`, `"size"`, `"mode"`, `"mtime"`,
`"linkTarget"` — left untouched. This is consistent with `find_container/2`,
which returns `"State"`/`"Running"` as the daemon spells them.

Failure modes:

- The header is missing, is not valid base64, or does not decode to a JSON
  object → `{:error, ErrorMessage.internal_server_error(...)}`, with the
  container ref and path in the details map. This mirrors how
  `Docker.Util.create_tar/3` reports a malformed archive.
- Transport and HTTP status errors → unchanged `Docker.Client` behavior, same
  codes as `get_archive/3`.

`stat_archive/3` is the cheap way to check whether a path exists before pulling
down a potentially large directory.

## Sandbox support

Both functions gain full sandbox parity with `put_archive`:

- `Docker.Sandbox.get_archive_response/3` and `stat_archive_response/3`, using
  the existing `find!` + `:erlang.fun_info` arity-dispatch pattern so registered
  stubs may take 0..3 arguments.
- `Docker.Sandbox.set_get_archive_responses/1` and
  `set_stat_archive_responses/1`.
- `sandbox_get_archive_response/3` and `sandbox_stat_archive_response/3`
  `defdelegate`s in `Docker.Containers` under the dev/test branch, plus the
  matching `raise` clauses in the `else` branch for other environments.
- Each public function checks `sandbox?(options)` and dispatches to the sandbox
  or to a private `do_*` implementation, exactly as `put_archive/4` does.

## Testing

- `test/docker_test.exs` — sandbox-mode tests for both functions: a successful
  response, and an error response (`:not_found`) propagating unchanged.
- `test/docker/engine/sandbox_test.exs` — add `{:get_archive, 3}` and
  `{:stat_archive, 3}` to the list of expected exported functions.
- A `stat_archive/3` test covering the malformed-header path, asserting
  `:internal_server_error`.

## Out of scope

- Streaming the tar body. `get_archive/3` buffers the whole archive in memory,
  which matches `put_archive/4` reading the whole file with `File.read/1`. A
  streaming variant can be added later if large-directory downloads need it.
- A `get_archive_to_file`-style convenience that writes to the local
  filesystem. Callers can `File.write/2` the returned binary.
- Any change to `Docker.Client`, `Docker.Util`, or `Docker.Frame`.
