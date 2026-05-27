#!/usr/bin/env bash
#
# snapc-run — run a one-shot command in the project's snapcompose VM.
#
# Usage: rl snapc-run [--no-push] [--] <command> [args...]
#
# Behaviour:
#   1. If no VM exists for the current project, provision one
#      non-interactively by activating all triggered snapcompose plugins
#      (Dockerfile/compose, mise, ruby-bundler, npm, ...). Cache hits
#      from prior runs make this fast.
#   2. Unless --no-push: push HEAD into the VM via the existing `rl` git
#      remote (set up by the framework's git plugin).
#   3. ssh into the VM as rlock, `cd repo`, run the user command, capture
#      exit code.
#   4. Exit with the user command's exit code.
#
# The VM persists across runs (one VM per project). To rebuild it (e.g.
# after a Dockerfile change blew the cache key), the user runs
# `rl rm && rl snapc-run -- <cmd>`.

set -euo pipefail
_PROFILE_T0=${EPOCHREALTIME//,/.}
_profile_mark() {
  [ -n "${SNAPC_PROFILE:-}" ] || return 0
  awk -v t0="$_PROFILE_T0" -v tn="${EPOCHREALTIME//,/.}" -v lbl="$1" \
      'BEGIN { printf "SNAPC_PROFILE %5.0fms %s\n", (tn-t0)*1000, lbl }' >&2
}
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"
source "${RL_LIB_DIR}/plugin.sh"
source "${RL_LIB_DIR}/toml.sh"
_profile_mark "after sourcing rl libs"

# snapcompose-side library — synthesises plugins from snapcompose.toml.
# Locate it relative to this command script.
SNAPC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$SNAPC_LIB/snapc-prebuild.sh"
_profile_mark "after sourcing snapc-prebuild"

NO_PUSH=0
VM_SUFFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-push)         NO_PUSH=1; shift ;;
        --vm-suffix=*)     VM_SUFFIX="${1#--vm-suffix=}"; shift ;;
        --vm-suffix)       VM_SUFFIX="${2:-}"; shift 2 ;;
        --)                shift; break ;;
        --*)               stderr "Error: unknown flag '$1'"; exit 2 ;;
        *)                 break ;;
    esac
done

