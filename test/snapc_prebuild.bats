#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    source "$LIB_DIR/toml.sh"
    source "$PROJECT_ROOT/lib/snapc-prebuild.sh"

    PROJECT="$BATS_TEST_TMPDIR/proj"
    SYNTH="$BATS_TEST_TMPDIR/synth"
    TEMPLATE="$PROJECT_ROOT/lib/snapc-prebuild-template.sh"
    mkdir -p "$PROJECT"
}

@test "snapc_prebuild_synthesize is a no-op when snapcompose.toml is missing" {
    run snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE"
    assert_success
    assert_output ""
    [ ! -d "$SYNTH" ]
}

@test "snapc_prebuild_synthesize is a no-op when snapcompose.toml has no [prebuild.*]" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[memory]
size = "4G"
EOF
    run snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE"
    assert_success
    assert_output ""
}

@test "snapc_prebuild_synthesize generates one plugin per [prebuild.<name>]" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.schema-load]
cmd = "rails db:schema:load"
key_files = ["db/schema.rb"]

[prebuild.migrate]
cmd = "rails db:migrate"
key_files = ["db/schema.rb", "db/migrate"]
strategy = "cached"

[prebuild.seed]
cmd = "rails db:seed"
key_files = ["db/seeds.rb"]
EOF
    run snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE"
    assert_success
    assert_line --index 0 "_prebuild-schema-load"
    assert_line --index 1 "_prebuild-migrate"
    assert_line --index 2 "_prebuild-seed"

    [ -d "$SYNTH/_prebuild-schema-load" ]
    [ -d "$SYNTH/_prebuild-migrate" ]
    [ -d "$SYNTH/_prebuild-seed" ]
}

@test "synthesised plugin.toml chains deps to preserve source order" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.first]
cmd = "echo a"
key_files = ["a.txt"]

[prebuild.second]
cmd = "echo b"
key_files = ["b.txt"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    grep -q '^deps = \[\]$' "$SYNTH/_prebuild-first/plugin.toml"
    grep -q '^deps = \["_prebuild-first"\]$' "$SYNTH/_prebuild-second/plugin.toml"
}

@test "synthesised plugin.toml honours declared strategy (default cached)" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.a]
cmd = "x"
key_files = ["x"]

[prebuild.b]
cmd = "y"
key_files = ["y"]
strategy = "incremental"
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    grep -q '^strategy = "cached"$' "$SYNTH/_prebuild-a/plugin.toml"
    grep -q '^strategy = "incremental"$' "$SYNTH/_prebuild-b/plugin.toml"
}

@test "synthesised cmd.sh contains the verbatim cmd from the section" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "docker compose exec app rails db:migrate"
key_files = ["db/schema.rb"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    grep -q 'docker compose exec app rails db:migrate' "$SYNTH/_prebuild-demo/cmd.sh"
    # set -eu is prepended so user typos fail the layer
    grep -q '^set -eu$' "$SYNTH/_prebuild-demo/cmd.sh"
}

@test "synthesised key_files.txt has one declared glob per line" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["db/schema.rb", "db/migrate/*.rb", "config/database.yml"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    run cat "$SYNTH/_prebuild-demo/key_files.txt"
    assert_success
    assert_line --index 0 "db/schema.rb"
    assert_line --index 1 "db/migrate/*.rb"
    assert_line --index 2 "config/database.yml"
}

@test "synthesised plugin.sh is a copy of the template" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["a"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    diff "$TEMPLATE" "$SYNTH/_prebuild-demo/plugin.sh"
}

@test "snapc_prebuild_synthesize fails on missing required cmd" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
key_files = ["a"]
EOF
    run snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE"
    assert_failure
    assert_output --partial "missing required 'cmd'"
}

@test "snapc_prebuild_synthesize fails on missing required key_files" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
EOF
    run snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE"
    assert_failure
    assert_output --partial "missing required 'key_files'"
}

@test "snapc_prebuild_synthesize rejects a snapcompose.toml with duplicate sections" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.migrate]
cmd = "x"
key_files = ["x"]

[prebuild.migrate]
cmd = "y"
key_files = ["y"]
EOF
    run snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE"
    assert_failure
    assert_output --partial "duplicate table headers"
}

@test "regenerating overwrites stale plugin contents" {
    # First synthesis with cmd=A.
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo A"
key_files = ["a"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null
    grep -q 'echo A' "$SYNTH/_prebuild-demo/cmd.sh"

    # Update the toml; second synthesis must replace cmd.sh content,
    # not leave the old "echo A" line behind.
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo B"
key_files = ["a"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null
    grep -q 'echo B' "$SYNTH/_prebuild-demo/cmd.sh"
    ! grep -q 'echo A' "$SYNTH/_prebuild-demo/cmd.sh"
}

@test "synthesised plugin's snapshot_key is stable when inputs unchanged" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["a.txt", "b.txt"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    cd "$PROJECT"
    echo "A" > a.txt
    echo "B" > b.txt
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)
    [ -n "$k1" ]
    [ "$k1" = "$k2" ]
}

@test "synthesised plugin's snapshot_key changes when a key_file's content changes" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["schema.rb"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    cd "$PROJECT"
    echo "version 1" > schema.rb
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)
    echo "version 2" > schema.rb
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "synthesised plugin's snapshot_key changes when the cmd changes" {
    cd "$PROJECT"
    echo "X" > x.txt

    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo first"
key_files = ["x.txt"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)

    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo second"
key_files = ["x.txt"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)

    [ "$k1" != "$k2" ]
}

@test "synthesised plugin's snapshot_should_skip prints 'skip' when no key_files match" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["missing-glob-*.rb"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    cd "$PROJECT"
    run env RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}

@test "synthesised plugin's snapshot_should_skip stays silent when a key_file matches" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["present.txt"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    cd "$PROJECT"
    echo "hi" > present.txt
    run env RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_should_skip
    assert_success
    refute_output "skip"
}

@test "synthesised plugin's snapshot_key uses glob-expansion at PROJECT cwd" {
    cat > "$PROJECT/snapcompose.toml" <<'EOF'
[prebuild.demo]
cmd = "echo demo"
key_files = ["db/migrate/*.rb"]
EOF
    snapc_prebuild_synthesize "$PROJECT" "$SYNTH" "$TEMPLATE" >/dev/null

    cd "$PROJECT"
    mkdir -p db/migrate
    echo "1" > db/migrate/001_init.rb
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)

    # Adding a new file to the glob changes the hash.
    echo "2" > db/migrate/002_add.rb
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$SYNTH/_prebuild-demo/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}
