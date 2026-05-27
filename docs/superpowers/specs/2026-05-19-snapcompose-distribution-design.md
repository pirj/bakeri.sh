# snapcompose Distribution Design

## What this is

A plugin pack for the [rlock](https://github.com/pirj/rlock) framework that turns rlock + aq into a CI/PR runner. Reuses rlock's layered qcow2 snapshot mechanism to bake a project's environment (Docker engine + compose services + language runtimes + deps) once and serve it warm — sub-second on cache hit — for every subsequent job.

Distinct from [ai.rlock](https://github.com/pirj/ai.rlock) (AI-coding-agent sandbox) — that distribution's plugins (auth-proxy, agent-claude-code, agent-codex) target an interactive developer workflow. snapcompose targets one-shot CI jobs, PR-from-fork sandboxes, and parallel job fan-out. Both can coexist on the same rlock + aq install.

## Goals

1. **Sub-second warm restart** for the common case (compose stack + deps installed, no project content changes). Live snapshots make this technically possible; snapcompose is the productization.
2. **A clean CI surface**: `snapc run <command>` for one-shot jobs, `snapc pr <pr-ref>` for PR-from-fork. No interactive UX required.
3. **No Docker on the host**. The whole point of running inside a VM is host isolation; snapcompose never spawns containers on the host.
4. **Idiomatic project files**. Users keep their existing `Dockerfile`, `docker-compose.yml`, `Gemfile`, `package.json`, etc. — no snapcompose-specific config files.
5. **Cache is host-local**. No remote registry, no team cache. The CI host owns it. (Cross-host transport is a future ask, see `rlock/TODO.md`.)

## Non-goals

- Replacing GitHub Actions / GitLab CI / Buildkite. snapcompose is a *runner* — something a CI pipeline calls into per job. Orchestration, secrets management, artifact upload, etc. stay with the existing CI platform.
- Multi-host fleet management. The cache is one host; running across a cluster requires the future "cross-machine snapshot transport" work in rlock.
- Custom-DSL workflows. Plugins are bash + plugin.toml; that's it.
- Auto-detecting Dockerfile changes vs lockfile changes vs migration changes. The layered cache already handles this via per-layer keys; explicit tooling on top is YAGNI until measurements say otherwise.

## Plugin set

The full chain (in load order, lowest in qcow2 stack first):

```
docker-engine        cached, cold,  shared across all snapcompose projects
  └─ docker-compose  cached, COLD initially → flip to LIVE post-MVP
       └─ mise       cached, cold,  triggers on mise.toml / .tool-versions
            └─ ruby-bundler   incremental, cold, triggers on Gemfile.lock
                 └─ npm       incremental, cold, triggers on package-lock.json
                      └─ uv / pnpm / poetry / cargo (similarly), if triggered
                           └─ rails-db-migrations   ephemeral
                                └─ rails-db-seeds   ephemeral
                                     └─ branch     cached, cold (from rlock framework)
```

Strategy and kind per plugin are summarized below. See `rlock/docs/superpowers/specs/2026-05-11-layered-snapshots-design.md` (strategies) and `rlock/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md` (kinds).

| Plugin | strategy | kind | Trigger | Recipe summary |
|---|---|---|---|---|
| `docker-engine` | cached | cold | none (pulled by deps) | `apk add docker docker-cli-compose`, `service docker start`. Key is a constant — single shared snapshot for all snapcompose projects. |
| `docker-compose` | cached | cold (MVP) → **live (post --memory wiring)** | `docker-compose.yml`, `docker-compose.yaml` | `docker compose build && docker compose up -d`, poll `docker compose ps` until all services are `running` and (if healthcheck declared) `healthy`. Key = SHA256 of `Dockerfile + compose YAML + .dockerignore + compose.override.*`. |
| `mise` | cached | cold | `mise.toml`, `.tool-versions`, `.ruby-version`, `.nvmrc` | `apk add mise`, `mise install`. Key = SHA256 of the tool-version files. |
| `ruby-bundler` | incremental | cold | `Gemfile.lock` | `bundle install --jobs=4 --retry=3` in the project's bind-mount. Key = SHA256 of `Gemfile.lock + .ruby-version + .bundler-version`. |
| `npm` | incremental | cold | `package-lock.json` | `npm ci`. Key = SHA256 of `package-lock.json + .nvmrc`. |
| `uv` / `pnpm` / `poetry` / `cargo` | incremental | cold | their lockfile | analogous. |
| `rails-db-migrations` | ephemeral | n/a | `db/migrate/` non-empty + `bin/rails` present | `bundle exec rails db:migrate`. Always rerun. |
| `rails-db-seeds` | ephemeral | n/a | `db/seeds.rb` present | `bundle exec rails db:seed`. Always rerun. |
| `rails-load-db-schema` | cached | cold | `db/schema.rb` present | `bundle exec rails db:schema:load`. Key = SHA256 of `db/schema.rb`. |

Ordering rationale: tool installers (mise) below dep installers (ruby-bundler, npm); language deps below DB lifecycle (rails-*); Docker-stack establishment below everything (compose up first so DB exists for migrations). Within sibling layers (ruby-bundler / npm), order doesn't strictly matter — `resolve_deps` is the tiebreaker; we'll publish whatever order falls out and revisit if real workloads have a strong preference.

### docker-compose `kind = "live"` rollout

Today (MVP): `kind = "cold"`. On cache hit, framework rebases disk to the cached qcow2; `aq start` boots fresh; `docker compose ps` is already populated because the disk has the saved Docker state — but containers re-launch from their last serialized state, which is usually OK but can take seconds.

Post-MVP (once we have a `[memory]` declaration in snapcompose manifests, see below): `kind = "live"`. Snapshot captures running compose stack + Postgres/Redis page cache + db connection state. Restore loads via `aq --from-snapshot=...` with `-incoming file:memory.bin`, guest resumes mid-flight, `docker compose ps` reports all services running immediately. Target restoration time: <2 s wall clock.

The flip is gated on:
1. `docker-compose/plugin.toml` declaring `memory = "4G"` (or similar) so the framework pins RAM at save time.
2. Project-level override mechanism — see "Open design questions" below.

## Commands

snapcompose commands ship as their own plugin in the same pack. They are not implemented as part of any other plugin.

### `snapc run [-- <command...>]`

Run one job in a fresh VM. Steps:

1. Walk the snapshot chain in the project (rlock framework, no snapcompose-specific logic). Net result: a warm VM ready at the topmost layer.
2. Push the user's project worktree into the VM (`git push rl HEAD:refs/heads/_bake_main`). Same mechanism the framework's `git` plugin uses.
3. `ssh` in, run the user's command in `/repo`. Capture stdout, stderr, exit code.
4. Tear down the VM (delete the per-VM qcow2 overlay; the cached snapshot stays).
5. Exit with the user's command's exit code.

Usage:

```sh
bake run -- rake test
bake run -- npm test
bake run -- pytest -x
```

The `--` is a convention to separate snapcompose flags (none yet) from the user command.

Implementation note: this is mostly orchestration around `rl new` + `git push` + `ssh exec` + `rl rm`. The plugin's `commands` field exposes `run` as a CLI verb; the framework dispatches.

### `snapc pr <pr-ref>`

Run the same flow as `snapc run`, but checkout an untrusted PR-from-fork before running the project's CI command. The PR ref can be:

- A GitHub URL (`https://github.com/owner/repo/pull/123`).
- A bare fork URL + branch (`git@github.com:contributor/repo.git contributor-branch`).
- A patch file (`snapc pr --patch /tmp/foo.patch`).

In all cases, the snapcompose host fetches the PR's commits into a local detached ref **on the host**, then pushes that ref into the VM via the standard `git` plugin. **No network access from the VM to the original fork.** The VM only sees what the host explicitly pushed — which means a malicious fork can't trigger network requests during checkout / dep install.

After the VM is provisioned + the project's deps are warm:

- `snapc pr` checks for a `bake.yaml` or `.github/workflows/*.yml` (in priority order) to find the test command. Falls back to `snapc run -- $(detect-test-cmd)` heuristics or to an explicit `--cmd` flag.
- Run the command, capture exit code + output.
- Tear down.

This is the highest-value piece of snapcompose for many users: isolated PR test runs that can't exfiltrate secrets, can't reach the internet to pivot, and start in under a second on warm cache.

### `snapc snapshot [ls | rm | rebuild]`

Explicit management of the cache, mostly for debugging and reclaiming disk.

- `snapc snapshot ls` — list cached layers per plugin, with sizes and last-used dates.
- `snapc snapshot rm <plugin>[:<key>]` — drop a specific cache entry (or all entries for a plugin).
- `snapc snapshot rebuild <plugin>` — force-rebuild a plugin's layer on the next `snapc run`. Drops the entry and any descendants in the chain (otherwise they'd cache-hit but point at a defunct ancestor).

Implementation: thin wrapper around `rl cache` (which doesn't exist yet — see `rlock/TODO.md` "Snapshot analytics"). snapcompose's `snapc snapshot ls` can ship before `rl cache stats` lands as a simple `du -sh` over `~/.local/share/aq/cache/*/*`.

## Benchmark targets

A real Rails 7 + Postgres 16 + Redis 7 + Sidekiq fixture project, average-sized (~100 K LOC, ~80 gems, ~500 npm packages, ~50 migrations). Numbers are wall-clock from `snapc run` invocation to the user's command starting.

| Scenario | Target | Notes |
|---|---|---|
| Cold (no cache, first ever run on host) | <90 s | Includes `apk add docker`, `docker compose pull/build/up`, `bundle install`, `npm ci`, schema load, migrate, seed. |
| Warm dep-only churn (Gemfile.lock changed, nothing else) | <30 s | `ruby-bundler` rebuilds incrementally; everything above hits cache. |
| Warm full hit (no project changes) | <2 s | Every layer hits cache. Final step is just `git push` + ssh exec. |
| Warm full hit with `kind = "live"` on docker-compose | <1 s | Live restore of compose + DB connection pool + page cache + Sidekiq workers. Aspirational; requires docker-compose live flip. |

These are stretch targets to validate the architecture, not commitments. First measurements happen after the `mise` + `ruby-bundler` plugins ship and we benchmark `snapc run` against a real fixture project (likely the rails-app fixture currently in `rlock/test/fixtures/rails-app/`).

## Distribution-level memory declarations

A project might pass `--memory=4G` to `aq` but snapcompose's plugin chain doesn't see that — `aq` is invoked once by rlock for the whole VM. So memory needs to be declared at the **distribution** or **project** level, not per plugin:

Option A — **per-plugin maximum, framework picks the max**:

```toml
# plugins/docker-compose/plugin.toml
[snapshot]
strategy = "cached"
kind     = "live"
memory   = "4G"        # this plugin asks for at least 4G

# plugins/ruby-bundler/plugin.toml
[snapshot]
strategy = "incremental"
kind     = "cold"
memory   = "2G"        # at least 2G; ignored under kind=cold but documented
```

The framework collects all `memory` values across the active plugin chain and picks the maximum, then invokes `aq new --memory=<max>G`.

Option B — **project-level override file** (`snapcompose.yaml` in repo root):

```yaml
memory: 6G
```

Read by snapcompose at the start of `snapc run`; passed to `aq new`.

Option C — **`snapc run --memory=NG`** explicit flag.

Recommendation: ship all three. (A) is the safe default (plugin authors know their needs), (B) lets project owners override per-project without forking the distribution, (C) is for one-off debugging.

## Open design questions

1. **Smoke fixture location.** `rlock/test/fixtures/rails-app/` currently has a minimal Rails+PG fixture used by framework integration tests. Whether to keep it in rlock (so framework integration tests cover docker-in-VM flows via snapcompose side-by-side checkout) or move to `snapcompose/test/fixtures/`. Recommendation: keep in rlock for now since rlock's integration_layered.sh already references it; revisit if rlock's test surface stops needing Docker.

2. **`snapc pr` source resolution.** GitHub URL parsing requires either a `gh` dep or hand-rolled REST calls. Recommendation: shell out to `gh pr view --json` for GitHub URLs (covers 95% of use cases); document GitLab / Bitbucket as future plugin work.

3. **PR-from-trusted vs PR-from-fork.** Some teams want isolation only for forks. Add `snapc pr --trust-internal` to skip the host-mediated git push for branches from the same repo (faster checkout, less isolation). Default: maximum isolation.

4. **Cache hit reporting.** Should `snapc run` print which layers hit/missed by default? Recommendation: yes, one line per layer with timings, similar to `docker build` output. Helps users debug "why is my cache missing".

5. **`snapc snapshot ls` format.** JSON vs table. Recommendation: human-readable table by default, `--json` flag for scripting.

6. **Concurrent `snapc run` on the same project.** Two CI jobs hit the same warm cache simultaneously — does the qcow2 backing chain handle this? Yes (each VM gets its own overlay above the shared backing), but the framework should document this explicitly. Out of scope for the design but worth a smoke test.

## What's NOT in this spec (deferred)

- **`bake fanout` / parallel sharding.** aq already has `aq fanout` for parallel VM execution; surface it through snapcompose once the single-VM path is solid.
- **Cross-machine cache sync** (depot.dev pattern). Tracked in `rlock/TODO.md`.
- **Custom container runtimes** (podman, OrbStack). snapcompose runs vanilla Docker inside the Alpine VM; users wanting different runtimes can write their own plugin pack.
- **Network policy controls.** A workload running inside the VM can reach the internet via `10.0.2.2` user-mode NAT today. Stricter egress (allowlists, mitm logging) is a future snapcompose concern, not MVP.
- **CI-platform integrations** (GHA / GitLab / Buildkite YAML generators). snapcompose is the runner; integrations come once the runner is solid.

## Order of operations

The plan, in implementation order:

1. **`mise` plugin** — validates the layered model with a second non-Docker plugin and exercises `deps = ["docker-engine"]` (mise needs Docker repos to be ready? no, actually mise is independent of docker-engine; let's verify and adjust).
2. **`ruby-bundler` plugin** + benchmark on the Rails fixture.
3. **`snapc run` command** — productizes the cache-walk-and-exec flow.
4. **`docker-compose` kind = "live" flip** + memory declaration mechanism.
5. **`snapc pr` command** — high-value, more involved.
6. **`snapc snapshot ls / rm / rebuild`** — debug ergonomics.

`npm`, `uv`, `rails-*` plugins follow the same pattern as `ruby-bundler` and land incrementally.