if [ $# -eq 0 ]; then
    stderr "Usage: rl snapc-run [--no-push] [--vm-suffix=<tag>] [--] <command> [args...]"
    exit 2
fi

# Resolve VM name. When --vm-suffix is given we bypass resolve_vm_name
# and `.rl/vm-name` entirely — each suffixed call works against its
# own VM independently, identified solely by basename-<suffix>. Useful
# for fan-out within one CI job (e.g. --vm-suffix=lint vs
# --vm-suffix=test) where each VM has its own state and snapshot cache.
if [[ -n "$VM_SUFFIX" ]]; then
    vm_name="$(basename "$(pwd)")-${VM_SUFFIX}"
else
    vm_name=$(resolve_vm_name 2>/dev/null) || vm_name="$(basename "$(pwd)")"
fi
[[ -n "$vm_name" ]] || die "Could not determine VM name for the current project."

# Synthesise prebuild plugins from snapcompose.toml (if present). The
# synth dir lives under .snapcompose/plugins/ in the project root. Even
# if the VM already exists we regenerate — cheap, and it keeps the
# plugin shapes consistent with the current snapcompose.toml so a later
# `rl new` / `rl warm rebuild` sees the right configuration.
SYNTH_DIR="$(pwd)/.snapcompose/plugins"
synthesised=()
memory_override=""
size_override=""
if [[ -f "$(pwd)/snapcompose.toml" ]]; then
    _profile_mark "before synthesise plugins"
    mapfile -t synthesised < <(snapc_prebuild_synthesize \
        "$(pwd)" "$SYNTH_DIR" \
        "$SNAPC_LIB/snapc-prebuild-template.sh")
    _profile_mark "after synthesise plugins"
    # `[memory] size = "4G"` overrides the per-plugin max in `rl new`.
    # Empty when absent — passed as nothing.
    memory_override=$(toml_get_in_section "$(pwd)/snapcompose.toml" "memory" "size")
    # `[disk] size = "4G"` overrides rlock's default `--size=16G`.
    # The default 16G is generous for arbitrary CI workloads; small
    # projects (single postgres container, tiny code base, no large
    # docker images) should drop to 4G–8G to save disk on CI cache
    # restores and warm-path snapshot extraction.
    size_override=$(toml_get_in_section "$(pwd)/snapcompose.toml" "disk" "size")
fi

# Expose the synthesised plugins to rlock for discovery / resolve_deps.
# Prepend to RLOCK_PLUGIN_PATH so they take precedence on name conflicts
# (any `_prebuild-*` name is reserved here by construction; collisions
# only happen if someone names a global user plugin `_prebuild-foo`,
# which we don't guard against — the synthesis wins).
if [[ ${#synthesised[@]} -gt 0 ]]; then
    export RLOCK_PLUGIN_PATH="$SYNTH_DIR:${RLOCK_PLUGIN_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/rl/plugins}"
fi

# Provision if missing. Auto-activate triggered plugins, no prompts.
# Append the synthesised _prebuild-* plugins so they participate in
# the chain at the end (their deps chain among themselves; the first
# has deps=[] so it sorts after all explicit/triggered plugins in
# argument order).
if [[ ! -d "$AQ_STATE_DIR/$vm_name" ]]; then
    info "No VM for this project yet — provisioning..."
    local_available=()
    _profile_mark "before discover_plugins"
    mapfile -t local_available < <(discover_plugins)
    _profile_mark "after discover_plugins"
    local_triggered=()
    mapfile -t local_triggered < <(detect_triggers "$(pwd)" "${local_available[@]}")
    _profile_mark "after detect_triggers"
    activate=("${local_triggered[@]}" "${synthesised[@]}")
    if [[ ${#activate[@]} -eq 0 ]]; then
        die "No snapcompose plugins triggered in $(pwd) and no snapcompose.toml [prebuild.*] sections. Need at least one of: Dockerfile, docker-compose.yml, mise.toml, .tool-versions, .ruby-version, .nvmrc — or declare prebuild steps in snapcompose.toml."
    fi
    # rl new prompts when no args; passing the activation list makes
    # it non-interactive. Prepend --memory + --size + --name flags as
    # the snapcompose.toml / --vm-suffix settings call for.
    rl_new_args=()
    [[ -n "$memory_override" ]] && rl_new_args+=("--memory=$memory_override")
    [[ -n "$size_override"   ]] && rl_new_args+=("--size=$size_override")
    [[ -n "$VM_SUFFIX"       ]] && rl_new_args+=("--name=$vm_name")
    rl_new_args+=("${activate[@]}")
    _profile_mark "before rl new"
    rl new "${rl_new_args[@]}"
    _profile_mark "after rl new"
else
    info "Reusing existing VM '$vm_name'"
fi

# Push current HEAD via the framework's `rl` git remote. The framework's
# git plugin set this up during `rl new`. If we're not in a git repo, or
# the remote isn't there, skip silently — the VM still has the code from
# the last push.
if [[ "$NO_PUSH" -eq 0 ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git remote get-url rl >/dev/null 2>&1; then
        info "Pushing HEAD into the VM..."
        # -f because we may be amending / rebasing between snapc-run calls.
        # Push to a dedicated bake ref so the user's own branch on the guest
        # isn't disturbed.
        _profile_mark "before git push"
        git push -f rl "HEAD:refs/heads/_snapc_run" >/dev/null 2>&1 \
            || warn "git push to VM failed — proceeding with whatever code is in the VM"
        _profile_mark "after git push"
    fi
fi

# Exec the user command. SSH error code propagates.
info "Running in VM: $*"
_profile_mark "before do_ssh"
# do_ssh handles 'aq start' if the VM is stopped. We cd into the guest's
# repo dir; the git plugin clones there. `bash -lc` to load mise + PATH.
set +e
do_ssh "$vm_name" "cd repo 2>/dev/null && git checkout _snapc_run >/dev/null 2>&1 || true; bash -lc 'cd ~/repo && $*'"
rc=$?
set -e

exit "$rc"
