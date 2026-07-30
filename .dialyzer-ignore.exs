# .dialyzer-ignore.exs
#
# No suppressions. The previous entry excused a defensive fallback clause
# in `lib/docker/minty/streamer/impl.ex`, a file that no longer exists.
# Unexpected values are now allowed to crash rather than being absorbed by
# fallback clauses Dialyzer cannot reach, so there is nothing to excuse.
[]
