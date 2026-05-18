#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/bake-cache"
    CMD="$PLUGIN_DIR/commands/bake-cache.sh"

    # Provide minimal stub ui.sh so the script can source it without
    # depending on the framework runtime.
    STUB_LIB="$BATS_TEST_TMPDIR/stub_lib"
    mkdir -p "$STUB_LIB"
    cat > "$STUB_LIB/ui.sh" <<'STUB'
info() { echo "[info] $*"; }
warn() { echo "[warn] $*" >&2; }
STUB

    CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$CACHE_DIR"
}

@test "bake-cache plugin declares the bake-cache command" {
    run grep -q 'commands *= *\["bake-cache"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "bake-cache plugin has no [snapshot] section (command-only)" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_failure
}

@test "bake-cache prints 'Cache empty' when no entries" {
    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD"
    assert_success
    assert_output --partial "Cache empty"
}

@test "bake-cache lists a cold entry with disk size and no memory" {
    local entry="$CACHE_DIR/ruby-bundler/abc123"
    mkdir -p "$entry"
    dd if=/dev/zero of="$entry/disk.qcow2" bs=1024 count=10 2>/dev/null
    cat > "$entry/meta.json" <<'M'
{ "plugin": "ruby-bundler", "key": "abc123", "kind": "cold" }
M

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD"
    assert_success
    assert_output --partial "ruby-bundler"
    assert_output --partial "abc123"
    assert_output --partial "cold"
    # Memory column should show '-' for a cold entry.
    [[ "$output" == *"-"* ]]
}

@test "bake-cache lists a live entry with disk + memory sizes" {
    local entry="$CACHE_DIR/docker-compose/def456"
    mkdir -p "$entry"
    dd if=/dev/zero of="$entry/disk.qcow2" bs=1024 count=10 2>/dev/null
    dd if=/dev/zero of="$entry/memory.bin" bs=1024 count=20 2>/dev/null
    cat > "$entry/meta.json" <<'M'
{ "plugin": "docker-compose", "key": "def456", "kind": "live" }
M

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD"
    assert_success
    assert_output --partial "docker-compose"
    assert_output --partial "def456"
    assert_output --partial "live"
}

@test "bake-cache shows last-prune line when log exists" {
    local entry="$CACHE_DIR/p/k"
    mkdir -p "$entry"
    dd if=/dev/zero of="$entry/disk.qcow2" bs=1024 count=1 2>/dev/null
    echo "Pruned 3 stale snapshots (240 MB)" > "$CACHE_DIR/.last-prune.log"

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD"
    assert_success
    assert_output --partial "Last prune: Pruned 3"
}
