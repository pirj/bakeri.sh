#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/npm"
    cd "$BATS_TEST_TMPDIR"
}

@test "npm plugin declares incremental cold snapshot + deps on mise" {
    run grep -q 'strategy *= *"incremental"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["mise"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "npm plugin triggers on package-lock.json" {
    run grep -q '"package-lock.json"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "npm snapshot_key hashes package-lock.json" {
    echo '{"name":"x","lockfileVersion":3}' > package-lock.json
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo '{"name":"y","lockfileVersion":3}' > package-lock.json
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "npm snapshot_key incorporates .nvmrc + .node-version" {
    echo '{}' > package-lock.json
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

@test "npm snapshot_key is stable when files unchanged" {
    echo '{}' > package-lock.json
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}
