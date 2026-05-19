#!/usr/bin/env bash
#
# docker-registry-cache — host-side Docker registry pull-through cache.
#
# Why: bakeri.sh's docker-compose cold pull dominates cold path (~60 s
# on a typical Rails+PG fixture). The pull happens INSIDE the guest VM,
# so the host's docker daemon has no shared image cache and every fresh
# project on the host pays the same network cost again.
#
# What: run the canonical CNCF distribution registry binary on the host
# in proxy mode. Guests' Docker daemons are configured to use it as a
# `registry-mirrors` target via /etc/docker/daemon.json. First project
# populates the cache; every subsequent project on the same host gets
# cache hits at LAN speed.
#
# Lifecycle:
#   * start hook (every `rl new` / SSH session): launch the registry
#     binary on the host if it isn't already running. Idempotent.
#   * snapshot_build (per-VM, once per cached state): write daemon.json
#     in the guest pointing at 10.0.2.2:5000, restart dockerd.
#   * rm hook: leave the host registry running — it's shared across
#     bakeri.sh projects on this host.
#
# Mirror runs on http://127.0.0.1:5000 on the host. Inside the VM,
# 10.0.2.2 is the host (QEMU user-mode NAT gateway).

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

REGISTRY_HOST_PORT=5000
REGISTRY_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/rl/registry"
REGISTRY_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rl/registry.yml"
REGISTRY_PID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rl/registry.pid"
REGISTRY_LOG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rl/registry.log"
REGISTRY_UPSTREAM="https://registry-1.docker.io"
GUEST_MIRROR_URL="http://10.0.2.2:${REGISTRY_HOST_PORT}"
RECIPE_VERSION="v1"

# No work to do when the project has no docker artefacts — no Dockerfile,
# no compose file means dockerd will never pull anything.
snapshot_should_skip() {
    if [ ! -f Dockerfile ] && [ ! -f docker-compose.yml ] && [ ! -f docker-compose.yaml ]; then
        echo "skip"
    fi
}

# Fixed-content recipe: the registry config + guest daemon.json don't
# depend on project state. One cached layer is shared across every
# bakeri.sh project on the host.
snapshot_key() {
    printf 'docker-registry-cache-recipe-%s-%s' "$RECIPE_VERSION" "$REGISTRY_UPSTREAM" \
        | sha256sum | cut -d' ' -f1
}

# Configure the guest's docker daemon to use the host as a registry
# mirror. docker-engine has already started dockerd in its
# snapshot_build; we change /etc/docker/daemon.json and restart so the
# new config takes effect. The restart is captured in the snapshot, so
# warm restores already see the mirror configured at boot.
snapshot_build() {
    local vm="$1"
    aq exec "$vm" <<SH
set -eu
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<DAEMON
{
    "registry-mirrors": ["${GUEST_MIRROR_URL}"]
}
DAEMON
service docker restart
# Wait for the socket back so dependent layers don't race dockerd.
for i in \$(seq 1 30); do
    [ -S /var/run/docker.sock ] && exit 0
    sleep 1
done
echo "ERROR: /var/run/docker.sock did not reappear within 30 s after dockerd restart" >&2
exit 1
SH
}

# --- host registry lifecycle ------------------------------------------

_registry_alive() {
    [ -f "$REGISTRY_PID_FILE" ] \
        && kill -0 "$(cat "$REGISTRY_PID_FILE" 2>/dev/null)" 2>/dev/null
}

_write_registry_config() {
    mkdir -p "$(dirname "$REGISTRY_CONFIG_FILE")" "$REGISTRY_DATA_DIR"
    cat > "$REGISTRY_CONFIG_FILE" <<YAML
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: $REGISTRY_DATA_DIR
http:
  addr: 127.0.0.1:$REGISTRY_HOST_PORT
proxy:
  remoteurl: $REGISTRY_UPSTREAM
YAML
}

_launch_registry() {
    _write_registry_config
    nohup registry serve "$REGISTRY_CONFIG_FILE" >> "$REGISTRY_LOG_FILE" 2>&1 &
    echo $! > "$REGISTRY_PID_FILE"
    disown $! 2>/dev/null || true

    # Probe /v2/ — registry's standard liveness endpoint. Returns 200
    # (or 401 in some modes); any HTTP response means the port is bound.
    local code i
    for i in $(seq 1 10); do
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 1 "http://127.0.0.1:$REGISTRY_HOST_PORT/v2/" 2>/dev/null) || code=000
        case "$code" in
            2*|4*) return 0 ;;
        esac
        sleep 0.5
    done
    return 1
}

# `start` hook runs at every `rl new` (and other lifecycle events that
# resolve the VM). Make sure the host registry is up; cheap when it
# already is.
start() {
    if _registry_alive; then
        return 0
    fi
    if ! _launch_registry; then
        warn "Docker registry mirror did not respond on :$REGISTRY_HOST_PORT — see $REGISTRY_LOG_FILE"
        warn "Guest pulls will fall through to docker.io directly (slow but correct)."
        return 0
    fi
    success "Docker registry mirror running on :$REGISTRY_HOST_PORT (proxy → $REGISTRY_UPSTREAM)"
}

# Leave the host registry running on `rl rm` — it's shared across every
# bakeri.sh project on the host. User stops manually if needed.
rm() {
    # shellcheck disable=SC2034
    local vm="$1"
    info "Docker registry mirror left running. Stop manually: kill \$(cat $REGISTRY_PID_FILE)"
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
