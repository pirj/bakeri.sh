#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Skip this layer when there's no pnpm-lock.yaml — saves ~5-7 s of
# rebase+boot+stop cycle around a no-op snapshot_build.
snapshot_should_skip() {
    [ -f pnpm-lock.yaml ] || echo "skip"
}

# Snapshot key = SHA256 of pnpm-lock.yaml plus the Node version markers
# that affect what pnpm installs.
snapshot_key() {
    {
        cat pnpm-lock.yaml 2>/dev/null || true
        cat .nvmrc         2>/dev/null || true
        cat .node-version  2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    if [ ! -f pnpm-lock.yaml ]; then
        info "pnpm: no pnpm-lock.yaml in project root, nothing to install"
        return 0
    fi

    aq exec "$vm" sh <<'SH'
set -eu
mkdir -p /home/rlock/repo
chown rlock:rlock /home/rlock/repo
# Native build deps for any modules with node-gyp / sharp / etc.
apk add build-base python3
SH

    local files=(pnpm-lock.yaml package.json)
    [ -f .npmrc        ] && files+=(.npmrc)
    [ -f .pnpmfile.cjs ] && files+=(.pnpmfile.cjs)
    [ -f pnpm-workspace.yaml ] && files+=(pnpm-workspace.yaml)
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

# pnpm via mise (preferred — pinned in tool-versions) or via corepack /
# global npm. corepack is bundled with Node 16+ and provisions pnpm at
# the version declared in package.json's packageManager field.
if ! command -v pnpm >/dev/null 2>&1; then
    if command -v corepack >/dev/null 2>&1; then
        corepack enable pnpm
    elif command -v npm >/dev/null 2>&1; then
        npm install -g pnpm
    else
        echo "ERROR: pnpm not available. Declare Node in mise.toml or .nvmrc." >&2
        exit 1
    fi
fi

# `pnpm install` honours the lockfile and works incrementally — only
# packages absent from the store get fetched, only project nodes_modules
# entries that differ get re-linked. --prefer-offline keeps already-cached
# tarballs out of the network path entirely.
pnpm install --prefer-offline
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
