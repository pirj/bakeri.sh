#!/usr/bin/env bash
#
# bake-pr — run a remote PR/MR (or local branch) in the project's
# bakeri.sh VM without giving the VM network access to an untrusted
# fork.
#
# Usage:
#   rl bake-pr [--cmd '<command>'] [--no-isolation] <ref>
#
# <ref> forms supported:
#   GitHub PR:   https://github.com/<owner>/<repo>/pull/<N>
#                <owner>/<repo>#<N>                     (gh shorthand)
#   GitLab MR:   https://gitlab.com/<owner>/<repo>/-/merge_requests/<N>
#                <owner>/<repo>!<N>                     (glab shorthand)
#   Local ref:   any branch / commit SHA / `git rev-parse`-able ref
#                (requires --no-isolation)
#
# Default (isolation) mode:
#   Resolves <ref> via the platform CLI (gh / glab) HOST-SIDE to fork URL
#   + branch + SHA, fetches the head into a detached local ref, then
#   pushes it to the VM via the existing `rl` remote. The VM never sees
#   the fork URL, and the host's authenticated credentials never enter
#   the VM.
#
# --no-isolation:
#   Treats <ref> as a local git ref. Skips the PR resolution and fork
#   fetch — pushes the ref to the VM directly. Use for: own-branch
#   smoke-tests before opening a PR, same-repo PRs you trust, or
#   testing local commits without remote round-trips.
#
# Out of scope: Bitbucket PRs (no widely-deployed CLI), patch files,
# automatic test-command detection from .github/workflows or
# .gitlab-ci.yml.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

CMD_TO_RUN=""
PR_REF=""
NO_ISOLATION=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cmd=*)         CMD_TO_RUN="${1#--cmd=}"; shift ;;
        --cmd)           CMD_TO_RUN="$2"; shift; shift ;;
        --no-isolation)  NO_ISOLATION=1; shift ;;
        --)              shift; break ;;
        --*)             stderr "Error: unknown flag '$1'"; exit 2 ;;
        *)               PR_REF="$1"; shift ;;
    esac
done

if [[ -z "$CMD_TO_RUN" && $# -gt 0 ]]; then
    CMD_TO_RUN="$*"
fi

if [[ -z "$PR_REF" ]]; then
    stderr "Usage: rl bake-pr [--cmd '<command>'] [--no-isolation] <ref>"
    exit 2
fi
if [[ -z "$CMD_TO_RUN" ]]; then
    stderr "Error: --cmd is required (auto-detection of test command is future work)."
    exit 2
fi

# Detect platform from PR_REF.
# Returns "github", "gitlab", or "local". Local means: not a recognised
# PR-URL form, will be treated as a git ref under --no-isolation.
detect_platform() {
    local ref="$1"
    case "$ref" in
        https://github.com/*)   echo "github" ;;
        https://gitlab.com/*)   echo "gitlab" ;;
        *#[0-9]*)               echo "github" ;;   # owner/repo#N
        *!*)                    echo "gitlab" ;;   # owner/repo!N
        *)                      echo "local" ;;
    esac
}

# Resolve a GitHub PR via gh, printing TAB-separated fork_url, branch, sha.
resolve_via_gh() {
    local ref="$1"
    command -v gh >/dev/null 2>&1 \
        || { stderr "Error: gh CLI not installed. Install from https://cli.github.com or use --no-isolation."; exit 1; }

    local json
    json=$(gh pr view "$ref" --json 'headRepository,headRepositoryOwner,headRefName,headRefOid' 2>&1) || {
        stderr "Error: gh pr view failed for '$ref'."
        stderr "$json"
        exit 1
    }
    local owner repo branch sha
    owner=$(echo "$json"  | grep -o '"headRepositoryOwner":[[:space:]]*{[^}]*"login":[[:space:]]*"[^"]*"' | sed -E 's/.*"login":[[:space:]]*"([^"]*)".*/\1/' | head -1)
    repo=$(echo "$json"   | grep -o '"headRepository":[[:space:]]*{[^}]*"name":[[:space:]]*"[^"]*"'      | sed -E 's/.*"name":[[:space:]]*"([^"]*)".*/\1/'  | head -1)
    branch=$(echo "$json" | grep -o '"headRefName":[[:space:]]*"[^"]*"'                                  | sed -E 's/.*"headRefName":[[:space:]]*"([^"]*)".*/\1/' | head -1)
    sha=$(echo "$json"    | grep -o '"headRefOid":[[:space:]]*"[^"]*"'                                   | sed -E 's/.*"headRefOid":[[:space:]]*"([^"]*)".*/\1/'  | head -1)
    if [[ -z "$owner" || -z "$repo" || -z "$branch" || -z "$sha" ]]; then
        stderr "Error: failed to parse gh output."
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\n' "https://github.com/${owner}/${repo}.git" "${owner}-${branch}" "$branch" "$sha"
}

