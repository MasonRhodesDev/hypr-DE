#!/bin/sh
set -eu
here=$(dirname -- "$0")
cd -- "$here/../.."
[ $# -gt 0 ] || set -- all
exec python3 -I tests/gates/gate.py "$@"
