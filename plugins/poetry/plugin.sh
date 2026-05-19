#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    [ -f poetry.lock ] || echo "skip"
}

# Snapshot key = SHA256 of poetry.lock plus pyproject.toml (poetry reads
# both to install), plus Python version markers.
snapshot_key() {
    {
        cat poetry.lock     2>/dev/null || true
        cat pyproject.toml  2>/dev/null || true
        cat .python-version 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    if [ ! -f poetry.lock ]; then
        info "poetry: no poetry.lock in project root, nothing to install"
        return 0
    fi

    aq exec "$vm" sh <<'SH'
set -eu
mkdir -p /home/rlock/repo
chown rlock:rlock /home/rlock/repo
SH

    local files=(poetry.lock pyproject.toml)
    [ -f .python-version  ] && files+=(.python-version)
    [ -f poetry.toml      ] && files+=(poetry.toml)
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

# poetry is in Alpine community (py3-poetry). mise can install it too;
# prefer mise if the project declares it, otherwise fall back.
if ! command -v poetry >/dev/null 2>&1; then
    sudo apk add py3-poetry 2>/dev/null || {
        echo "ERROR: poetry not available. Declare poetry in mise.toml or update Alpine." >&2
        exit 1
    }
fi

# Keep .venv inside the project so the cache layer captures it.
poetry config virtualenvs.in-project true

# `poetry install --no-interaction` reads pyproject.toml + poetry.lock
# and installs into .venv. Incremental: pre-existing .venv from earlier
# layer skips already-installed deps.
poetry install --no-interaction --no-ansi
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
