# bakeri.sh TODO

This file tracks distribution-level work — plugins, commands, and design
choices specific to the CI / pre-baked-environment use case. Cross-cutting
items (framework, aq, AI plugins) live in the corresponding repo's TODO.

## North-star: GitHub Actions CI integration

bakeri.sh is primarily a CI runner. Local PR isolation is a side use case
deferred to a future separate tool (working title `p.rlock`). Anything
below is scored against "does this make GH Actions CI faster / easier".

- [ ] **Cross-machine snapshot transport via `actions/cache`**. The
  layer cache must survive between CI runs. MVP: GH Actions native
  `actions/cache@v4` keyed by `hashFiles('bakerish.toml', '<lockfiles>',
  ...)`. Free, no setup, ~10 GB / 7-day retention limits. The cache
  dir is `~/.local/share/aq/cache/` — restore/save it, every other
  bake-run on the runner is sub-second warm.
- [ ] **`bakeri.sh/.github/workflows/example-bakerish-ci.yml`** — the
  reference setup users copy-paste from. Shows: prereq install (qemu,
  aq, rlock, bakeri.sh), actions/cache restore, `bake run -- <cmd>`,
  actions/cache save.
- [ ] **Packaged action `pirj/setup-bakerish@v1`** — encapsulates the
  prereq install + cache choreography. Cleaner UX than the snippet
  once usage patterns settle. Ship after the example workflow has a
  few real consumers.
- [ ] **OCI registry cache transport** as alt-to-actions/cache for
  cross-repo / unlimited-size needs. Mirrors depot.dev's approach.
  Roadmap item; not blocking the MVP.

Full design in `docs/superpowers/specs/2026-05-20-bakerish-toml-and-prebuild.md`
(prebuild) and a future GH-CI-specific spec doc.

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
- [done 2026-05-19, commit 314476f] **`uv`** / **`poetry`** / **`pnpm`** /
  **`cargo`** — dep-installer plugins mirroring the npm / ruby-bundler
  shape (incremental cold, deps on mise). Each scp's its lockfile +
  manifest into /home/rlock/repo, then runs the install command via
  mise-managed or apk-fallback tooling. `cargo` stops at `cargo fetch`
  (target/ build is the user's call).
- [supplanted by bakerish.toml] **rails-* lifecycle plugins**
  (`rails-db-migrations`, `rails-db-seeds`, `rails-load-db-schema`) —
  originally planned as separate ecosystem plugins. The 2026-05-20
  design review concluded these are one-line shims around a single
  `docker compose exec app rails db:<verb>` command each; making them
  separate plugins would compound to N similar shims per ecosystem
  (Django manage.py, Phoenix mix ecto, ...). Folded into
  `bakerish.toml` `[prebuild.<name>]` sections instead. The Rails
  reference snippet ships in [bakerish-toml.md doc — TODO]; rails-*
  semantics map directly to:

    ```toml
    [prebuild.schema-load]
    cmd = "docker compose exec app rails db:schema:load"
    key_files = ["db/schema.rb"]            # strategy defaults to cached

    [prebuild.migrate]
    cmd = "docker compose exec app rails db:migrate"
    key_files = ["db/schema.rb", "db/migrate"]  # NOT incremental — see spec note

    [prebuild.seed]
    cmd = "docker compose exec app rails db:seed"
    key_files = ["db/seeds.rb"]
    ```

  See `docs/superpowers/specs/2026-05-20-bakerish-toml-and-prebuild.md`
  for the full reasoning (in particular: why `rails db:migrate` is NOT
  `incremental` — silent correctness bug on edited migrations).

## bakerish.toml — project config + prebuild synthesis

Full design in `docs/superpowers/specs/2026-05-20-bakerish-toml-and-prebuild.md`.

- [done 2026-05-20, commit 1c11e46] `lib/bake-prebuild.sh` synthesiser
  + `lib/bake-prebuild-template.sh` runtime template. Each
  `[prebuild.<name>]` becomes its own snapshot layer with its own
  cache slot. 18 bats.
- [done 2026-05-20, commit dc25e11] `bake-run` reads bakerish.toml,
  synthesises `.bakerish/plugins/_prebuild-*`, exports
  `PLUGIN_USER_DIRS`, appends synthesised plugins to `rl new`.
- [done 2026-05-20, rlock commit 7e47d12] **prereq:** rlock's
  `PLUGIN_USER_DIRS` (colon-separated list) — required for bake-run
  to compose synth dir alongside user-global plugin dir.
  *Follow-up rename below: PLUGIN_USER_DIRS → RLOCK_PLUGIN_PATH.*
- [ ] **rename `PLUGIN_USER_DIRS` → `RLOCK_PLUGIN_PATH`** (rlock-side
  change, bakeri.sh consumer follows). Current name is too generic;
  PATH-like naming (RLOCK_ prefix, no "user", no "dir/s") makes it
  obvious it's rlock-specific composition like shell `$PATH`. Also
  drop the singular `PLUGIN_USER_DIR` fallback — every consumer
  switches to RLOCK_PLUGIN_PATH (single-entry list is still fine).
- [done 2026-05-20, rlock commit 2d46847] **prereq:**
  `toml_get_array_in_section` in rlock's `lib/toml.sh` — section-
  aware array reader needed by the synthesiser.
- [ ] **`docs/bakerish-toml.md`** — format reference + per-ecosystem
  snippets (Rails, Django, Phoenix, Go modules, ...). Explains the
  `cached` vs `incremental` contract with the rails-db-migrate
  caveat front-and-centre.
- [ ] **`docs/writing-a-plugin.md`** — for users who outgrow
  `[prebuild.<name>]`: how to write a custom plugin with finer
  positioning, custom triggers, multi-step caching.
- [ ] **`[memory] size`** in bakerish.toml is parsed but not yet
  wired to anything. Override what `aq new --memory` gets — needed
  for the docker-compose `kind = "live"` flip once aq's memory
  pinning lands (see "docker-compose kind = live" below).
- [ ] **`plugin = "<name>"` reference in `[prebuild.<name>]`** for
  interleaving prebuild steps between existing plugins. Pivots
  bakerish.toml to be the authoritative chain spec. Deferred until
  prebuild-MVP demonstrates the need.

## Commands to add

- [done 2026-05-19, commit 6 weeks ago] **`bake run`** — one-shot
  CI job runner. Reads bakerish.toml, auto-provisions VM if missing
  (triggered plugins + synthesised prebuild), pushes HEAD via the
  `rl` git remote, exec's the command, propagates exit code.
- [ ] **`bake run --vm-suffix=<tag>`** for parallel-in-one-job VMs
  (e.g. `bake run --vm-suffix=lint -- rubocop` alongside `bake run
  --vm-suffix=test -- rspec` in the same CI job, each on its own VM
  with its own cache slot). Per-spec section "Parallel: one VM
  concurrent / many VMs".
- **`bake pr <pr-url>`** — checkout an untrusted PR (from any fork), run
  the project's CI command in isolation. Variant of `bake run` with
  source = git PR ref.
- **`bake snapshot ls / rm / inspect`** — explicit management of the
  layered cache. Wrap `aq snapshot` underneath.

## docker-compose kind = "live"

- [done 2026-05-19] `docker-compose/plugin.toml` is now
  `kind = "live"` with `memory = "4G"`. aq's `--memory=NG` flag (aq
  v2.5.0) and the framework's per-plugin `memory` declaration both
  shipped together; the docker-compose flip followed. Live restore
  on the rails-pg-sample fixture measured at ~1.3 s end-to-end (see
  `../benchmark-2026-05-19-c-live-restore.md`).

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

