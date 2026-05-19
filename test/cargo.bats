#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/cargo"
    cd "$BATS_TEST_TMPDIR"
}

@test "cargo plugin declares incremental cold snapshot + deps on mise" {
    run grep -q 'strategy *= *"incremental"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["mise"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "cargo plugin triggers on Cargo.lock" {
    run grep -q '"Cargo.lock"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "cargo snapshot_key hashes Cargo.lock + Cargo.toml" {
    cat > Cargo.toml <<'EOF'
[package]
name = "demo"
version = "0.1.0"
EOF
    echo "[[package]]" > Cargo.lock
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "[[package]] changed" > Cargo.lock
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "cargo snapshot_key incorporates rust-toolchain pin" {
    echo "[[package]]" > Cargo.lock
    echo "1.75.0" > rust-toolchain
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "1.80.0" > rust-toolchain
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "cargo snapshot_should_skip prints 'skip' when no Cargo.lock" {
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}

@test "cargo snapshot_should_skip stays silent when Cargo.lock exists" {
    echo "[[package]]" > Cargo.lock
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    refute_output "skip"
}
