#!/usr/bin/env bash
#
# bake-pr — run a GitHub PR's branch in the project's bakeri.sh VM,
# without giving the VM network access to the untrusted fork.
#
# Usage: rl bake-pr --cmd '<command>' <pr-ref>
#
# <pr-ref> forms supported in MVP:
#   * https://github.com/<owner>/<repo>/pull/<N>
#   * <owner>/<repo>#<N>          (gh shorthand)
#
# Workflow:
#   1. Use `gh pr view --json` HOST-SIDE to resolve PR -> head fork +
#      branch + SHA. The fork URL is never given to the VM.
#   2. Add the fork as a local git remote (`_bake_pr_remote`), fetch the
#      PR head into a detached local ref. The host has authenticated git
#      already; the VM doesn't need to.
#   3. Push that ref into the VM via the existing `rl` remote as
#      `_bake_pr` branch.
#   4. ssh in, checkout `_bake_pr` in /repo, run the user's --cmd,
#      capture exit code.
#   5. Always clean up the temp remote on the host.
#   6. Exit with the command's exit code.
#
# Out of scope for MVP: GitLab / Bitbucket URLs, patch files, automatic
# test-command detection from .github/workflows. Use --cmd explicitly.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

CMD_TO_RUN=""
PR_REF=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cmd=*) CMD_TO_RUN="${1#--cmd=}"; shift ;;
        --cmd)   CMD_TO_RUN="$2"; shift; shift ;;
        --)      shift; break ;;
        --*)     stderr "Error: unknown flag '$1'"; exit 2 ;;
        *)       PR_REF="$1"; shift ;;
    esac
done

# Pick up any trailing args after `--` as the command if --cmd wasn't given.
if [[ -z "$CMD_TO_RUN" && $# -gt 0 ]]; then
    CMD_TO_RUN="$*"
fi

if [[ -z "$PR_REF" ]]; then
    stderr "Usage: rl bake-pr --cmd '<command>' <github-pr-url-or-shorthand>"
    exit 2
fi
if [[ -z "$CMD_TO_RUN" ]]; then
    stderr "Error: --cmd is required in MVP (auto-detection of test command is future work)."
    exit 2
fi

# Resolve the PR ref via gh. Both URL and shorthand forms work since
# `gh pr view` accepts either. --json gives us the fork URL + branch
# without scraping HTML.
info "Resolving PR via gh..."
PR_JSON=$(gh pr view "$PR_REF" --json 'headRepository,headRepositoryOwner,headRefName,headRefOid' 2>&1) || {
    stderr "Error: gh pr view failed for '$PR_REF'."
    stderr "$PR_JSON"
    exit 1
}

FORK_OWNER=$(echo "$PR_JSON" | grep -o '"headRepositoryOwner":[[:space:]]*{[^}]*"login":[[:space:]]*"[^"]*"' | sed -E 's/.*"login":[[:space:]]*"([^"]*)".*/\1/' | head -1)
FORK_REPO=$(echo "$PR_JSON" | grep -o '"headRepository":[[:space:]]*{[^}]*"name":[[:space:]]*"[^"]*"' | sed -E 's/.*"name":[[:space:]]*"([^"]*)".*/\1/' | head -1)
PR_BRANCH=$(echo "$PR_JSON" | grep -o '"headRefName":[[:space:]]*"[^"]*"' | sed -E 's/.*"headRefName":[[:space:]]*"([^"]*)".*/\1/' | head -1)
PR_SHA=$(echo "$PR_JSON" | grep -o '"headRefOid":[[:space:]]*"[^"]*"' | sed -E 's/.*"headRefOid":[[:space:]]*"([^"]*)".*/\1/' | head -1)

if [[ -z "$FORK_OWNER" || -z "$FORK_REPO" || -z "$PR_BRANCH" || -z "$PR_SHA" ]]; then
    stderr "Error: failed to parse gh output. Got:"
    stderr "  fork_owner='$FORK_OWNER' fork_repo='$FORK_REPO' pr_branch='$PR_BRANCH' pr_sha='$PR_SHA'"
    exit 1
fi

FORK_URL="https://github.com/${FORK_OWNER}/${FORK_REPO}.git"
TMP_REMOTE="_bake_pr_remote_$$"
LOCAL_REF="refs/_bake_pr/${FORK_OWNER}-${PR_BRANCH}"

info "PR ${PR_REF} -> ${FORK_OWNER}:${PR_BRANCH} @ ${PR_SHA:0:12}"

cleanup() {
    git remote remove "$TMP_REMOTE" 2>/dev/null || true
    # Leave the local ref for inspection; harmless.
}
trap cleanup EXIT

# Fetch the PR head into a detached local ref, host-side.
info "Fetching PR head from fork..."
git remote add "$TMP_REMOTE" "$FORK_URL"
git fetch --no-tags --no-recurse-submodules --depth=50 "$TMP_REMOTE" \
    "+${PR_BRANCH}:${LOCAL_REF}" >/dev/null 2>&1 || {
    stderr "Error: git fetch from $FORK_URL ($PR_BRANCH) failed."
    exit 1
}

# Verify the SHA matches what gh reported — guards against a race where
# the PR head moves between gh pr view and git fetch.
FETCHED_SHA=$(git rev-parse "$LOCAL_REF")
if [[ "$FETCHED_SHA" != "$PR_SHA" ]]; then
    warn "Fetched SHA ($FETCHED_SHA) differs from gh's reported head ($PR_SHA). PR may have updated mid-flight; continuing with fetched."
fi

# Ensure the bakeri.sh VM exists. We deliberately reuse the project's
# persistent VM rather than spinning a one-shot; the cached layers make
# the next provision instant.
vm_name=$(resolve_vm_name 2>/dev/null) || vm_name="$(basename "$(pwd)")"
if [[ ! -d "$AQ_STATE_DIR/$vm_name" ]]; then
    stderr "Error: VM for this project not found. Run 'rl new' first (or 'rl bake-run -- :' to provision)."
    exit 1
fi

# Push the PR ref into the VM via the framework's `rl` remote. The VM
# never talks to GitHub.
if ! git remote get-url rl >/dev/null 2>&1; then
    stderr "Error: 'rl' git remote not configured. Run 'rl new' to set it up."
    exit 1
fi
info "Pushing PR head into VM..."
git push -f rl "${LOCAL_REF}:refs/heads/_bake_pr" >/dev/null 2>&1 || {
    stderr "Error: git push to VM failed."
    exit 1
}

# Execute the test command in the VM, checked out to the PR ref.
info "Running PR command in VM (checked out to _bake_pr)..."
set +e
do_ssh "$vm_name" "cd ~/repo && git checkout _bake_pr >/dev/null && bash -lc '$CMD_TO_RUN'"
rc=$?
set -e

# Restore the VM's repo to its prior branch (best-effort; don't fail if
# there isn't one to go back to).
do_ssh "$vm_name" "cd ~/repo && git checkout - >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

exit "$rc"
