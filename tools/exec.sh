#!/bin/bash
# Connect a local shell to the running iPad Claude MicroVM.
# Usage: ./scripts/exec.sh [--profile <profile>] [--region <region>]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$DIR/exec.js" "$@"
