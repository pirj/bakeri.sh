# snapcompose monorepo + CI auto-push — Design

**Date:** 2026-05-29
**Status:** Design, pending implementation
**Driver:** Walking-skeleton attempt of the multi-microservice benchmark surfaced two gaps that block CI usage on any non-toy fixture.

## Problem

snapcompose today works end-to-end only when:

1. The project root IS the git repo root (single-app fixtures like `snapcompose-rails-pg-example`), AND
2. A human sits at a terminal, runs `rl new`, then manually wires up the `rl` git remote and pushes HEAD into the VM.

Neither assumption holds for the multi-microservice benchmark:

1. The benchmark fixture is a **monorepo** — six service codebases under `services/<name>/`, each with its own `snapcompose.toml`, `Gemfile.lock`/`package.json`/etc. Plugins inside the VM look at `/home/rlock/repo/Gemfile.lock` (root), but the actual lockfile is at `/home/rlock/repo/services/main/Gemfile.lock`.
2. In CI **no one is at a terminal**. The current `snapc run` flow is: provision VM (chain walks, may fail if a layer needs source), then `git push -f rl HEAD` (skipped because the `rl` remote doesn't exist). Source never arrives in the VM, so `docker compose build` / `bundle install` / `mise install` all fail.

The walking-skeleton attempt hit this on the very first run: `COPY Gemfile Gemfile.lock /rails/` fails inside the build container because the only files snapc pushed into the VM were the Dockerfile and the compose YAML — nothing else.

## Goals

Three coordinated features (treat them as one design):

- **F1 — subdir-as-project**: `snapcompose.toml` may live in a subdirectory of the git repo. When `snapc run` is invoked from `<repo>/services/main/`, every plugin's snapshot_build inside the VM operates in `/home/rlock/repo/services/main/`, not `/home/rlock/repo/`.
- **F2 — auto-push at cache-miss boundary**: The framework (`rl new` / `cmd_new`) sets up an `rl-<vm>` git remote automatically (non-interactive, flock-protected) and pushes HEAD into the VM **at most once per `rl new`**. The push fires at one of two points: (a) during chain walking, at the first cache-miss boundary of a non-{`_base`, `git`} plugin — ensures that source-needing snapshot_builds find files; (b) post-walk catch-all — fires on full-warm runs where every snapshot was cache-hit but app-code on host has advanced since the last build (a one-line edit in `app/models/user.rb` invalidates no `snapshot_key`, yet the user expects fresh source).
- **F3 — drop redundant scp from docker-compose plugin**: once F2 delivers source via git push, the plugin's `aq scp Dockerfile compose .dockerignore` loop is redundant. Replace it with a single `cd "$VM_PROJECT_DIR" && docker compose ...`.

## Non-goals

- Per-service `snapcompose.toml` discovery from a parent directory ("auto-detect all snapcompose projects in the monorepo"). Each `snapc run` invocation is still scoped to one subproject; the multi-VM orchestration happens at the workflow / shell level via parallel `snapc run` calls with `--vm-suffix`.
- Hot-reload of source between layer rebuilds. If a *later* layer's miss requires more recent source than what was pushed at the *earlier* miss boundary, we re-push at that point too. But within a single `snapc run`, source is captured once at the first miss.
- Sparse git push (push only the subproject subtree). The whole monorepo HEAD goes to every VM — that's a benchmark-honest behaviour (cache cost reflects the monorepo reality), and the framework changes to support sparse push would dwarf the benefit.

## Design

### F1 — subdir-as-project

**Mechanism:** export an environment variable from `snapc-run` that every plugin reads when it cd's inside the VM.

`snapc-run.sh` adds:

```bash
SNAPC_HOST_PROJECT_ROOT="$(pwd)"
if SNAPC_GIT_ROOT="$(git -C "$SNAPC_HOST_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    SNAPC_SUBPROJECT_REL="$(realpath --relative-to="$SNAPC_GIT_ROOT" "$SNAPC_HOST_PROJECT_ROOT")"
    [ "$SNAPC_SUBPROJECT_REL" = "." ] && SNAPC_SUBPROJECT_REL=""
else
    # Not a git repo. Push won't work; SNAPC_SUBPROJECT_REL stays empty.
    SNAPC_SUBPROJECT_REL=""
fi

if [ -n "$SNAPC_SUBPROJECT_REL" ]; then
    SNAPC_VM_PROJECT_DIR="/home/rlock/repo/$SNAPC_SUBPROJECT_REL"
else
    SNAPC_VM_PROJECT_DIR="/home/rlock/repo"
fi

export SNAPC_VM_PROJECT_DIR SNAPC_SUBPROJECT_REL SNAPC_GIT_ROOT
```

**Plugins** that operate inside the VM use this variable when they cd. Today they hard-code `cd /home/rlock/repo` (or rely on rlock's default). They become:

```bash
cd "${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"
```

The fallback default preserves backwards compatibility with non-monorepo fixtures.

**Plugins touched in this design**: `docker-compose`, `ruby-bundler`, `mise`, `npm`, `uv`, `pnpm`, `poetry`, `cargo`. Each is a single-line change.

**Snapshot keys are unaffected** — they read host files (paths relative to host project root, which is already `pwd`), not VM files.

### F2 — auto-push at cache-miss boundary

**Mechanism.** Implemented entirely in the rlock framework — no plugin metadata needed. The framework knows when it's walking a cache-miss layer; it owns source delivery.

**1. Helper `git_sync_source_to_vm` in `rlock/lib/util.sh`.** Single function the framework calls. Idempotent and concurrency-safe.

```bash
git_sync_source_to_vm() {
    local vm="$1"
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    local port
    port=$(get_ssh_port "$vm" 2>/dev/null) || { warn ...; return 0; }

    local remote_name="rl-$vm"
    local remote_url="ssh://rlock@localhost:$port/home/rlock/repo"

    # flock the .git/config to serialize concurrent multi-VM remote setup.
    (
        flock 9
        git -C "$git_root" remote remove "$remote_name" 2>/dev/null || :
        git -C "$git_root" remote add "$remote_name" "$remote_url"
    ) 9>"$git_root/.git/config.lock"

    info "Pushing HEAD into VM '$vm'..."
    GIT_SSH_COMMAND="ssh ... -p $port" \
        git -C "$git_root" push -f "$remote_name" HEAD:refs/heads/main
}
```

The VM-scoped remote name (`rl-<vm>`) lets one monorepo's working tree have N parallel remotes — one per microservice VM — without collision.

**2. Walker hook for the first-miss case.** `snapshot_walk_chain` in `rlock/lib/snapshot.sh` exposes a pluggable hook `snapshot_walk_chain_first_miss_hook`. At the start of each miss-path iteration, if the missing plugin is not `_base` or `git` (those plugins build the receiving repo itself — there's nothing to push into yet) and we haven't pushed yet this walk, the walker calls the hook and marks `_SNAPSHOT_FIRST_MISS_DONE=1`.

`cmd_new` in `rlock/bin/rl` defines the hook to call `git_sync_source_to_vm` whenever the `git` plugin is in the resolved chain. Other entry points (e.g. a future `rl provision` without git) can leave it undefined; the walker no-ops in that case.

**3. Post-walk catch-all in `cmd_new`.** Full-warm runs never enter the miss-path body and so never call the hook. To handle the "app-code changed on host since last build, but no `snapshot_key` invalidated" case, `cmd_new` checks `_SNAPSHOT_FIRST_MISS_DONE` after the walk completes. If still 0 and the git plugin is in the chain, it calls `git_sync_source_to_vm` once more — guaranteeing the running VM always has the host's latest HEAD before user code runs.

**Net effect: at most one push per `rl new`, always after the last restore/build and before user-visible code execution.** Cold + partial-warm push during the walk (so source-needing builds see fresh files); full-warm push after the walk (so the running VM sees fresh app code).

**`snapc run` against an existing VM.** When the VM already exists, `rl new` doesn't run and the framework path isn't entered. `snapc run` itself calls the same `git_sync_source_to_vm` helper as a separate refresh-on-rerun pass. Same flock semantics, same idempotent remote setup. Old `git push -f rl HEAD:refs/heads/_snapc_run` code path removed.

**No plugin metadata needed.** Earlier drafts of this spec proposed a `needs_source = true|false` field in `plugin.toml` to gate the push per-plugin. Discarded: pushing source into a plugin that doesn't strictly need it costs nothing (the VM's repo just has files no one reads), but having to thread a flag through every dep-installer plugin AND through the walker is a real maintenance tax. Framework owns the policy.

**Backwards compatibility.** Framework-only change. No plugin protocol bump. Pre-v0.3.0 plugins unchanged.

### F3 — drop redundant scp from docker-compose plugin

Once F2 delivers source via git push, the `docker-compose` plugin's `aq scp` loop is dead code. Replace `snapshot_build` body with:

```bash
snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<SH
set -eu
command -v jq >/dev/null 2>&1 || apk add jq
cd "${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"
docker compose build
docker compose up -d

# Wait up to 5 minutes for all services to be running. (unchanged from existing)
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

The plugin declares `needs_source = true` in its `plugin.toml` (because it needs `docker-compose.yml` and possibly `Dockerfile` from the project, both of which now arrive via git push).

`snapshot_key()` is unchanged — it still hashes host-side files.

## Multi-VM concurrency (relevant to Phase 3 benchmark, designed for here)

A monorepo workflow spawns N parallel `snapc run --vm-suffix=svc-N` calls. The git remote auto-setup must be **serialized** because `git remote add` writes to `.git/config` and concurrent writers can corrupt the file. Two safeguards:

1. `snapc-run` wraps the remote-setup block with `flock` on `.git/config.lock`. Sequential within the lock; parallel everywhere else.
2. Pushes themselves are safe to run in parallel — different remotes, different destinations.

If `rl new` itself is invoked for multiple VMs in parallel, the chain walker may race on shared cache layers (`docker-engine` snapshot etc.). That concurrency lives in the rlock framework, not snapcompose, and is out of scope for this spec — but if it's missing, the benchmark workflow will surface it and the fix can land in a follow-up.

## Testing

Bats tests under `snapcompose/test/`:

- **`test/subdir_as_project.bats`**: create a temp git repo with a snapcompose project in `services/main/`. Run `snapc run` from that subdir. Assert that inside the VM, plugins operate in `/home/rlock/repo/services/main/` (e.g. `Gemfile.lock` is found there, `bundle install` succeeds).
- **`test/auto_push.bats`**: same fixture, no pre-existing `rl` remote. Run `snapc run`. Assert `rl-<vm>` remote was created and HEAD was pushed.
- **`test/auto_push_full_warm.bats`**: same fixture, run twice. Assert second run does NOT push (full warm).
- **`test/docker_compose_no_scp.bats`**: assert the docker-compose plugin no longer scp's Dockerfile to the VM (no separate aq scp call before `docker compose build`).

All four extend the existing `test/` patterns. They will be slow (each provisions a real VM) — gate behind the same opt-in env var the existing integration tests use.

## CHANGELOG / version

- **snapcompose**: bump to `v0.3.0` (minor — backwards-compatible plugin protocol bump, new auto-push behaviour). Document in CHANGELOG.md.
- **rlock**: no changes required by this spec.
- **setup-snapcompose**: no input changes; consumers pin `snapcompose-version: v0.3.0` to opt in.
- **snapcompose-benchmark workflow**: pin `snapcompose-version: v0.3.0`, restore `services/main/` subdir as the snapcompose project.

## Rollout

1. Spec approved.
2. Implementation per plan `2026-05-29-monorepo-and-ci-auto-push.md`.
3. Bats tests green locally.
4. snapcompose `v0.3.0` tag.
5. Walking-skeleton benchmark workflow re-pinned to `v0.3.0`, fixture re-arranged to monorepo shape, re-triggered.
6. Headline cold timing lands in `snapcompose/README.md`.
