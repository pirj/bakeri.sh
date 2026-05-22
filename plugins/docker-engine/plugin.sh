#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Snapshot key = pinned identifier for this installation recipe.
# Bump the suffix (or include external inputs) when the recipe changes.
snapshot_key() {
    printf 'docker-engine-recipe-v2' | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'SH'
set -eu
apk add docker docker-cli-compose
# rlock is the unprivileged user prebuild commands run as (see
# bake-prebuild-template's `su -l rlock`). Without docker-group
# membership, `docker compose` fails with permission denied on
# /var/run/docker.sock. addgroup is busybox-compatible.
addgroup rlock docker
rc-update add docker boot
service docker start
# Wait up to 30s for the daemon socket
for i in $(seq 1 30); do
    [ -S /var/run/docker.sock ] && exit 0
    sleep 1
done
echo "docker.sock did not appear" >&2
exit 1
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
