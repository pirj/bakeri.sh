# snapcompose monorepo + CI auto-push — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement F1 (subdir-as-project), F2 (auto-push at cache-miss boundary), F3 (drop redundant scp from docker-compose plugin) so the multi-microservice benchmark fixture (monorepo, no human in the loop) can run on GH Actions.

**Architecture:** New `SNAPC_VM_PROJECT_DIR` env var exported by `snapc-run` based on host-side subdirectory-vs-git-root delta. Plugins respect it when cd'ing inside the VM. `plugin.toml` gains a `needs_source` field; `snapc-run` sets up `rl-<vm-name>` remote and pushes HEAD before chain walking if any source-needing layer has a cache miss. `docker-compose` plugin drops its scp loop in favor of the now-always-present project tree at `$SNAPC_VM_PROJECT_DIR`.

**Tech Stack:** Bash, BATS, rlock plugin protocol.

**Spec:** [`docs/superpowers/specs/2026-05-29-monorepo-and-ci-auto-push.md`](../specs/2026-05-29-monorepo-and-ci-auto-push.md).

---

## Task 1: snapc-run computes and exports `SNAPC_VM_PROJECT_DIR`

**Files:**
- Modify: `plugins/snapc-run/commands/snapc-run.sh`

- [ ] **Step 1.1: Insert subdir detection block before chain walking**

After the existing `vm_name=...` resolution block (search for `[[ -n "$vm_name" ]] || die`), insert:

```bash
# F1 — subdir-as-project. If pwd is a subdir of the git repo, plugins
# inside the VM cd to /home/rlock/repo/<subdir-rel> instead of
# /home/rlock/repo. SNAPC_VM_PROJECT_DIR is exported for plugins to
# read; SNAPC_SUBPROJECT_REL is exported for snapc-run's own push step.
SNAPC_HOST_PROJECT_ROOT="$(pwd)"
if SNAPC_GIT_ROOT="$(git -C "$SNAPC_HOST_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    SNAPC_SUBPROJECT_REL="$(realpath --relative-to="$SNAPC_GIT_ROOT" "$SNAPC_HOST_PROJECT_ROOT")"
    [ "$SNAPC_SUBPROJECT_REL" = "." ] && SNAPC_SUBPROJECT_REL=""
else
    SNAPC_GIT_ROOT=""
    SNAPC_SUBPROJECT_REL=""
fi
if [ -n "$SNAPC_SUBPROJECT_REL" ]; then
    SNAPC_VM_PROJECT_DIR="/home/rlock/repo/$SNAPC_SUBPROJECT_REL"
else
    SNAPC_VM_PROJECT_DIR="/home/rlock/repo"
fi
export SNAPC_VM_PROJECT_DIR SNAPC_SUBPROJECT_REL SNAPC_GIT_ROOT SNAPC_HOST_PROJECT_ROOT
```

- [ ] **Step 1.2: Manually sanity-check**

From a temp dir that's a subdir of a git repo, run:

```bash
mkdir -p /tmp/_snapctest/services/main && cd /tmp/_snapctest && git init -q && cd services/main
( source /Users/pirj/source/ai.rlock/snapcompose/plugins/snapc-run/commands/snapc-run.sh 2>&1 | true
  echo "SNAPC_VM_PROJECT_DIR=$SNAPC_VM_PROJECT_DIR" )
```

The sourcing will error out at the arg-parser (no args), but the env-export block runs above the arg parser. Expected output: `SNAPC_VM_PROJECT_DIR=/home/rlock/repo/services/main`.

(If this assertion is awkward to verify by source-then-print because of intervening exits, skip the sanity check — the bats test in Task 8 covers it.)

