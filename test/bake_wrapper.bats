#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    BAKE="$PROJECT_ROOT/bin/bake"
}

@test "bake without args prints Usage and exits 2" {
    run env PATH="$PATH" "$BAKE"
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "bake help prints Usage and exits 0" {
    run env PATH="$PATH" "$BAKE" help
    assert_success
    assert_output --partial "Subcommands:"
}

@test "bake errors when rl not on PATH" {
    # Empty PATH so `rl` is unfindable.
    run env PATH="/usr/bin:/bin" "$BAKE" run -- echo hi
    assert_failure 1
    assert_output --partial "'rl' not on PATH"
}

@test "bake forwards subcommand as bake-<sub> to rl" {
    # Stub `rl` that echoes its args and exits 42.
    local bin_stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_stub"
    cat > "$bin_stub/rl" <<'STUB'
#!/usr/bin/env bash
echo "RL ARGS: $*"
exit 42
STUB
    chmod +x "$bin_stub/rl"

    run env PATH="$bin_stub:/usr/bin:/bin" "$BAKE" run -- echo hi
    [ "$status" -eq 42 ]
    [[ "$output" == *"RL ARGS: bake-run -- echo hi"* ]]
}

@test "bake forwards pr subcommand correctly" {
    local bin_stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_stub"
    cat > "$bin_stub/rl" <<'STUB'
#!/usr/bin/env bash
echo "RL ARGS: $*"
STUB
    chmod +x "$bin_stub/rl"

    run env PATH="$bin_stub:/usr/bin:/bin" "$BAKE" pr --cmd 'rake test' https://github.com/o/r/pull/1
    assert_success
    [[ "$output" == *"RL ARGS: bake-pr --cmd rake test https://github.com/o/r/pull/1"* ]]
}
