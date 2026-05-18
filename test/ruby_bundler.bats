#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/ruby-bundler"
    cd "$BATS_TEST_TMPDIR"
}

@test "ruby-bundler plugin declares incremental cold snapshot + deps on mise" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"incremental"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"cold"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["mise"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "ruby-bundler plugin triggers on Gemfile.lock" {
    run grep -q '"Gemfile.lock"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "ruby-bundler snapshot_key hashes Gemfile.lock" {
    cat > Gemfile.lock <<'L'
GEM
  remote: https://rubygems.org/
  specs:
    rails (7.0.4)
L
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    cat > Gemfile.lock <<'L'
GEM
  remote: https://rubygems.org/
  specs:
    rails (7.0.5)
L
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "ruby-bundler snapshot_key incorporates .ruby-version" {
    echo "GEM" > Gemfile.lock
    echo "3.3.0" > .ruby-version
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "3.3.5" > .ruby-version
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "ruby-bundler snapshot_key incorporates .bundler-version" {
    echo "GEM" > Gemfile.lock
    echo "2.5.0" > .bundler-version
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    echo "2.6.0" > .bundler-version
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "ruby-bundler snapshot_key is stable when files unchanged" {
    echo "GEM" > Gemfile.lock
    echo "3.3.0" > .ruby-version
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}
