#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-engine"
}

@test "docker-engine plugin declares cached snapshot" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-engine plugin protocol_version is 1" {
    run grep -q 'protocol_version *= *"1"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-engine snapshot_key is stable for same input" {
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]
    [ "$k1" = "$k2" ]
}
