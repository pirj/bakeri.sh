#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-compose"
    cd "$BATS_TEST_TMPDIR"
}

@test "docker-compose plugin declares cached live snapshot with 4G memory + deps on docker-registry-cache" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    # docker-registry-cache transitively depends on docker-engine, so this
    # both pulls the engine in AND ensures the host-side mirror is set up
    # before `docker compose pull` runs.
    run grep -q 'deps *= *\["docker-registry-cache"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"live"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'memory *= *"4G"' "$PLUGIN_DIR/plugin.toml"
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
