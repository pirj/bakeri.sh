#!/usr/bin/env bash
#
# bake-run — run a one-shot command in the project's bakeri.sh VM.
#
# Usage: rl bake-run [--no-push] [--] <command> [args...]
#
# Behaviour:
#   1. If no VM exists for the current project, provision one
#      non-interactively by activating all triggered bakeri.sh plugins
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
# `rl rm && rl bake-run -- <cmd>`.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"
source "${RL_LIB_DIR}/plugin.sh"
source "${RL_LIB_DIR}/toml.sh"

# bakeri.sh-side library — synthesises plugins from bakerish.toml.
# Locate it relative to this command script.
BAKERI_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$BAKERI_LIB/bake-prebuild.sh"

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
    stderr "Usage: rl bake-run [--no-push] [--vm-suffix=<tag>] [--] <command> [args...]"
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

# Synthesise prebuild plugins from bakerish.toml (if present). The
# synth dir lives under .bakerish/plugins/ in the project root. Even
# if the VM already exists we regenerate — cheap, and it keeps the
# plugin shapes consistent with the current bakerish.toml so a later
# `rl new` / `rl warm rebuild` sees the right configuration.
SYNTH_DIR="$(pwd)/.bakerish/plugins"
synthesised=()
memory_override=""
if [[ -f "$(pwd)/bakerish.toml" ]]; then
    mapfile -t synthesised < <(bake_prebuild_synthesize \
        "$(pwd)" "$SYNTH_DIR" \
        "$BAKERI_LIB/bake-prebuild-template.sh")
    # `[memory] size = "4G"` overrides the per-plugin max in `rl new`.
    # Empty when absent — passed as nothing.
    memory_override=$(toml_get_in_section "$(pwd)/bakerish.toml" "memory" "size")
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
    mapfile -t local_available < <(discover_plugins)
    local_triggered=()
    mapfile -t local_triggered < <(detect_triggers "$(pwd)" "${local_available[@]}")
    activate=("${local_triggered[@]}" "${synthesised[@]}")
    if [[ ${#activate[@]} -eq 0 ]]; then
        die "No bakeri.sh plugins triggered in $(pwd) and no bakerish.toml [prebuild.*] sections. Need at least one of: Dockerfile, docker-compose.yml, mise.toml, .tool-versions, .ruby-version, .nvmrc — or declare prebuild steps in bakerish.toml."
    fi
    # rl new prompts when no args; passing the activation list makes
    # it non-interactive. Prepend --memory + --name flags as the
    # bakerish.toml / --vm-suffix settings call for.
    rl_new_args=()
    [[ -n "$memory_override" ]] && rl_new_args+=("--memory=$memory_override")
    [[ -n "$VM_SUFFIX"       ]] && rl_new_args+=("--name=$vm_name")
    rl_new_args+=("${activate[@]}")
    rl new "${rl_new_args[@]}"
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
        # -f because we may be amending / rebasing between bake-run calls.
        # Push to a dedicated bake ref so the user's own branch on the guest
        # isn't disturbed.
        git push -f rl "HEAD:refs/heads/_bake_run" >/dev/null 2>&1 \
            || warn "git push to VM failed — proceeding with whatever code is in the VM"
    fi
fi

# Exec the user command. SSH error code propagates.
info "Running in VM: $*"
# do_ssh handles 'aq start' if the VM is stopped. We cd into the guest's
# repo dir; the git plugin clones there. `bash -lc` to load mise + PATH.
set +e
do_ssh "$vm_name" "cd repo 2>/dev/null && git checkout _bake_run >/dev/null 2>&1 || true; bash -lc 'cd ~/repo && $*'"
rc=$?
set -e

exit "$rc"
