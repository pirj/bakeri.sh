# bakeri.sh TODO

This file tracks distribution-level work — plugins, commands, and design
choices specific to the CI / pre-baked-environment use case. Cross-cutting
items (framework, aq, AI plugins) live in the corresponding repo's TODO.

## Plugins to add

- **`mise`** — tool-version manager. `triggers = ["mise.toml", ".tool-versions"]`.
  `snapshot_key` = hash of mise config + `.ruby-version` / `.nvmrc` / etc.
  `strategy = "cached"`, `kind = "cold"`.
- **`ruby-bundler`** — `deps = ["mise"]`, `triggers = ["Gemfile.lock"]`,
  `strategy = "incremental"`, `kind = "cold"`. `snapshot_build` runs
  `bundle install --jobs=4`.
- **`npm`** — `deps = ["mise"]`, `triggers = ["package-lock.json"]`,
  `strategy = "incremental"`, `kind = "cold"`. `snapshot_build` runs
  `npm ci`.
- **`uv`** / **`poetry`** / **`pnpm`** — analogous patterns for
  python / pnpm respectively.
- **`rails-db-migrations`** — `deps = ["docker-compose", "ruby-bundler"]`,
  `strategy = "ephemeral"` (cheap to rerun, frequently changes).
- **`rails-db-seeds`** — `deps = ["rails-db-migrations"]`,
  `strategy = "ephemeral"`.
- **`rails-load-db-schema`** — `deps = ["docker-compose", "ruby-bundler"]`,
  `strategy = "cached"` (schema.rb changes are rarer than migrations).

## Commands to add

- **`bake run`** — one-shot CI job runner. Takes a command, dispatches to
  a fresh VM (from the warmest cached layer), runs the command, captures
  stdout/stderr + exit code, tears down. The shape mirrors `aq fanout`
  for parallelism over multiple shards.
- **`bake pr <pr-url>`** — checkout an untrusted PR (from any fork), run
  the project's CI command in isolation. Variant of `bake run` with
  source = git PR ref.
- **`bake snapshot ls / rm / inspect`** — explicit management of the
  layered cache. Wrap `aq snapshot` underneath.

## docker-compose kind = "live"

Currently `docker-compose` is `kind = "cold"`. The biggest single win in
the bakeri.sh story is flipping it to `kind = "live"` so warm VMs resume
from running compose state in <2 s instead of replaying `compose up` from
cold (~10–30 s for a real stack).

Blocked by:

- `aq new --memory=NG` flag (tracked in `aq/ROADMAP.md`). Live snapshots
  bind the captured RAM size; 1 GiB default in aq today is too tight for
  realistic Docker stacks (postgres + redis + app easily exceeds 1 GiB).
- Framework's `meta.json` RAM size pinning (will land alongside
  `--memory`, per `rlock/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md`).

Once both unblock: flip `docker-compose/plugin.toml` to `kind = "live"`,
measure savings, document in CHANGELOG.

## Distribution-specific UX

- `bake run` and `bake pr` need a way to surface measurement (cold/warm
  wall-clock per job). Tie into the framework's planned snapshot
  analytics (`rl cache stats` — see `rlock/TODO.md`).
- "Per-VM CPU/memory caps for shards" — already an `aq` follow-up under
  fanout. Surface from `bake run --max-cpu --max-mem` once aq supports.

## Shared docker-engine layer

`docker-engine`'s `snapshot_key` is a content hash that doesn't depend
on the project — every bakeri.sh project that activates Docker chains
off the same cached snapshot. Measurement TODO: how much disk does
this single snapshot occupy and how much time does it save versus a
cold install? (~30 s install, ~470 MiB snapshot — confirm.)

## Open design questions

- **PR-from-untrusted-fork model.** Two options:
  - Host adds the untrusted git repo as an `rl` remote and code reaches
    the VM via git push only — same model as ai.rlock for safety.
  - VM clones the fork directly (network-permitted in CI). Faster, less
    safe against malicious refs / fetch hooks.
  Recommendation: start with model A for `bake pr`, document the
  tradeoff. Model B can be opt-in for "trusted CI" use cases.
- **What's the smoke fixture project?** A minimal Rails+Postgres app
  lives in `test/fixtures/rails-app/` in the rlock repo today. Whether
  to keep it there (so framework integration tests use it) or move it
  here is TBD.
