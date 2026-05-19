#!/usr/bin/env bats
#
# Lock in the contract that bakeri.sh consumes rlock's TOML parser
# directly (no copy, no fork) for distribution-specific config like
# `bakeri.toml`. Catches drift if rlock ever accidentally couples
# `lib/toml.sh` to its plugin-protocol internals.

setup() {
    load 'test_helper/common'
    _common_setup
    # Source rlock's TOML helpers via the same LIB_DIR that the test
    # helper resolves for every other bakeri.sh test.
    source "$LIB_DIR/toml.sh"
}

@test "rlock's toml.sh is sourceable from bakeri.sh without rlock-specific env" {
    # The functions exist after sourcing — no other rlock state needed.
    declare -F toml_get             > /dev/null
    declare -F toml_get_array       > /dev/null
    declare -F toml_get_in_section  > /dev/null
    declare -F toml_validate        > /dev/null
}

@test "rlock's toml.sh parses a bakeri.toml-shaped file" {
    cat > "$BATS_TEST_TMPDIR/bakeri.toml" <<'EOF'
[memory]
size = "4G"

[prebuild.schema-load]
cmd = "docker compose exec app rails db:schema:load"
strategy = "cached"
key_files = ["db/schema.rb"]

[prebuild.migrate]
cmd = "docker compose exec app rails db:migrate"
strategy = "ephemeral"
EOF

    run toml_validate "$BATS_TEST_TMPDIR/bakeri.toml"
    assert_success

    run toml_get_in_section "$BATS_TEST_TMPDIR/bakeri.toml" "memory" "size"
    assert_success
    assert_output "4G"

    run toml_get_in_section "$BATS_TEST_TMPDIR/bakeri.toml" "prebuild.schema-load" "cmd"
    assert_success
    assert_output "docker compose exec app rails db:schema:load"

    run toml_get_in_section "$BATS_TEST_TMPDIR/bakeri.toml" "prebuild.migrate" "strategy"
    assert_success
    assert_output "ephemeral"
}

@test "toml_validate from bakeri.sh side rejects a duplicated bakeri.toml section" {
    cat > "$BATS_TEST_TMPDIR/bakeri.toml" <<'EOF'
[prebuild.migrate]
cmd = "rails db:migrate"

[prebuild.migrate]
cmd = "rails db:rollback"
EOF
    run toml_validate "$BATS_TEST_TMPDIR/bakeri.toml"
    assert_failure
    assert_output --partial "[prebuild.migrate]"
}
