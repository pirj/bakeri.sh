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
info()   { echo "[info] $*"; }
warn()   { echo "[warn] $*" >&2; }
stderr() { echo "$@" >&2; }
die()    { echo "Error: $*" >&2; exit 1; }
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

@test "bake-cache --rm <plugin> drops every entry for that plugin" {
    mkdir -p "$CACHE_DIR/ruby-bundler/k1" "$CACHE_DIR/ruby-bundler/k2" "$CACHE_DIR/npm/k1"
    touch "$CACHE_DIR/ruby-bundler/k1/disk.qcow2" \
          "$CACHE_DIR/ruby-bundler/k2/disk.qcow2" \
          "$CACHE_DIR/npm/k1/disk.qcow2"

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --rm ruby-bundler
    assert_success
    [ ! -d "$CACHE_DIR/ruby-bundler" ]
    [ -f "$CACHE_DIR/npm/k1/disk.qcow2" ]
}

@test "bake-cache --rm <plugin>:<key> drops one entry only" {
    mkdir -p "$CACHE_DIR/ruby-bundler/k1" "$CACHE_DIR/ruby-bundler/k2"
    touch "$CACHE_DIR/ruby-bundler/k1/disk.qcow2" \
          "$CACHE_DIR/ruby-bundler/k2/disk.qcow2"

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --rm ruby-bundler:k1
    assert_success
    [ ! -d "$CACHE_DIR/ruby-bundler/k1" ]
    [ -f "$CACHE_DIR/ruby-bundler/k2/disk.qcow2" ]
}

@test "bake-cache --rm reports no-op for unknown plugin" {
    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --rm never-existed
    assert_success
    assert_output --partial "No cache entries"
}

@test "bake-cache --rebuild drops plugin + descendants" {
    # docker-compose has parent_plugin = docker-engine in its meta.json,
    # so --rebuild docker-engine should also drop docker-compose entries.
    mkdir -p "$CACHE_DIR/docker-engine/de_k1" "$CACHE_DIR/docker-compose/dc_k1" "$CACHE_DIR/unrelated/u_k1"
    touch "$CACHE_DIR/docker-engine/de_k1/disk.qcow2" \
          "$CACHE_DIR/docker-compose/dc_k1/disk.qcow2" \
          "$CACHE_DIR/unrelated/u_k1/disk.qcow2"
    cat > "$CACHE_DIR/docker-engine/de_k1/meta.json" <<'M'
{ "plugin": "docker-engine", "parent_plugin": "" }
M
    cat > "$CACHE_DIR/docker-compose/dc_k1/meta.json" <<'M'
{ "plugin": "docker-compose", "parent_plugin": "docker-engine" }
M
    cat > "$CACHE_DIR/unrelated/u_k1/meta.json" <<'M'
{ "plugin": "unrelated", "parent_plugin": "" }
M

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --rebuild docker-engine
    assert_success
    [ ! -d "$CACHE_DIR/docker-engine" ]
    [ ! -d "$CACHE_DIR/docker-compose/dc_k1" ]
    [ -f "$CACHE_DIR/unrelated/u_k1/disk.qcow2" ]
}

# --- push / pull via OCI -------------------------------------------------
#
# `oras` is mocked with a shell script that records its argv to
# bin_stub/oras.log and, for `oras push`, just creates a sentinel file
# so the script's `tar` work can be observed. For `oras pull` it writes
# pre-canned tarballs into the output dir.

_setup_oras_stub_for_push() {
    local bin_stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_stub"
    cat > "$bin_stub/oras" <<'ORAS'
#!/usr/bin/env bash
# Record argv (and cwd so we can verify staging-dir relative-paths).
echo "cwd=$(pwd)" >> "$BATS_TEST_TMPDIR/oras.log"
echo "argv=$*"    >> "$BATS_TEST_TMPDIR/oras.log"
ORAS
    chmod +x "$bin_stub/oras"
    PATH="$bin_stub:$PATH"
    export PATH
}

@test "bake-cache --push errors without ref" {
    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --push
    assert_failure 2
    assert_output --partial "Usage: rl bake-cache --push"
}

@test "bake-cache --push errors when oras is not installed" {
    # PATH that has /bin (for bash itself) but not the stub dir → oras absent.
    run env PATH="/bin:/usr/bin" RL_LIB_DIR="$STUB_LIB" \
        RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --push ghcr.io/x/y:latest
    assert_failure 1
    assert_output --partial "oras CLI required"
}

