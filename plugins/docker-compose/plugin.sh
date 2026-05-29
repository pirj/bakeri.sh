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

    # Find the canonical compose file.
    local compose_file=""
    for cand in docker-compose.yml docker-compose.yaml; do
        [[ -f "$cand" ]] && { compose_file="$cand"; break; }
    done

    # F1 — subdir-as-project. snapc-run exports SNAPC_VM_PROJECT_DIR
    # to the directory inside the VM where THIS snapcompose project's
    # files should live (e.g. /home/rlock/repo/services/main when the
    # snapcompose project is a subdir of a monorepo). Falls back to
    # the legacy /home/rlock/repo for single-app fixtures.
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    # Prepare the target dir inside the VM.
    aq exec "$vm" sh <<SH
mkdir -p "$vm_project_dir"
chown -R rlock:rlock /home/rlock/repo
SH

    # Copy Dockerfile + compose files into the VM ahead of git push.
    # Targets land at \$vm_project_dir so a subsequent `cd` finds them
    # alongside any source the git plugin's push delivered.
    for f in Dockerfile "$compose_file" docker-compose.override.yml \
             docker-compose.override.yaml .dockerignore; do
        [[ -n "$f" && -f "$f" ]] && aq scp "$f" "$vm:$vm_project_dir/$f"
    done

    # Build + up + wait for healthy.
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