- [ ] **Step 1.3: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add plugins/snapc-run/commands/snapc-run.sh
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "snapc-run: export SNAPC_VM_PROJECT_DIR for subdir-as-project (F1)"
```

---

## Task 2: `plugin.toml` schema bump — `needs_source` field

**Files:**
- Modify: `../rlock/lib/plugin.sh` (parsing)
- Modify: `plugins/docker-compose/plugin.toml`
- Modify: `plugins/ruby-bundler/plugin.toml`
- Modify: `plugins/mise/plugin.toml`
- Modify: `plugins/npm/plugin.toml`
- Modify: `plugins/uv/plugin.toml`
- Modify: `plugins/pnpm/plugin.toml`
- Modify: `plugins/poetry/plugin.toml`
- Modify: `plugins/cargo/plugin.toml`

- [ ] **Step 2.1: Add `needs_source` reading helper in rlock framework**

In `../rlock/lib/plugin.sh`, after the existing `plugin_dep_list()` function, add:

```bash
# Read the `needs_source` field from a plugin's plugin.toml. Returns
# "true" or "false" (defaults to false if the field is absent or the
# manifest is missing). Plugins set this true if their snapshot_build
# requires source code in /home/rlock/repo.
plugin_needs_source() {
    local plugin="$1"
    local manifest
    manifest="$(plugin_manifest_path "$plugin")" || return 0
    local val
    val="$(toml_get "$manifest" "needs_source")"
    [ "$val" = "true" ] && { echo "true"; return; }
    echo "false"
}
```

- [ ] **Step 2.2: Annotate plugins that need source**

In each of the listed `plugin.toml` files, add a top-level line:

```toml
needs_source = true
```

(For `docker-compose`, `ruby-bundler`, `mise`, `npm`, `uv`, `pnpm`, `poetry`, `cargo`.)

Plugins like `docker-engine` and `docker-registry-cache` do NOT need source; do not annotate them.

- [ ] **Step 2.3: Bump `protocol_version`**

In each modified `plugin.toml`, bump `protocol_version = "1"` to `protocol_version = "2"`. Update the framework's `PLUGIN_PROTOCOL_VERSION` constant in `../rlock/lib/plugin.sh` from `1` to `2`.

- [ ] **Step 2.4: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/rlock add lib/plugin.sh
git -C /Users/pirj/source/ai.rlock/rlock commit -m "framework: needs_source plugin.toml field + bump protocol_version 1→2"
git -C /Users/pirj/source/ai.rlock/snapcompose add plugins/*/plugin.toml
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "plugins: declare needs_source on source-dependent plugins, bump protocol_version"
```

---

## Task 3: snapc-run auto-sets `rl-<vm>` remote

**Files:**
- Modify: `plugins/snapc-run/commands/snapc-run.sh`

- [ ] **Step 3.1: Replace the existing `if [[ "$NO_PUSH" -eq 0 ]] ...` block**

The current block:
```bash
if [[ "$NO_PUSH" -eq 0 ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git remote get-url rl >/dev/null 2>&1; then
        info "Pushing HEAD into the VM..."
        _profile_mark "before git push"
        git push -f rl "HEAD:refs/heads/_snapc_run" >/dev/null 2>&1 \
            || warn "git push to VM failed — proceeding with whatever code is in the VM"
        _profile_mark "after git push"
    fi
fi
```

Replace with:

```bash
# F2 — auto-push at cache-miss boundary. snapc-run sets up the rl-<vm>
# remote (idempotent), checks whether any activated plugin that declares
# needs_source has a cache miss, and pushes HEAD if so.
if [[ "$NO_PUSH" -eq 0 ]] && [ -n "$SNAPC_GIT_ROOT" ]; then
    remote_name="rl-$vm_name"
    ssh_port="$(get_ssh_port "$vm_name")" || warn "could not read SSH port for $vm_name; skipping auto-push"
    if [ -n "${ssh_port:-}" ]; then
        # Idempotent remote setup. Lock .git/config against concurrent
        # snapc-run invocations (multi-VM monorepo workflows).
        (
            flock 9
            git -C "$SNAPC_GIT_ROOT" remote remove "$remote_name" 2>/dev/null || :
            git -C "$SNAPC_GIT_ROOT" remote add "$remote_name" \
                "ssh://rlock@localhost:$ssh_port/home/rlock/repo"
        ) 9>"$SNAPC_GIT_ROOT/.git/config.lock"

        # Decide whether to push: any source-needing plugin with miss?
        needs_push=0
        for plugin in $ACTIVATED_PLUGINS; do
            [ "$(plugin_needs_source "$plugin")" = "true" ] || continue
            cache_hit "$plugin" || { needs_push=1; break; }
        done

        if [ "$needs_push" = "1" ]; then
            info "Pushing HEAD into the VM ($remote_name)..."
            _profile_mark "before git push"
            GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $ssh_port" \
                git -C "$SNAPC_GIT_ROOT" push -f "$remote_name" "HEAD:refs/heads/_snapc_main" >/dev/null 2>&1 \
                || warn "git push to VM failed — proceeding with whatever code is in the VM"
            _profile_mark "after git push"
        else
            info "Full-warm cache — skipping git push."
        fi
    fi
fi
```

