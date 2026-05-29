#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Hash every file that influences the warm state.
snapshot_key() {
    {
        local f
        for f in Dockerfile docker-compose.yml docker-compose.yaml \
                 docker-compose.override.yml docker-compose.override.yaml \
                 .dockerignore; do
            if [[ -f "$f" ]]; then
                echo "=== $f ==="
                cat "$f"
            fi
        done
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    # F1 — subdir-as-project. snapc-run exports SNAPC_VM_PROJECT_DIR
    # to the directory inside the VM where THIS snapcompose project's
    # files should live (e.g. /home/rlock/repo/services/main for a
    # monorepo subproject). Falls back to /home/rlock/repo for single-
    # app fixtures.
    #
    # F3 — source is delivered by the framework's auto-push at the
    # first cache-miss boundary, before this snapshot_build runs. The
    # Dockerfile + docker-compose.yml are tracked in git alongside the
    # rest of the source; no per-file scp loop is needed.
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    aq exec "$vm" sh <<SH
set -eu
command -v jq >/dev/null 2>&1 || apk add jq
cd "$vm_project_dir"
docker compose build
docker compose up -d

# Wait up to 5 minutes for all services to be running. Services with a
# declared healthcheck must report Health == "healthy"; services without
# (empty/null Health) are considered ready as soon as State == "running".
for i in \$(seq 1 60); do
    pending=\$(docker compose ps --format json | \\
        jq -s '[.[] | select(.State != "running" or .Health == "starting" or .Health == "unhealthy")] | length')
    [ "\$pending" = "0" ] && exit 0
    sleep 5
done

echo "compose services failed to become healthy within 5 minutes:" >&2
docker compose ps >&2
docker compose logs --tail=50 >&2
exit 1
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
