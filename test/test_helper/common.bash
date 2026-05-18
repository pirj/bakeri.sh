#!/usr/bin/env bash

_common_setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'

    # bakeri.sh tests depend on the rlock framework for shared lib + protocol.
    # Two layout options:
    #   1. RL_FRAMEWORK_DIR set by the caller (CI, local dev with custom paths).
    #   2. Default: ../rlock relative to this distribution's project root
    #      (matches the migration plan's recommended side-by-side checkout).
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    RL_FRAMEWORK_DIR="${RL_FRAMEWORK_DIR:-$(cd "$PROJECT_ROOT/../rlock" 2>/dev/null && pwd)}"

    if [[ -z "$RL_FRAMEWORK_DIR" || ! -d "$RL_FRAMEWORK_DIR/lib" ]]; then
        echo "ERROR: rlock framework not found." >&2
        echo "Set RL_FRAMEWORK_DIR to the rlock checkout, or place bakeri.sh next to rlock/ as siblings." >&2
        exit 1
    fi

    LIB_DIR="$RL_FRAMEWORK_DIR/lib"
}