# Resolve a GitLab MR via glab, printing TAB-separated fork_url, local_ref_suffix, branch, sha.
resolve_via_glab() {
    local ref="$1"
    command -v glab >/dev/null 2>&1 \
        || { stderr "Error: glab CLI not installed. Install from https://gitlab.com/gitlab-org/cli or use --no-isolation."; exit 1; }

    local json
    json=$(glab mr view "$ref" --output json 2>&1) || {
        stderr "Error: glab mr view failed for '$ref'."
        stderr "$json"
        exit 1
    }
    local fork_url branch sha
    # source_project.http_url_to_repo identifies the fork.
    fork_url=$(echo "$json" | grep -o '"source_project_url":[[:space:]]*"[^"]*"' | sed -E 's/.*"source_project_url":[[:space:]]*"([^"]*)".*/\1/' | head -1)
    branch=$(echo "$json"   | grep -o '"source_branch":[[:space:]]*"[^"]*"'      | sed -E 's/.*"source_branch":[[:space:]]*"([^"]*)".*/\1/'   | head -1)
    sha=$(echo "$json"      | grep -o '"sha":[[:space:]]*"[^"]*"'                | sed -E 's/.*"sha":[[:space:]]*"([^"]*)".*/\1/'             | head -1)
    if [[ -z "$fork_url" || -z "$branch" || -z "$sha" ]]; then
        stderr "Error: failed to parse glab output."
        exit 1
    fi
    # glab emits source_project_url as a web URL — append .git for fetch.
    [[ "$fork_url" == *.git ]] || fork_url="${fork_url}.git"
    # Derive a local-ref suffix from the URL slug (last path segment).
    local slug
    slug="${fork_url##*/}"
    slug="${slug%.git}"
    printf '%s\t%s\t%s\t%s\n' "$fork_url" "${slug}-${branch}" "$branch" "$sha"
}

PLATFORM=$(detect_platform "$PR_REF")

# Validate combination of --no-isolation and platform.
if [[ "$NO_ISOLATION" -ne 1 && "$PLATFORM" == "local" ]]; then
    stderr "Error: '$PR_REF' is not a recognised GitHub/GitLab PR URL."
    stderr "       Pass --no-isolation to treat it as a local git ref."
    exit 2
fi

# Resolve the ref (platform CLI or local git) BEFORE checking VM state —
# both surface clearer errors (missing CLI, bad ref) than a VM-not-found
# message would for those issues.
LOCAL_REF=""
if [[ "$NO_ISOLATION" -eq 1 ]]; then
    info "Local ref: ${PR_REF}"
    LOCAL_SHA=$(git rev-parse --verify "$PR_REF" 2>/dev/null) || {
        stderr "Error: '$PR_REF' is not a valid local git ref."
        exit 1
    }
    info "Resolved to ${LOCAL_SHA:0:12}"
    LOCAL_REF="$LOCAL_SHA"
else
    info "Resolving ${PLATFORM} PR via $([[ "$PLATFORM" == "github" ]] && echo gh || echo glab)..."
    case "$PLATFORM" in
        github)  resolved=$(resolve_via_gh   "$PR_REF") ;;
        gitlab)  resolved=$(resolve_via_glab "$PR_REF") ;;
        *)       stderr "Error: unsupported platform '$PLATFORM'."; exit 1 ;;
    esac
    IFS=$'\t' read -r FORK_URL REF_SUFFIX PR_BRANCH PR_SHA <<<"$resolved"

    LOCAL_REF="refs/_bake_pr/${REF_SUFFIX}"
    TMP_REMOTE="_bake_pr_remote_$$"
    info "PR ${PR_REF} -> ${PR_BRANCH} @ ${PR_SHA:0:12}"

    cleanup() {
        git remote remove "$TMP_REMOTE" 2>/dev/null || true
    }
    trap cleanup EXIT

    info "Fetching PR head from fork..."
    git remote add "$TMP_REMOTE" "$FORK_URL"
    git fetch --no-tags --no-recurse-submodules --depth=50 "$TMP_REMOTE" \
        "+${PR_BRANCH}:${LOCAL_REF}" >/dev/null 2>&1 || {
        stderr "Error: git fetch from $FORK_URL ($PR_BRANCH) failed."
        exit 1
    }

    FETCHED_SHA=$(git rev-parse "$LOCAL_REF")
    if [[ "$FETCHED_SHA" != "$PR_SHA" ]]; then
        warn "Fetched SHA ($FETCHED_SHA) differs from API's reported head ($PR_SHA). PR may have updated mid-flight; continuing with fetched."
    fi
fi

# Ensure the bakeri.sh VM exists and the `rl` remote is configured.
vm_name=$(resolve_vm_name 2>/dev/null) || vm_name="$(basename "$(pwd)")"
if [[ ! -d "${AQ_STATE_DIR:-}/$vm_name" ]]; then
    stderr "Error: VM for this project not found. Run 'rl new' first (or 'rl bake-run -- :' to provision)."
    exit 1
fi
if ! git remote get-url rl >/dev/null 2>&1; then
    stderr "Error: 'rl' git remote not configured. Run 'rl new' to set it up."
    exit 1
fi

info "Pushing ref into VM..."
git push -f rl "${LOCAL_REF}:refs/heads/_bake_pr" >/dev/null 2>&1 || {
    stderr "Error: git push to VM failed."
    exit 1
}

# Execute the command in the VM, checked out to the pushed ref.
info "Running command in VM (checked out to _bake_pr)..."
set +e
do_ssh "$vm_name" "cd ~/repo && git checkout _bake_pr >/dev/null && bash -lc '$CMD_TO_RUN'"
rc=$?
set -e

# Best-effort: restore the VM's repo to its prior branch.
do_ssh "$vm_name" "cd ~/repo && git checkout - >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

exit "$rc"
