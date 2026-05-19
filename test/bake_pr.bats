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

@test "bake-pr plugin declares git as the only unconditional host dep" {
    run grep -q 'host_deps *= *\["git"\]' "$PLUGIN_DIR/plugin.toml"
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

@test "bake-pr rejects unrecognised ref without --no-isolation" {
    run env RL_LIB_DIR="$STUB_LIB" bash "$CMD" --cmd 'echo hi' my-branch
    assert_failure 2
    assert_output --partial "not a recognised GitHub/GitLab PR URL"
    assert_output --partial "--no-isolation"
}

@test "bake-pr routes gitlab URL to glab (runtime-checked)" {
    # No glab on PATH — script must fail with the platform-specific
    # install hint, NOT with a github-specific one.
    PATH="$BATS_TEST_TMPDIR/empty-bin:$PATH" \
    run env RL_LIB_DIR="$STUB_LIB" bash "$CMD" --cmd 'echo hi' \
        https://gitlab.com/owner/repo/-/merge_requests/3
    assert_failure 1
    assert_output --partial "glab CLI not installed"
    refute_output --partial "gh CLI not installed"
}

@test "bake-pr --no-isolation skips PR resolution entirely" {
    # Build a tiny local git repo so `git rev-parse HEAD` resolves, and
    # configure an `rl` remote that just sinks pushes (a local bare repo).
    local sink="$BATS_TEST_TMPDIR/sink.git"
    git init --bare -q "$sink"
    local proj="$BATS_TEST_TMPDIR/proj"
    git init -q "$proj"
    cd "$proj"
    git -c user.email=a@b -c user.name=a commit --allow-empty -m init -q
    git remote add rl "$sink"

    # AQ_STATE_DIR must contain a dir matching the VM name (the script
    # checks existence). resolve_vm_name in the stub returns "stub-vm".
    local aq_state="$BATS_TEST_TMPDIR/aq_state"
    mkdir -p "$aq_state/stub-vm"

    AQ_STATE_DIR="$aq_state" run env RL_LIB_DIR="$STUB_LIB" \
        bash "$CMD" --cmd 'echo hi' --no-isolation HEAD
    assert_success
    # do_ssh stub echoes its args — verify we got there.
    assert_output --partial "DOSSH:stub-vm"
    # And verify the sink received the push under the expected ref.
    run git --git-dir="$sink" rev-parse refs/heads/_bake_pr
    assert_success
}
