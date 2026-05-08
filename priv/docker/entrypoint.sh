#!/bin/sh
echo READY

if [ "$1" = "repl" ]; then
  while IFS= read -r line; do
    echo "got: $line"
  done
  exit 0
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec sh
fi
