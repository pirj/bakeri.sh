#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/poetry"
    cd "$BATS_TEST_TMPDIR"
}

@test "poetry plugin declares incremental cold snapshot + deps on mise" {
    run grep -q 'strategy *= *"incremental"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["mise"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "poetry plugin triggers on poetry.lock" {
    run grep -q '"poetry.lock"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "poetry snapshot_key hashes poetry.lock + pyproject.toml" {
    cat > pyproject.toml <<'EOF'
[tool.poetry]
name = "demo"
EOF
    echo "[[package]]" > poetry.lock
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "[[package]] changed" > poetry.lock
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "poetry snapshot_key incorporates .python-version" {
    echo "[[package]]" > poetry.lock
    echo "3.12" > .python-version
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "3.13" > .python-version
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "poetry snapshot_should_skip prints 'skip' when no poetry.lock" {
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}

@test "poetry snapshot_should_skip stays silent when poetry.lock exists" {
    echo "[[package]]" > poetry.lock
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    refute_output "skip"
}
