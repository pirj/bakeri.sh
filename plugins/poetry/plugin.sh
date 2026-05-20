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
# mise must be on PATH — this plugin declares `deps = ["mise"]`. Fail
# loudly rather than silently using a system Python (wrong version).
eval "$(mise activate bash)"
cd ~/repo

# Project must declare `poetry` (or `python` + a way to install poetry)
# in mise.toml / .tool-versions. Falling back to apk's py3-poetry would
# bind to the system Python — wrong version, hard-to-debug.
command -v poetry >/dev/null 2>&1

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
