#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/bake-pr"
    CMD="$PLUGIN_DIR/commands/bake-pr.sh"

    STUB_LIB="$BATS_TEST_TMPDIR/stub_lib"
    mkdir -p "$STUB_LIB"
    cat > "$STUB_LIB/ui.sh" <<'STUB'
info() { :; }
warn() { echo "$@" >&2; }
die()  { echo "$@" >&2; exit 1; }
stderr() { echo "$@" >&2; }
STUB
    cat > "$STUB_LIB/util.sh" <<'STUB'
resolve_vm_name() { echo "stub-vm"; }
do_ssh()          { echo "DOSSH:$*"; return 0; }
STUB
}

@test "bake-pr plugin declares the bake-pr command" {
    run grep -q 'commands *= *\["bake-pr"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "bake-pr plugin requires gh + git host deps" {
    run grep -q 'host_deps *= *\["gh", "git"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "bake-pr plugin has no [snapshot] section (command-only)" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_failure
}

@test "bake-pr exits 2 when no PR ref given" {
    run env RL_LIB_DIR="$STUB_LIB" bash "$CMD"
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "bake-pr exits 2 when --cmd missing" {
    run env RL_LIB_DIR="$STUB_LIB" bash "$CMD" https://github.com/owner/repo/pull/123
    assert_failure 2
    assert_output --partial "--cmd is required"
}

@test "bake-pr exits 2 on unknown flag" {
    run env RL_LIB_DIR="$STUB_LIB" bash "$CMD" --bogus
    assert_failure 2
    assert_output --partial "unknown flag"
}

@test "bake-pr parses --cmd flag (separate or =) before invoking gh" {
    # Replace `gh` with a failing stub so we don't actually hit the
    # network, but get past the arg parsing.
    local bin_stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_stub"
    cat > "$bin_stub/gh" <<'GH'
#!/usr/bin/env bash
echo "STUB GH FAILED" >&2
exit 1
GH
    chmod +x "$bin_stub/gh"

    PATH="$bin_stub:$PATH" run env RL_LIB_DIR="$STUB_LIB" bash "$CMD" --cmd 'echo hi' https://github.com/owner/repo/pull/1
    # gh fails → bake-pr surfaces the failure (exit 1) — but it DID get
    # past arg parsing.
    assert_failure 1
    assert_output --partial "STUB GH FAILED"
    refute_output --partial "--cmd is required"
}
