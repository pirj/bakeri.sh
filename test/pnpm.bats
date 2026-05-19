#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/pnpm"
    cd "$BATS_TEST_TMPDIR"
}

@test "pnpm plugin declares incremental cold snapshot + deps on mise" {
    run grep -q 'strategy *= *"incremental"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["mise"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "pnpm plugin triggers on pnpm-lock.yaml" {
    run grep -q '"pnpm-lock.yaml"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "pnpm snapshot_key hashes pnpm-lock.yaml" {
    echo 'lockfileVersion: 9.0' > pnpm-lock.yaml
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo 'lockfileVersion: 9.1' > pnpm-lock.yaml
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "pnpm snapshot_key incorporates .nvmrc + .node-version" {
    echo 'lockfileVersion: 9.0' > pnpm-lock.yaml
    echo "20" > .nvmrc
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "22" > .nvmrc
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]

    echo "22.5.0" > .node-version
    local k3
    k3=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k2" != "$k3" ]
}

@test "pnpm snapshot_key is stable when files unchanged" {
    echo 'lockfileVersion: 9.0' > pnpm-lock.yaml
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}

@test "pnpm snapshot_should_skip prints 'skip' when no pnpm-lock.yaml" {
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}

@test "pnpm snapshot_should_skip stays silent when pnpm-lock.yaml exists" {
    echo 'lockfileVersion: 9.0' > pnpm-lock.yaml
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    refute_output "skip"
}
