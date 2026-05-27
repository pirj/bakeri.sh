# snapcompose

Distribution of pre-baked, cache-warmed environment plugins for [rlock](https://github.com/pirj/rlock). Bake your project's environment once into a snapshot; serve it warm in under a second on every subsequent `rl new`.

Aimed at CI/PR workloads where:
- A clean isolated VM is created for every job (or for every untrusted PR), and
- Spending minutes per job re-installing Docker, Ruby gems, npm packages, or running migrations from scratch is wasteful.

## Plugins shipped

- **`docker-engine`** — Installs Docker inside the Alpine guest. Single shared snapshot, reused across every project that activates Docker.
- **`docker-compose`** — Runs `docker compose up` against the project's compose file, waits for healthchecks, snapshots the warm state. Subsequent VMs from this snapshot have postgres / redis / app containers already running.

Planned (see `docs/superpowers/plans/`):

- `mise`, `nvm` — language runtime managers
- `ruby-bundler`, `npm`, `uv`, `pnpm`, `poetry` — dependency installers
- `rails-db-migrations`, `rails-db-seeds`, `rails-load-db-schema` — Rails lifecycle
- `snapc run` — one-shot CI job runner
- `snapc pr` — PR-from-untrusted-fork sandbox runner

## Install

snapcompose is a plugin pack: it provides plugins for the rlock framework. Clone both side by side, then add both `bin/` dirs to `PATH`:

```sh
git clone git@github.com:pirj/rlock.git
git clone git@github.com:pirj/snapcompose.git
export PATH="$PWD/rlock/bin:$PWD/snapcompose/bin:$PATH"
export RLOCK_PLUGIN_PATH="$PWD/snapcompose/plugins"

cd your-project   # has Dockerfile / docker-compose.yml
rl new            # provisions the VM, walking the cache chain
bake run -- rake test
```

`bake` is a thin wrapper around `rl bake-<sub>` for the friendlier UX:

| Friendly form           | Equivalent                              |
|-------------------------|-----------------------------------------|
| `snapc run -- <cmd>`     | `rl snapc-run -- <cmd>`                  |
| `snapc pr --cmd '<cmd>' <pr-url>` | `rl snapc-pr --cmd '<cmd>' <pr-url>` |
| `snapc cache`            | `rl snapc-cache`                         |
| `snapc cache --rm <plugin>` | `rl snapc-cache --rm <plugin>`         |

For full Docker functionality, `aq` (the underlying VM engine) needs enough RAM. The current `aq -m 1G` default is too tight for most compose stacks. Roadmap item: `aq --memory=NG` flag, after which snapcompose plugins can declare `kind = "live"` for sub-second restore. Until then, expect cold restarts on warm-layer cache hits.

## Design

snapcompose is one of several plugin packs that consume the rlock framework. Architecture is documented in:

- [`rlock/docs/superpowers/specs/2026-05-11-layered-snapshots-design.md`](https://github.com/pirj/rlock/blob/main/docs/superpowers/specs/2026-05-11-layered-snapshots-design.md) — layered qcow2 snapshot orchestration, plugin protocol, cached/incremental/ephemeral strategies.
- [`rlock/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md`](https://github.com/pirj/rlock/blob/main/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md) — cold-vs-live snapshot tradeoff.
- [`rlock/docs/superpowers/plans/2026-05-11-repo-split-migration.md`](https://github.com/pirj/rlock/blob/main/docs/superpowers/plans/2026-05-11-repo-split-migration.md) — why we have three repos.

## Tests

```sh
# From the snapcompose checkout, with rlock as a sibling directory:
bats test/
```

If rlock is elsewhere: `RL_FRAMEWORK_DIR=/path/to/rlock bats test/`.
