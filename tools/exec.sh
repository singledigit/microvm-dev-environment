#!/bin/bash
# Connect an interactive shell to a user's iPad Claude MicroVM.
# Usage: ./tools/exec.sh --user <email> [--root]
set -euo pipefail
DIR="$(unset CDPATH; cd "$(dirname "$0")" && pwd)"
exec node "$DIR/exec.js" "$@"
