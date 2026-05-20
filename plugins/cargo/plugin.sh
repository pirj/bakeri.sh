#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    [ -f Cargo.lock ] || echo "skip"
}

# Snapshot key = SHA256 of Cargo.lock plus Cargo.toml (workspace deps
# can sit in the manifest), plus the rust-toolchain pin if present.
snapshot_key() {
    {
        cat Cargo.lock          2>/dev/null || true
        cat Cargo.toml          2>/dev/null || true
        cat rust-toolchain      2>/dev/null || true
        cat rust-toolchain.toml 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    if [ ! -f Cargo.lock ]; then
        info "cargo: no Cargo.lock in project root, nothing to fetch"
        return 0
    fi

    aq exec "$vm" sh <<'SH'
set -eu
mkdir -p /home/rlock/repo
chown rlock:rlock /home/rlock/repo
SH

    local files=(Cargo.lock Cargo.toml)
    [ -f rust-toolchain      ] && files+=(rust-toolchain)
    [ -f rust-toolchain.toml ] && files+=(rust-toolchain.toml)
    local f
    for f in "${files[@]}"; do
        [ -f "$f" ] && aq scp "$f" "$vm:/home/rlock/repo/$f"
    done

    aq exec "$vm" sh <<'SH'
set -eu
chown -R rlock:rlock /home/rlock/repo
su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
# mise must be on PATH — this plugin declares `deps = ["mise"]`. Fail
# loudly rather than silently using system Rust (wrong toolchain).
eval "$(mise activate bash)"
cd ~/repo

# Project must declare `rust` in mise.toml / rust-toolchain.toml.
# Falling back to apk's `rust cargo` would bind to whatever Alpine
# ships — wrong toolchain, hard-to-debug.
command -v cargo >/dev/null 2>&1

# `cargo fetch` downloads all dependencies declared in Cargo.lock into
# ~/.cargo/registry. It does NOT compile — that's deliberate: compile
# artifacts depend on profile (debug/release) and features and are
# expensive to share. Compile happens at `bake run` time on top of this.
cargo fetch --locked
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
