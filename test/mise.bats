#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/mise"
    cd "$BATS_TEST_TMPDIR"
}

@test "mise plugin declares cached cold snapshot" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "mise plugin protocol_version is 1" {
    run grep -q 'protocol_version *= *"1"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "mise plugin triggers on the expected tool-version files" {
    for trig in mise.toml .tool-versions .ruby-version .nvmrc; do
        run grep -q "\"$trig\"" "$PLUGIN_DIR/plugin.toml"
        assert_success
    done
}

@test "mise snapshot_key hashes mise.toml when present" {
    cat > mise.toml <<EOF
[tools]
ruby = "3.3.0"
EOF
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    cat > mise.toml <<EOF
[tools]
ruby = "3.3.5"
EOF
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "mise snapshot_key incorporates .ruby-version" {
    echo "3.3.0" > .ruby-version
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    echo "3.3.5" > .ruby-version
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "mise snapshot_key incorporates .tool-versions and .nvmrc" {
    echo "ruby 3.3.0" > .tool-versions
    echo "20"        > .nvmrc
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "ruby 3.3.0
nodejs 22" > .tool-versions
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]

    echo "22" > .nvmrc
    local k3
    k3=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k2" != "$k3" ]
}

@test "mise snapshot_key is stable when files unchanged" {
    echo "ruby 3.3.0" > .tool-versions
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}
