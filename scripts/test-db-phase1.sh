#!/usr/bin/env bash
set -euo pipefail
# Compatibility entry point: only runner-owned disposable resources may be destroyed.
exec node "$(dirname "$0")/test-db.mjs" "$@"