## Consolidate `bake-run` / `bake-pr` / `bake-cache` into one `bake-cli` plugin

Surfaced by the 2026-05-19 architecture review (Issue 1) — see
[`architecture-review-2026-05-19.md`](../architecture-review-2026-05-19.md).

Today, each of the three command-only plugins declares the same 10-entry
trigger list (Dockerfile, docker-compose.\*, mise.toml, .tool-versions,
.ruby-version, .nvmrc, .node-version, Gemfile.lock, package-lock.json) —
the union of distribution-relevant files. Adding a new dep installer
(uv, pnpm, poetry, ...) requires updating its triggers AND all three
bake-\* plugins. Triplication invites drift.

Fix: collapse into a single `bake-cli` plugin:

```
plugins/bake-cli/
  plugin.toml              # commands = ["bake-run", "bake-pr", "bake-cache"]
                           # trigger list (single source of truth)
  commands/
    bake-run.sh            # moved from plugins/bake-run/commands/
    bake-pr.sh             # moved from plugins/bake-pr/commands/
    bake-cache.sh          # moved from plugins/bake-cache/commands/
```

Framework already supports multiple `commands = [...]` per plugin (used
by `auth-proxy` declaring `auth`, `branch` declaring `branch`, etc.).
The command scripts don't change; just the directory layout + the three
old `plugin.toml` files merge into one.

Tests: rename test files (`bake_run.bats` -> `bake_cli_run.bats` or
keep names), update `PLUGIN_DIR` to point at `plugins/bake-cli`. Net
test count unchanged.

[done 2026-05-19, commit 29a75fd] Pre-warmed docker image cache on host. Shipped as `docker-registry-cache` plugin: CNCF distribution binary in proxy mode on 127.0.0.1:5000; guest dockerd configured via daemon.json `registry-mirrors` to 10.0.2.2:5000. ~60 s saved off every cold rl new after the first on the host. host_deps = ["registry"] (brew install docker-distribution-distribution on macOS).

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