@test "bake-cache --push is a no-op when cache is empty" {
    _setup_oras_stub_for_push
    rm -rf "$CACHE_DIR"
    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --push ghcr.io/x/y:latest
    assert_success
    assert_output --partial "Cache empty"
    # oras must not have been called.
    [ ! -f "$BATS_TEST_TMPDIR/oras.log" ]
}

@test "bake-cache --push tars every layer and invokes oras push" {
    _setup_oras_stub_for_push
    mkdir -p "$CACHE_DIR/_base/k1" "$CACHE_DIR/docker-compose/k2"
    echo "diskbytes" > "$CACHE_DIR/_base/k1/disk.qcow2"
    echo '{"kind":"cold"}' > "$CACHE_DIR/_base/k1/meta.json"
    echo "diskbytes" > "$CACHE_DIR/docker-compose/k2/disk.qcow2"
    echo "memzst"   > "$CACHE_DIR/docker-compose/k2/memory.bin.zst"

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --push ghcr.io/x/y:latest
    assert_success
    assert_output --partial "Pushing 2 layers"

    # oras was invoked once.
    [ -f "$BATS_TEST_TMPDIR/oras.log" ]
    local oras_argv
    oras_argv=$(grep '^argv=' "$BATS_TEST_TMPDIR/oras.log")
    [[ "$oras_argv" == *"push"* ]]
    [[ "$oras_argv" == *"ghcr.io/x/y:latest"* ]]
    # Each layer should appear as a tar.gz arg with the bakerish media
    # type annotation.
    [[ "$oras_argv" == *"_base__k1.tar.gz:application/vnd.bakerish.layer.v1+gzip"* ]]
    [[ "$oras_argv" == *"docker-compose__k2.tar.gz:application/vnd.bakerish.layer.v1+gzip"* ]]
}

@test "bake-cache --pull errors without ref" {
    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --pull
    assert_failure 2
    assert_output --partial "Usage: rl bake-cache --pull"
}

@test "bake-cache --pull errors when oras is not installed" {
    run env PATH="/bin:/usr/bin" RL_LIB_DIR="$STUB_LIB" \
        RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --pull ghcr.io/x/y:latest
    assert_failure 1
    assert_output --partial "oras CLI required"
}

@test "bake-cache --pull untars layers from the artifact into RL_CACHE_DIR" {
    # Oras stub for pull: it writes two pre-canned tarballs into the
    # output dir (the -o argument), simulating what a real pull would
    # produce.
    local bin_stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_stub"
    cat > "$bin_stub/oras" <<'ORAS'
#!/usr/bin/env bash
# Parse `oras pull <ref> -o <dir>`.
out_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out_dir="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[ -n "$out_dir" ] || { echo "stub: missing -o" >&2; exit 1; }

# Cook up two layer tarballs whose roots are "<plugin>/<key>/<file>".
staging=$(mktemp -d)
mkdir -p "$staging/_base/restored-k1"
echo "from-registry-base"   > "$staging/_base/restored-k1/disk.qcow2"
echo '{"kind":"cold"}'      > "$staging/_base/restored-k1/meta.json"
tar czf "$out_dir/_base__restored-k1.tar.gz" -C "$staging" _base/restored-k1

mkdir -p "$staging/docker-compose/restored-k2"
echo "from-registry-compose" > "$staging/docker-compose/restored-k2/disk.qcow2"
tar czf "$out_dir/docker-compose__restored-k2.tar.gz" -C "$staging" docker-compose/restored-k2
rm -rf "$staging"
ORAS
    chmod +x "$bin_stub/oras"
    PATH="$bin_stub:$PATH"
    export PATH

    run env RL_LIB_DIR="$STUB_LIB" RL_CACHE_DIR="$CACHE_DIR" bash "$CMD" --pull ghcr.io/x/y:latest
    assert_success
    assert_output --partial "restored 2 layer(s)"

    # The fake artifact's two layers should now exist under CACHE_DIR.
    [ -f "$CACHE_DIR/_base/restored-k1/disk.qcow2" ]
    [ -f "$CACHE_DIR/docker-compose/restored-k2/disk.qcow2" ]
    [ "$(cat "$CACHE_DIR/_base/restored-k1/disk.qcow2")" = "from-registry-base" ]
}
