#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    [ -f uv.lock ] || echo "skip"
}

# Snapshot key = SHA256 of uv.lock plus pyproject.toml (uv reads both to
# resolve), plus the Python version markers that affect what uv installs.
snapshot_key() {
    {
        cat uv.lock         2>/dev/null || true
        cat pyproject.toml  2>/dev/null || true
        cat .python-version 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    if [ ! -f uv.lock ]; then
        info "uv: no uv.lock in project root, nothing to install"
        return 0
    fi

    aq exec "$vm" sh <<'SH'
set -eu
mkdir -p /home/rlock/repo
chown rlock:rlock /home/rlock/repo
SH

    local files=(uv.lock pyproject.toml)
    [ -f .python-version  ] && files+=(.python-version)
    [ -f .python-versions ] && files+=(.python-versions)
    [ -f uv.toml          ] && files+=(uv.toml)
    local f
    for f in "${files[@]}"; do
        [ -f "$f" ] && aq scp "$f" "$vm:/home/rlock/repo/$f"
    done

    aq exec "$vm" sh <<'SH'
set -eu
chown -R rlock:rlock /home/rlock/repo
su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
eval "$(mise activate bash 2>/dev/null)" || true
cd ~/repo

# uv is in Alpine community (3.21+). mise can install it too; prefer
# mise if the project declares it, otherwise fall back to the system
# package. The plugin must NOT use the upstream curl-pipe installer —
# offline-friendly is a stated bakeri.sh value.
if ! command -v uv >/dev/null 2>&1; then
    sudo apk add uv 2>/dev/null || {
        echo "ERROR: uv not available. Declare uv in mise.toml or update Alpine." >&2
        exit 1
    }
fi

# `uv sync` reads pyproject.toml + uv.lock and resolves the project's
# .venv. Incremental by nature: skips packages already linked into .venv
# and skips downloads already in the global cache.
uv sync --frozen
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
