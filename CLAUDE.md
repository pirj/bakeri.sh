# snapcompose — orientation for agents

`snapcompose` is the **CI / pre-baked-environment plugin pack** for
[`rlock`](https://github.com/pirj/rlock). Bakes a project's
environment once into a snapshot chain; serves it sub-second on
every `rl new` / `snapc run`.

> Renamed from `bakeri.sh` to `snapcompose` on 2026-05-27.
> The `bake` CLI command became `snapc`, the config file
> became `snapcompose.toml`, and the OCI cache media type
> became `application/vnd.snapcompose.layer.v1+gzip`. Clean
> break — old names are not aliased.

See [`README.md`](README.md) for usage, [`TODO.md`](TODO.md) for
open work, and the umbrella's [`CLAUDE.md`](../CLAUDE.md) for how
this fits with sibling repos.

## Primary focus: CI

This pack is **CI-runner-first**. Local PR isolation is deferred
to a future `p.rlock` tool. Decisions here should optimize for:

- Sub-second warm rebuild on GH Actions / GitLab CI / Buildkite
  runners.
- Cross-machine cache sharing (planned via OCI; see rlock's
  cross-machine snapshot transport TODO).
- Per-ecosystem layered snapshots (Docker → language runtimes →
  deps → app) so cache invalidation is granular.

If a decision optimizes for "developer laptop PR sandbox" at the
cost of CI ergonomics, push back.

## Plugins shipped

```
plugins/
├── docker-engine            apk add docker, single shared snapshot
├── docker-compose           bring compose stack up + healthcheck, snapshot warm
├── docker-registry-cache    host-side registry mirror, cache image layers
├── mise / uv / pnpm / poetry / cargo  dep-installer plugins
├── ruby-bundler / npm       same shape, per-ecosystem
├── snapc-run                 one-shot command runner ("bake run -- pytest")
├── snapc-cache               cache mgmt (--gc, --push, --pull OCI)
└── snapc-pr                  PR-from-untrusted-fork sandbox (in progress)
```

Each plugin is `rlock`'s plugin protocol shape — `plugin.toml`,
`plugin.sh`, optional `commands/`. See `rlock/CLAUDE.md` and
`docs/writing-a-plugin.md` for the protocol.

## Snapshot strategies

Plugins declare `[snapshot] strategy = "<kind>"` in
`plugin.toml`:

- **`cached`** — content-addressable; key derived from inputs
  (lockfile hash, Dockerfile content). Rebuilt from parent when
  key changes. Default for dep installers.
- **`incremental`** — rebuilds *on top of* parent's cached state
  rather than from scratch (e.g., adding one gem to an existing
  bundle). Cheaper miss path.
- **`ephemeral`** — runs every iteration, no cache (e.g., DB
  migrations). Use sparingly; ephemeral plugins block the
  cache-hit fast-path.

In-place updates of leaf incremental layers are a planned
optimization — see `../rlock/TODO.md` "In-place update of leaf
incremental layers."

## `snapcompose.toml` — per-project config

Project root has a `snapcompose.toml` declaring which plugins
activate, in what order, with what config:

```toml
[memory]
size = "4G"

[prebuild.docker-compose]
file = "docker-compose.test.yml"

[prebuild.ruby-bundler]
gemfile = "Gemfile"
```

`rl new` synthesizes the plugin activation list from this. See
`docs/snapcompose-toml.md` for the full schema.

## Commands

```sh
bake run -- <cmd>           one-shot job in a fresh-warm VM
bake cache --gc <oci-ref>   garbage collect old layers
bake cache --push           push cache to OCI registry
bake cache --pull           pull cache from OCI registry
bake pr <pr-url>            sandbox an untrusted fork PR
bake snapshot inspect       show cached snapshot details
```

`snapc run` is the CI workhorse; `snapc pr` is the in-progress
adventure (untrusted-fork model under discussion in TODO).

## Conventions

- **Per-ecosystem layer order is heuristic.** Empirically:
  `npm > bundle > python deps > Dockerfile/compose`. Higher layers
  rebuild more often. Lower layers should be most stable.
- **`docker-engine` snapshot key is a constant** so the qcow2 is
  shared across every project that uses Docker. Don't
  per-projectify it.
- **Snapshot-key serialization stays stable.** Cross-machine OCI
  transport (in flight) depends on key reproducibility across
  hosts. Be careful with hash inputs (sort lists, normalize
  whitespace, etc.).
- **`AQ_NO_SNAPSHOT_COMPRESS=1`** can be set for ~400 ms faster
  warm in exchange for ~1.1 GB cache per kind=live layer. CI
  with cache-restore-only jobs may want this; CI with
  cache-save jobs probably doesn't.

## What NOT to do

- Don't introduce a "bare Alpine" snapshot layer below
  `docker-engine`. In snapcompose every VM activates
  docker-engine, so a separate Alpine layer would always have
  exactly one descendant — pure overhead.
- Don't add plugins speculatively. Each new dep-installer is
  ~50 lines of boilerplate; we ship when a real user needs it.
- Don't break `snapcompose.toml` schema. `setup-snapcompose` and
  user projects depend on it; bump `protocol_version` and
  document migration if you must.
- Don't merge a CHANGELOG entry without a benchmark run if the
  change could affect cold/warm/warm-from-patch timings. The
  snapcompose-benchmark workflow (against the `snapcompose-benchmark`
  fixture repo) is the regression detector; methodology is in
  [`docs/bench/2026-05-29-microservices-benchmark.md`](docs/bench/2026-05-29-microservices-benchmark.md)
  and headline results in [`README.md`](README.md). Performance
  releases of aq and rlock also trigger this benchmark — see
  their CLAUDE.md.

## Sibling repos and dependencies

Required:

- [`rlock`](https://github.com/pirj/rlock) — the plugin framework.
- [`aq`](https://github.com/pirj/aq) — VM lifecycle (transitively).

Wraps `snapcompose` for GH Actions:

- [`setup-snapcompose`](https://github.com/pirj/setup-snapcompose) —
  composite action; rename to `setup-snapcompose` follows the
  snapcompose rename.

Coexists in workspace:

- [`ai.rlock`](https://github.com/pirj/ai.rlock) — different
  plugin pack (AI agents). Can run alongside `snapcompose` in the
  same VM; see ai.rlock README for combined use.

## Where decisions go

- **Mechanical work** for this pack → [`TODO.md`](TODO.md).
- **Cross-cutting decisions** affecting snapcompose + sibling
  repos (snapshot protocol changes, plugin-pack versioning,
  cache-transport format) → ADRs in `../meta/decisions/`. See
  `../meta/CLAUDE.md`.
- **CHANGELOG.md** for what shipped, per version.
- **SECURITY.md** for vulnerability reporting.

## Workspace context

This repo lives at `~/source/ai.rlock/snapcompose/` inside the
umbrella workspace. The umbrella's [`CLAUDE.md`](../CLAUDE.md) is
the single best map of how all sibling repos connect, including
the pending rename.