Note: `cache_hit` and `ACTIVATED_PLUGINS` are existing framework helpers — verify their exact names in `../rlock/lib/plugin.sh` and `bin/rl` before relying on them; rename if needed. (If `cache_hit` doesn't exist as a standalone helper, inline the equivalent: check whether the plugin's current snapshot_key exists in `~/.local/share/aq/cache/snapshots/<plugin>/<key>/`.)

- [ ] **Step 3.2: Move the push above the chain walk**

The existing snapc-run code calls `rl new` (chain walk) and then handles the push. With the new behaviour the push must happen *before* the chain walks (so that source-needing plugins find files when they run snapshot_build). Move the entire F2 block to execute *after* `rl new` provisions the VM (so SSH port exists and is readable) but *before* the chain walk completes — which means the chain walk itself needs to be split.

Concretely:
1. `rl new --provision-only` → creates the VM, runs the `_base` plugin only.
2. F2 push block (above).
3. `rl new --chain-only` → walks the rest of the chain.

If `rl new` doesn't expose those flags today, add them. The `_base` plugin (rlock's framework plugin) is the only one without `needs_source`; it can always run first without a push.

(If splitting `rl new` is more invasive than the rest of this plan combined, fall back to the simpler V1: always push BEFORE chain walking, accept ~1 s of overhead on full-warm runs. Track the optimization as a follow-up.)

- [ ] **Step 3.3: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add plugins/snapc-run/commands/snapc-run.sh
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "snapc-run: auto-setup rl-<vm> remote + push at cache-miss boundary (F2)"
```

---

## Task 4: docker-compose plugin — drop redundant scp + use SNAPC_VM_PROJECT_DIR

**Files:**
- Modify: `plugins/docker-compose/plugin.sh`

- [ ] **Step 4.1: Replace `snapshot_build`**

Replace the entire `snapshot_build()` function with:

```bash
snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    aq exec "$vm" sh <<SH
set -eu
command -v jq >/dev/null 2>&1 || apk add jq
cd "$vm_project_dir"
docker compose build
docker compose up -d

# Wait up to 5 minutes for all services to be running.
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
```

This removes the `aq scp` loop. The `mkdir -p /home/rlock/repo; chown rlock:rlock /home/rlock/repo` lines also go away — that directory is created by the `git` plugin's `snapshot_build`.

- [ ] **Step 4.2: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add plugins/docker-compose/plugin.sh
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "docker-compose: drop scp loop, cd to SNAPC_VM_PROJECT_DIR (F3)"
```

---

## Task 5: ruby-bundler plugin — cd to subdir

**Files:**
- Modify: `plugins/ruby-bundler/plugin.sh`

- [ ] **Step 5.1: Find and update the cd in `snapshot_build`**

In the existing `snapshot_build`, the inner shell block does `cd /home/rlock/repo` (or operates implicitly from there). Replace the hard-coded path with `${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}`. Same edit pattern as in `docker-compose`.

- [ ] **Step 5.2: Update `snapshot_should_skip` and `snapshot_key` lookups**

These functions run on the *host* (they hash files relative to `pwd`). They should already work because `pwd` is the subproject — no change needed. Sanity check by reading the existing code.

