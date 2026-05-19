#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/uv"
    cd "$BATS_TEST_TMPDIR"
}

@test "uv plugin declares incremental cold snapshot + deps on mise" {
    run grep -q 'strategy *= *"incremental"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["mise"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "uv plugin triggers on uv.lock" {
    run grep -q '"uv.lock"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "uv snapshot_key hashes uv.lock + pyproject.toml" {
    cat > pyproject.toml <<'EOF'
[project]
name = "demo"
version = "0.1.0"
EOF
    echo "[[package]]" > uv.lock
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "[[package]] changed" > uv.lock
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]

    # pyproject.toml change also moves the key.
    echo 'name = "other"' >> pyproject.toml
    local k3
    k3=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k2" != "$k3" ]
}

@test "uv snapshot_key incorporates .python-version" {
    echo "[[package]]" > uv.lock
    echo "3.12" > .python-version
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "3.13" > .python-version
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "uv snapshot_should_skip prints 'skip' when no uv.lock" {
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}

@test "uv snapshot_should_skip stays silent when uv.lock exists" {
    echo "[[package]]" > uv.lock
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    refute_output "skip"
}
