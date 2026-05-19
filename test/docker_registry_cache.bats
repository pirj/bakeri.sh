#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-registry-cache"
    cd "$BATS_TEST_TMPDIR"
}

@test "plugin declares cached cold snapshot + deps on docker-engine" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["docker-engine"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "plugin declares host_deps = [\"registry\"]" {
    run grep -q 'host_deps *= *\["registry"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "plugin has no triggers (opt-in only — listed explicitly on rl new)" {
    run grep -q '^triggers *= *\[\]$' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "snapshot_should_skip prints 'skip' when no Dockerfile / compose file" {
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}

@test "snapshot_should_skip stays silent when Dockerfile present" {
    echo "FROM alpine" > Dockerfile
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    refute_output "skip"
}

@test "snapshot_should_skip stays silent for docker-compose.yml / .yaml" {
    for f in docker-compose.yml docker-compose.yaml; do
        rm -f Dockerfile docker-compose.yml docker-compose.yaml
        echo "services: {}" > "$f"
        run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
        assert_success
        refute_output "skip"
    done
}

@test "snapshot_key is constant — same hash on every call" {
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]
    [ "$k1" = "$k2" ]
}

@test "snapshot_key is independent of project content (one shared cache)" {
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "FROM alpine" > Dockerfile
    echo "x" > docker-compose.yml
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    [ "$k1" = "$k2" ]
}

@test "docker-registry-cache plugin transitively depends on docker-engine" {
    # docker-compose intentionally does NOT depend on docker-registry-cache —
    # the mirror is an opt-in optimisation, not a correctness requirement.
    # docker-registry-cache itself still depends on docker-engine because
    # configuring /etc/docker/daemon.json requires dockerd to exist first.
    run grep -q 'deps *= *\["docker-engine"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}