- [ ] **Step 5.3: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add plugins/ruby-bundler/plugin.sh
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "ruby-bundler: cd to SNAPC_VM_PROJECT_DIR in VM (F1)"
```

---

## Task 6: mise / npm / uv / pnpm / poetry / cargo plugins — cd to subdir

**Files:**
- Modify: `plugins/mise/plugin.sh`
- Modify: `plugins/npm/plugin.sh`
- Modify: `plugins/uv/plugin.sh`
- Modify: `plugins/pnpm/plugin.sh`
- Modify: `plugins/poetry/plugin.sh`
- Modify: `plugins/cargo/plugin.sh`

- [ ] **Step 6.1: Same edit pattern as Task 5 for each plugin**

In each plugin's `snapshot_build`, replace any hard-coded `cd /home/rlock/repo` with `cd "${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"`. If a plugin doesn't explicitly cd (relies on default cwd in `aq exec`), add the cd at the top of the inner shell heredoc.

- [ ] **Step 6.2: Commit (one commit covering all six plugins)**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add plugins/{mise,npm,uv,pnpm,poetry,cargo}/plugin.sh
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "ecosystem plugins: cd to SNAPC_VM_PROJECT_DIR (F1)"
```

---

## Task 7: Bats test — subdir-as-project

**Files:**
- Create: `test/subdir_as_project.bats`

- [ ] **Step 7.1: Write the test**

```bash
#!/usr/bin/env bats

# Verifies that snapc-run operates a snapcompose project living in a
# subdirectory of the host git repo. Inside the VM, plugins must
# operate at /home/rlock/repo/<subdir>, not /home/rlock/repo.

load helpers

setup() {
    if [ -z "${RUN_INTEGRATION:-}" ]; then
        skip "Integration test — set RUN_INTEGRATION=1 to run."
    fi
    require_tools snapc rl aq git
    TEST_REPO="$(mktemp -d)/monorepo"
    mkdir -p "$TEST_REPO/services/main"
    git -C "$TEST_REPO" init -q -b main
    cat > "$TEST_REPO/services/main/snapcompose.toml" <<'TOML'
[memory]
size = "2G"
TOML
    cat > "$TEST_REPO/services/main/docker-compose.yml" <<'YAML'
services:
  redis:
    image: redis:7-alpine
YAML
    git -C "$TEST_REPO" add -A
    git -C "$TEST_REPO" -c user.email=t@t -c user.name=t commit -q -m init
}

teardown() {
    cd "$TEST_REPO/services/main" 2>/dev/null && rl rm 2>/dev/null || :
    rm -rf "$TEST_REPO"
}

@test "snapc run from services/main puts the project at /home/rlock/repo/services/main" {
    cd "$TEST_REPO/services/main"
    run snapc run -- 'pwd; ls'
    [ "$status" = 0 ]
    [[ "$output" == *"/home/rlock/repo/services/main"* ]]
    [[ "$output" == *"docker-compose.yml"* ]]
    [[ "$output" == *"snapcompose.toml"* ]]
}
```

- [ ] **Step 7.2: Run locally**

```bash
RUN_INTEGRATION=1 bats /Users/pirj/source/ai.rlock/snapcompose/test/subdir_as_project.bats
```

Expected: PASS. If FAIL, debug — likely `cd "${SNAPC_VM_PROJECT_DIR:-...}"` not actually taking effect because snapc-run isn't exporting the var in the right scope.

- [ ] **Step 7.3: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add test/subdir_as_project.bats
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "test: subdir-as-project integration test"
```

---

## Task 8: Bats test — auto-push (cache miss + full warm)

**Files:**
- Create: `test/auto_push.bats`

- [ ] **Step 8.1: Write the test**

```bash
#!/usr/bin/env bats

load helpers

setup() {
    if [ -z "${RUN_INTEGRATION:-}" ]; then
        skip "Integration test — set RUN_INTEGRATION=1 to run."
    fi
    require_tools snapc rl aq git
    TEST_REPO="$(mktemp -d)/monorepo"
    mkdir -p "$TEST_REPO/services/main"
    git -C "$TEST_REPO" init -q -b main
    cat > "$TEST_REPO/services/main/snapcompose.toml" <<'TOML'
[memory]
size = "2G"
TOML
    cat > "$TEST_REPO/services/main/docker-compose.yml" <<'YAML'
services:
  redis:
    image: redis:7-alpine
YAML
    echo "test marker" > "$TEST_REPO/services/main/MARKER"
    git -C "$TEST_REPO" add -A
    git -C "$TEST_REPO" -c user.email=t@t -c user.name=t commit -q -m init
}

