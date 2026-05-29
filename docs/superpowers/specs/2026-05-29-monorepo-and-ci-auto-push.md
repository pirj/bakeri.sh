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
- **F2 — auto-push at cache-miss boundary**: `snapc run` sets up the `rl` git remote automatically (non-interactive) and pushes HEAD into the VM **only when at least one upstream layer that needs source has a cache miss**. Full-warm runs skip the push.
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

**Mechanism:**

1. **Auto-setup `rl` remote.** In `snapc-run`, after `rl new` provisions the VM, before chain walking enters source-needing layers, check whether the host repo has an `rl` remote pointing at this VM's current SSH endpoint. If not, set it up:

   ```bash
   port=$(get_ssh_port "$vm_name")  # rlock util
   remote_url="ssh://rlock@localhost:$port/home/rlock/repo"
   key_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
   ssh_cmd="ssh $key_opts -p $port"
   git remote remove rl 2>/dev/null || :
   git remote add rl "$remote_url"
   git config --local core.sshCommand "$ssh_cmd"
   ```

   For multi-VM monorepo use, the remote name needs to be VM-scoped: `rl-<vm-name>`. The `--vm-suffix=<tag>` form already gives us a VM-scoped name (`<basename>-<tag>`), and `snapc-run` knows it, so the remote is `rl-${vm_name}`. Single-VM use keeps the unsuffixed `rl` for backwards compatibility.

2. **Decide whether to push.** Before walking the chain, ask each plugin's manifest whether it declares `needs_source = true` (new field in `plugin.toml`, default false). If any such plugin has a cache miss for its current snapshot_key, set `needs_push=1`.

   Cache miss check uses rlock's existing snapshot cache index — same lookup the chain walker would do anyway. Cheap.

3. **Push if needed.** If `needs_push=1`, run:

   ```bash
   git push -f "rl-$vm_name" "HEAD:refs/heads/_snapc_main"
   ```

   The push goes to the VM's bare-ish repo at `/home/rlock/repo` (set up by the `git` plugin's snapshot_build with `receive.denyCurrentBranch updateInstead` so the working tree advances). After push, `/home/rlock/repo` contains the full monorepo HEAD.

4. **Walk the chain.** Source is in place; cache-miss layers can build.

**Why "any source-needing miss → push at start" instead of "push exactly between the cached prefix and the first miss":** the simpler model has cost = 1 extra push per cold/partial-warm run (~100 ms – 1 s for typical repos). The precise-boundary model requires the chain walker to interleave snapshot logic with shell-out steps, which is a much bigger refactor for very small win. We can revisit if measurement shows the simpler model is too slow.

**Backwards compatibility:** plugins that don't declare `needs_source` default to false. Old fixtures see no behaviour change.

**`plugin.toml` schema bump:** add optional `needs_source = true|false` field at the top level of `plugin.toml`. Bump `protocol_version` from `"1"` to `"2"` so the framework knows whether to read this field; plugins without it default to false. Older snapcompose readers tolerate unknown fields.

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
