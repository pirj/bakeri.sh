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

NO_PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-push) NO_PUSH=1; shift ;;
        --)        shift; break ;;
        --*)       stderr "Error: unknown flag '$1'"; exit 2 ;;
        *)         break ;;
    esac
done

if [ $# -eq 0 ]; then
    stderr "Usage: rl bake-run [--no-push] [--] <command> [args...]"
    exit 2
fi

# Resolve VM name (plugin resolve_vm hooks first, then CWD basename).
vm_name=$(resolve_vm_name 2>/dev/null) || vm_name="$(basename "$(pwd)")"
[[ -n "$vm_name" ]] || die "Could not determine VM name for the current project."

# Provision if missing. Auto-activate triggered plugins, no prompts.
if [[ ! -d "$AQ_STATE_DIR/$vm_name" ]]; then
    info "No VM for this project yet — provisioning..."
    local_available=()
    mapfile -t local_available < <(discover_plugins)
    local_triggered=()
    mapfile -t local_triggered < <(detect_triggers "$(pwd)" "${local_available[@]}")
    if [[ ${#local_triggered[@]} -eq 0 ]]; then
        die "No bakeri.sh plugins triggered in $(pwd). Need at least one of: Dockerfile, docker-compose.yml, mise.toml, .tool-versions, .ruby-version, .nvmrc."
    fi
    # rl new prompts when no args; passing the triggered list makes it
    # non-interactive.
    rl new "${local_triggered[@]}"
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
