#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/snapc-run"
    CMD="$PLUGIN_DIR/commands/snapc-run.sh"
}

@test "snapc-run plugin declares the 'snapc-run' command" {
    run grep -q 'commands *= *\["snapc-run"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "snapc-run plugin is command-only (no triggers, no [snapshot])" {
    # The framework's dispatch_command falls back to all discoverable
    # plugins for command lookup, so snapc-run doesn't need triggers to
    # appear in ACTIVE_PLUGINS.
    run grep -q '^triggers *= *\[\]$' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "snapc-run plugin has no [snapshot] section (command-only)" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_failure
}

@test "snapc-run command script exists and is executable" {
    [ -x "$CMD" ]
}

@test "snapc-run exits 2 with usage when no command given" {
    # Stub the libs the script sources. Provide minimal stderr/info so
    # the arg parser can emit its Usage message without aborting on
    # `command not found`.
    local stub_lib="$BATS_TEST_TMPDIR/stub_lib"
    mkdir -p "$stub_lib"
    cat > "$stub_lib/ui.sh" <<'STUB'
info() { :; }
warn() { echo "$@" >&2; }
die()  { echo "$@" >&2; exit 1; }
stderr() { echo "$@" >&2; }
STUB
    for f in util plugin toml; do : > "$stub_lib/$f.sh"; done

    run env RL_LIB_DIR="$stub_lib" bash "$CMD"
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "snapc-run exits 2 on unknown flag" {
    local stub_lib="$BATS_TEST_TMPDIR/stub_lib"
    mkdir -p "$stub_lib"
    cat > "$stub_lib/ui.sh" <<'STUB'
info() { :; }
warn() { echo "$@" >&2; }
die()  { echo "$@" >&2; exit 1; }
stderr() { echo "$@" >&2; }
STUB
    for f in util plugin toml; do : > "$stub_lib/$f.sh"; done

    run env RL_LIB_DIR="$stub_lib" bash "$CMD" --bogus
    assert_failure 2
    assert_output --partial "unknown flag"
}

@test "snapc-run accepts --no-push and then a command" {
    # Stub the libs plus the framework helpers the script invokes after
    # arg parsing, so we exercise the parse + branch decision without
    # spinning a real VM.
    local stub_lib="$BATS_TEST_TMPDIR/stub_lib"
    mkdir -p "$stub_lib"
    for f in ui util plugin toml; do : > "$stub_lib/$f.sh"; done

    # Provide stub functions for everything snapc-run calls.
    cat > "$stub_lib/ui.sh" <<'STUB'
info() { echo "[info] $*"; }
warn() { echo "[warn] $*" >&2; }
die()  { echo "ERR: $*" >&2; exit 1; }
stderr() { echo "$@" >&2; }
STUB
    cat > "$stub_lib/util.sh" <<'STUB'
resolve_vm_name() { echo "stub-vm"; }
do_ssh() { echo "DOSSH:$*"; return 7; }
STUB
    cat > "$stub_lib/plugin.sh" <<'STUB'
discover_plugins() { :; }
detect_triggers()  { :; }
STUB
    # Make AQ_STATE_DIR/stub-vm exist so the "provision if missing" branch
    # is skipped.
    export AQ_STATE_DIR="$BATS_TEST_TMPDIR/aq_state"
    mkdir -p "$AQ_STATE_DIR/stub-vm"

    run env RL_LIB_DIR="$stub_lib" bash "$CMD" --no-push -- echo hi
    # do_ssh returned 7 → snapc-run should exit with 7.
    [ "$status" -eq 7 ]
    [[ "$output" == *"DOSSH:"* ]]
}
