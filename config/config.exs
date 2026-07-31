import Config

# The project's configuration.
#
# Every value below is reachable from application code through a named
# function on `Docker.Config` — no other module calls `Application` for
# configuration.
#
# Note: this is build-time config; in a release it is baked in when the
# release is assembled. Move it to `config/runtime.exs` (same shape, same
# `Docker.Config` accessors) if you need it read at boot instead.
config :docker,
  # Docker Engine API version prefixed onto request paths ("/v1.45/...").
  version: "1.45",

  # The local daemon socket. On macOS this is Docker Desktop's socket by
  # way of a symlink.
  socket_path: "/var/run/docker.sock"
