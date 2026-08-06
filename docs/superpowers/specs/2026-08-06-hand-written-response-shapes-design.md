# Hand-written response shapes — design

`Docker.Serializer` goes away. Every function that returns a daemon response
maps it by hand, so the shape a caller gets is written in the function that
returns it.

## Why

`Serializer.deserialize/2` recurses through a response calling
`String.to_atom/1` on every string key at every depth. Some of those keys are
Docker's own field names, a fixed vocabulary. Others are written by whoever
built the image or created the container, and are unbounded.

Measured, on a fresh VM, through `Docker.Image.find_image/2`:

    inspect an image with 2 novel label keys    atom_count +546   (Docker's own names, once)
    inspect a second such image                 atom_count +2
    inspect a third                             atom_count +2
    inspect an image with 20 novel label keys   atom_count +20

Each measurement follows `:erlang.garbage_collect/0`. Atoms are never
collected. The ceiling is `:erlang.system_info(:atom_limit)`, 1,048,576 by
default, and crossing it aborts the VM with `system_limit` rather than raising
something catchable.

The input is ordinary, not contrived: image labels are written by whoever built
the image, and inspecting a public base image means inspecting a stranger's
labels.

The moduledoc already states the rule — *"Atoms are not garbage-collected, so
do not hand this function keys from an untrusted source"* — and `find_image` is
the one caller that hands it exactly that.

## The invariant

**Every atom this library produces is a literal in its source.**

That is what hand-writing buys. Not diligence, not a list of paths to skip, not
a guard that could be forgotten: there is no `String.to_atom/1` in the library,
so no response can create one. A key the daemon sends that no function names
simply does not appear in the result.

`String.to_atom/1` must not appear in `lib/`. If a future change needs it, that
is the change to argue about.

## Rules for writing a shape

**Transliterate, do not rename.** A key becomes the atom its API name says:
`"Id"` to `:id`, `"RepoTags"` to `:repo_tags`, `"HostConfig"` to
`:host_config`, `"NetworkSettings"` to `:network_settings`. Do not improve on
Docker's naming — a reader with the Engine API reference open should be able to
follow the mapping without a glossary. The only reason to choose a different
name is a genuine collision, where two API keys in the same map would
transliterate to one atom; note it in a comment where it happens.

**Map the whole response.** Every field the daemon sends gets a home, including
the parts nobody reads. `HostConfig` is 63 keys of cgroup limits, ulimits and
device mappings; they get written out once and are then the schema, in code.
Dropping fields would make these functions a curated view rather than a client,
and a caller needing one would have nowhere to go.

**Data never becomes a key.** Some regions of a Docker response are
dictionaries: the map's keys are the data. Those become lists, so the data
lives in values where it cannot be atomized:

    "Labels": {"com.acme.Team-Name": "platform"}
    -> labels: [%{name: "com.acme.Team-Name", value: "platform"}]

    "Networks": {"demo-net": {"NetworkID": "...", "Aliases": [...]}}
    -> networks: [%{name: "demo-net", value: %{network_id: "...", aliases: [...]}}]

`name` and `value` are the one place this design introduces names of its own,
because a dictionary entry has none to transliterate. One rule for both kinds —
scalar-valued and object-valued — so every dictionary reads the same. Do not
merge an object's fields up beside `name`: it reads better for networks and
gives two different record shapes, and breaks the day an object has its own
`Name`.

## The dictionary regions

Verified against a live daemon by walking each response and flagging every map
whose keys are not PascalCase, since Docker's own field names are.

**Container inspect**

| Path | Keys are |
|---|---|
| `Config.ExposedPorts` | `"80/tcp"` |
| `Config.Labels` | label names |
| `HostConfig.PortBindings` | `"80/tcp"` |
| `NetworkSettings.Networks` | network names |
| `NetworkSettings.Ports` | `"80/tcp"` |

**Image inspect**

| Path | Keys are |
|---|---|
| `Config.Labels` | label names |
| `Config.ExposedPorts` | port specs |
| `Config.Volumes` | container paths |
| `GraphDriver.Data` | storage-driver field names |

`Config.Volumes` and `GraphDriver.Data` do not appear on a minimal image such
as `alpine`, so a test fixture must carry a `VOLUME` and be inspected on a real
storage driver for those paths to be exercised.

This list is a finding, not a guarantee. It was produced from responses this
machine could generate; a container using features these did not exercise may
carry others. That is precisely why the invariant above does not depend on the
list being complete — a region nobody hand-wrote is absent from the result,
which a test notices, rather than silently atomized.

## Scope

Twenty-odd call sites return a daemon body today, and only two of them
deserialize. The rest return raw string-keyed maps, which is why
`find_container` and `list_containers` disagree with `find_image` about key
type. Under this design they all get hand-written shapes, and the disagreement
goes away.

    exec.ex        3 sites   (exec_start output, exec_create, exec_inspect)
    containers.ex  9 sites   (inspect, list, create, start, stop, delete,
                              archive put/get, wait)
    image.ex       3 sites   (list, inspect, delete)
    network.ex     4 sites
    info.ex        1 site

Many are trivial — a delete returns little or nothing. The weight is container
inspect at 166 keys, image inspect at 38, and a container list entry at 42.

## Order

1. `Docker.Image.find_image/2` — 38 keys, three deep, and the function whose
   current behaviour caused this. Establishes the pattern and the dictionary
   helper.
2. `Docker.Containers.find_container/2` — the big one, 166 keys, and the place
   the `HostConfig` slog lands.
3. `Docker.Containers.list_containers/2` — a different, flatter shape with
   `Labels` at the top level rather than under `Config`.
4. The remaining endpoints, smallest first.
5. Delete `Docker.Serializer`. Check whether `Docker.Casing` has any caller
   left; today the serializer is its only one in this repo, but confirm against
   anything else that depends on this library before removing it.

## Consequences for `deployd`

`deployd`'s docker backend passes these responses through untouched, so its
tests assert whatever this library returns. When a shape lands, the matching
assertions in `test/deployd/backends/docker/tools_test.exs` change with it, and
the caveat in the backend's moduledoc about which call returns which key type
is deleted rather than rewritten, because it stops being true.
