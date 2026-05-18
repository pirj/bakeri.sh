#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-compose"
    cd "$BATS_TEST_TMPDIR"
}

@test "docker-compose plugin declares cached snapshot + deps on docker-engine" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["docker-engine"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-compose snapshot_key hashes Dockerfile + compose + .dockerignore" {
    cat > Dockerfile <<EOF
FROM alpine
EOF
    cat > docker-compose.yml <<EOF
services:
  db: {image: postgres:16}
EOF
    cat > .dockerignore <<EOF
*.log
EOF
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    echo "FROM debian" > Dockerfile
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "docker-compose snapshot_key is stable when files unchanged" {
    echo "FROM alpine" > Dockerfile
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}
