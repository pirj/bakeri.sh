#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Snapshot key = hash of all tool-version-declaring files in the project root.
# Any of these missing = no contribution to the hash. The `|| true` keeps a
# missing file from tripping the surrounding `set -e`.
snapshot_key() {
    {
        cat mise.toml      2>/dev/null || true
        cat .tool-versions 2>/dev/null || true
        cat .ruby-version  2>/dev/null || true
        cat .nvmrc         2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

# Install mise inside the VM, copy the project's tool-version files into a
# known location, trust them, and resolve every tool. mise builds runtimes
# from source on Alpine for most languages, so this step can be slow on
# first run — that's the whole point of caching it.
snapshot_build() {
    local vm="$1"

    # Push the tool-version files to the guest so `mise install` can read
    # them. Only the ones that exist on the host get copied.
    local files=()
    [ -f mise.toml      ] && files+=(mise.toml)
    [ -f .tool-versions ] && files+=(.tool-versions)
    [ -f .ruby-version  ] && files+=(.ruby-version)
    [ -f .nvmrc         ] && files+=(.nvmrc)

    if [ "${#files[@]}" -eq 0 ]; then
        info "mise: no tool-version files present, nothing to install"
        return 0
    fi

    aq scp "${files[@]}" "$vm:/home/rlock/"

    aq exec "$vm" sh <<'SH'
set -eu
# `mise` is in Alpine community since 3.20. Bundled with build deps that
# many language runtimes need when mise compiles from source.
apk add mise build-base openssl-dev readline-dev yaml-dev zlib-dev libffi-dev

# Activate per-user, trust the project files, install everything.
su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
grep -q "mise activate" ~/.profile 2>/dev/null \
    || echo 'eval "$(mise activate bash)"' >> ~/.profile

eval "$(mise activate bash)"

# Trust any project file that landed in $HOME (one per declared trigger).
for f in mise.toml .tool-versions .ruby-version .nvmrc; do
    [ -f ~/"$f" ] || continue
    mise trust ~/"$f" 2>/dev/null || true
done

# `mise install` (no args) reads all configured files and installs every
# declared tool version. With multiple files it does the right thing.
mise install
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
