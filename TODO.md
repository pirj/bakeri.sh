# bakeri.sh TODO

This file tracks distribution-level work — plugins, commands, and design
choices specific to the CI / pre-baked-environment use case. Cross-cutting
items (framework, aq, AI plugins) live in the corresponding repo's TODO.

## North-star: GitHub Actions CI integration

bakeri.sh is primarily a CI runner. Local PR isolation is a side use case
deferred to a future separate tool (working title `p.rlock`). Anything
below is scored against "does this make GH Actions CI faster / easier".

- [done 2026-05-21, commit 532644c] **Cross-machine snapshot transport
  via `actions/cache`** + the reference workflow
  `.github/workflows/example-bakerish-ci.yml`. Both shipped together.
  The cache dir `~/.local/share/aq/cache/` round-trips between CI
  runs; second-and-later runs hit sub-second-warm.
- [done 2026-05-21, https://github.com/pirj/setup-bakerish] **Packaged
  action `pirj/setup-bakerish@v1`** — composite action that does
  install + cache restore + auto-save in one step. Inputs cover ref
  pinning, cache-key segmentation, cache-extra-paths, restore-only
  mode, and AQ_NO_SNAPSHOT_COMPRESS surfacing. Currently private
  during early adoption; v1 tag mutable, will cut v1.0.0 once
  upstream repos stabilise.
- [~] **OCI registry cache transport** (alt / supplement to
  actions/cache). **Shipped**: per-layer `bake cache --push <oci-ref>`
  / `--pull <oci-ref>` (commit 4ea3750) + two-tier integration in
  setup-bakerish (`oci-cache-ref` input, GH cache primary + OCI
  fallback). Per-layer model dedups identical slots server-side by
  sha256 — active PR churn uploads ~50 MB per commit (the one
  changed slot), not 2.6 GB. **Remaining**:
  - [ ] `bake cache --gc <oci-ref>` for periodic cleanup
    (registry-specific manifest enumeration). GHCR has no auto-TTL
    so this matters for long-lived caches.
  - [ ] Chunk-level dedup à la depot.dev (chunk qcow2 files,
    per-chunk content-addressable storage). Deferred until a
    measured pain point appears — for ephemeral CI runners the
    pull-side bandwidth win is marginal; storage-side dedup is the
    real value.

Full design in `docs/superpowers/specs/2026-05-20-bakerish-toml-and-prebuild.md`
(prebuild) and a future GH-CI-specific spec doc.

## Plugins — shipped baseline

All baseline plugins for the bakeri.sh CI distribution shipped pre-
2026-05-19:

- [done] **`mise`** — tool-version manager. Cached cold; hashes
  mise.toml / .tool-versions / .ruby-version / .nvmrc.
- [done] **`ruby-bundler`** — incremental cold; deps on mise; runs
  `bundle install` against Gemfile.lock.
- [done] **`npm`** — incremental cold; deps on mise; runs `npm install
  --prefer-offline` against package-lock.json.
- [done 2026-05-19, commit 314476f] **`uv`** / **`poetry`** / **`pnpm`** /
  **`cargo`** — dep-installer plugins mirroring the npm / ruby-bundler
  shape (incremental cold, deps on mise). Each scp's its lockfile +
  manifest into /home/rlock/repo, then runs the install command via
  mise-managed tooling. `cargo` stops at `cargo fetch` (target/ build
  is the user's call).
- [done 2026-05-19, commit 29a75fd] **`docker-engine`** + **`docker-
  compose`** (cached cold + cached live) + **`docker-registry-cache`**
  for the host-side pull-through Docker registry.

## Plugins — supplanted by bakerish.toml
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
  `RLOCK_PLUGIN_PATH`, appends synthesised plugins to `rl new`.
- [done 2026-05-21, rlock commit pending] **prereq:** rlock's
  `RLOCK_PLUGIN_PATH` — colon-separated PATH-like list of plugin
  directories. Replaces the older `PLUGIN_USER_DIR` / `PLUGIN_USER_DIRS`
  pair entirely; the singular `PLUGIN_USER_DIR` form is gone. Default
  when unset: `~/.config/rl/plugins`. Earlier entries win on name
  conflicts.
- [done 2026-05-20, rlock commit 2d46847] **prereq:**
  `toml_get_array_in_section` in rlock's `lib/toml.sh` — section-
  aware array reader needed by the synthesiser.
- [done 2026-05-21, commit ab40f7a] **`docs/bakerish-toml.md`** —
  format reference + per-ecosystem snippets (Rails, Django, Phoenix,
  Go modules). Cached/incremental contract with the rails-migrate
  caveat front-and-centre.
- [done 2026-05-21, commit 5546d20] **`docs/writing-a-plugin.md`** —
  escape-hatch guide for cases that outgrow `[prebuild.<name>]`.
- [done 2026-05-21, commit 981acbf + rlock 58d8fef] **`[memory] size`
  in bakerish.toml** — overrides `aq new --memory` via the new
  `rl new --memory=NG` flag. Takes precedence over the per-plugin
  max_snapshot_memory derivation; falls back to it when omitted.
- [ ] **`plugin = "<name>"` reference in `[prebuild.<name>]`** for
  interleaving prebuild steps between existing plugins. Pivots
  bakerish.toml to be the authoritative chain spec. Deferred until
  prebuild-MVP demonstrates the need.

## Commands to add

- [done 2026-05-19, commit 6 weeks ago] **`bake run`** — one-shot
  CI job runner. Reads bakerish.toml, auto-provisions VM if missing
  (triggered plugins + synthesised prebuild), pushes HEAD via the
  `rl` git remote, exec's the command, propagates exit code.
- [done 2026-05-21, commit pending] **`bake run --vm-suffix=<tag>`**
  for parallel-in-one-job VMs. Prereq: rlock's `rl new --name=<vm>`
  flag (commit pending in rlock) — lets bake-run pin the synthesised
  VM name to `<basename>-<suffix>` rather than the cwd-derived
  default. Each suffixed VM has its own state + cache slot; layer
  cache (under $RL_CACHE_DIR) is shared by `(plugin, snapshot_key)`
  so the snapshot layers transparently reuse across suffixes.
- [~] **`bake pr`** — partial: GitHub PR URLs + GitLab MR URLs +
  `--no-isolation` shipped 2026-05-19 (commit e03ff1a). **Remaining**:
  - [ ] Bitbucket PR URLs (no widely-deployed CLI; needs HTTP-API
    path).
  - [ ] Auto-detect command from `.github/workflows/*.yml` /
    `.gitlab-ci.yml` so `bake pr <url>` works without `--cmd`.
- [ ] **`bake snapshot ls / rm / inspect`** — explicit management of
  the layered cache. Wrap `aq snapshot` underneath. (Current
  `bake-cache` covers ls/rm; `inspect` for layer parent chains +
  per-key metadata is the gap.)
- [ ] **Cleanup of stale `_bake_run` / `_bake_pr` refs on the VM**.
  Each `bake run` / `bake pr` force-pushes to a dedicated ref
  (`refs/heads/_bake_run`, `refs/heads/_bake_pr`). They accumulate
  on the guest's git tree across many invocations. Add an `rl rm`
  hook (or a periodic GC step) to drop refs older than N days.

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
- [ ] **`examples/` directory** — ready-to-fork project skeletons
  showing canonical `bakerish.toml` + `.github/workflows/ci.yml`
  pairs per ecosystem (Rails+PG, Django+PG, Phoenix+PG, plain
  Node/pnpm, Go modules, ...). The per-ecosystem snippets in
  `docs/bakerish-toml.md` are reference fragments; an
  `examples/<ecosystem>/` carries a working fixture you can clone
  and adapt. Build incrementally — first Rails+PG (reuse
  `test/fixtures/rails-pg-sample`), then add ecosystems as adopter
  demand surfaces.

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