teardown() {
    cd "$TEST_REPO/services/main" 2>/dev/null && rl rm 2>/dev/null || :
    rm -rf "$TEST_REPO"
}

@test "first snapc run sets up the rl-<vm> remote and pushes" {
    cd "$TEST_REPO/services/main"
    run snapc run -- 'cat MARKER'
    [ "$status" = 0 ]
    [[ "$output" == *"test marker"* ]]
    run git -C "$TEST_REPO" remote
    [[ "$output" == *"rl-main"* ]]
}

@test "second snapc run on unchanged code skips the push (full warm)" {
    cd "$TEST_REPO/services/main"
    snapc run -- true >/dev/null
    SNAPC_PROFILE=1 run snapc run -- true
    [[ "$output" != *"before git push"* ]]
    [[ "$output" == *"Full-warm cache"* ]]
}
```

- [ ] **Step 8.2: Run locally + commit**

```bash
RUN_INTEGRATION=1 bats /Users/pirj/source/ai.rlock/snapcompose/test/auto_push.bats
git -C /Users/pirj/source/ai.rlock/snapcompose add test/auto_push.bats
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "test: auto-push (cache miss vs full warm)"
```

---

## Task 9: CHANGELOG + tag

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 9.1: Add v0.3.0 entry**

Top of `snapcompose/CHANGELOG.md`:

```markdown
## [0.3.0] - 2026-05-30

### Added
- **Subdir-as-project (F1):** `snapcompose.toml` may live in any subdirectory of the host git repo. `snapc-run` detects the subdir relative to the git root and exports `SNAPC_VM_PROJECT_DIR`; plugins cd to this directory inside the VM. Enables monorepo fixtures with one snapcompose project per service.
- **Auto-push at cache-miss boundary (F2):** `snapc-run` sets up `rl-<vm-name>` git remote automatically (non-interactive) and pushes HEAD into the VM only when an activated plugin that declares `needs_source = true` has a cache miss. Full-warm runs skip the push. CI-friendly out of the box.
- **`plugin.toml` `needs_source` field (protocol v2):** plugins declare whether their `snapshot_build` requires the project source tree in `/home/rlock/repo`. Defaults to false. Annotated for all dep-installer plugins (`docker-compose`, `mise`, `ruby-bundler`, `npm`, `uv`, `pnpm`, `poetry`, `cargo`).

### Changed
- **`docker-compose` plugin (F3):** dropped the `aq scp Dockerfile compose .dockerignore` loop. Source now arrives via the auto-push; the plugin's `snapshot_build` simply cds to `SNAPC_VM_PROJECT_DIR` and runs `docker compose build && docker compose up -d`.
- **Plugin protocol version**: 1 → 2. Plugins must opt into the bump explicitly. Backwards-compatible: v1 plugins continue to work, just without `needs_source` recognition.
```

- [ ] **Step 9.2: Tag**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add CHANGELOG.md
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "release: v0.3.0 — subdir-as-project + auto-push + docker-compose scp drop"
git -C /Users/pirj/source/ai.rlock/snapcompose tag v0.3.0
git -C /Users/pirj/source/ai.rlock/snapcompose push origin main v0.3.0
```

---

## Spec-coverage self-review

- F1 subdir-as-project: Tasks 1 + 5 + 6 + 7.
- F2 auto-push at cache-miss boundary: Tasks 2 (plugin.toml field) + 3 (snapc-run logic) + 8 (test).
- F3 drop scp from docker-compose: Task 4.
- Multi-VM concurrency safety (flock on `.git/config`): Task 3.1.
- Bats test gates: Tasks 7 + 8 (opt-in via `RUN_INTEGRATION=1`).
- CHANGELOG + tag: Task 9.

End of plan.
