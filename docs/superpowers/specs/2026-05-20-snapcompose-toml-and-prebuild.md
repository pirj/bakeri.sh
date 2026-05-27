# `snapcompose.toml` + prebuild layers — design spec — 2026-05-20

Project-level config for snapcompose: declarative chain extensions that
synthesise into rlock-visible snapshot layers, plus always-run hooks.
Captures all decisions from the 2026-05-20 design conversation so the
implementation pass can run without re-deriving them.

## Context and priority

snapcompose is a distribution on top of rlock targeted at **CI/PR
workloads** — primarily GitHub Actions caching where VM snapshots are
restored across CI runs. Local PR isolation is a side use case and is
*not* the priority; a future separate tool (working title `p.rlock`)
will cover it. This spec optimises for the CI scenario throughout.

Two concrete consequences for CI-first thinking:

- **No state between invocations.** A GH runner is destroyed after
  each job; `snapc run` always starts with a clean filesystem plus
  whatever `actions/cache` restored. Anything we'd otherwise treat as
  "invalidate on config change" is moot — the next CI run computes
  the new cache key from `snapcompose.toml` content and either hits or
  misses naturally.
- **Speed of warm restore over a populated cache is the headline.**
  Every design decision below trades complexity to preserve sub-3 s
  warm + fine-grained cache slots.

## File format

`snapcompose.toml` lives at the project root. The filename intentionally
drops the dot from "snapcompose" so it stays a normal visible config
file (sibling of `package.json` / `Gemfile`), not a dotfile.

Three section types:

```toml
[memory]
size = "4G"                          # override aq new --memory

[prebuild.<name>]                    # cached snapshot layer
cmd = "<shell-command>"
key_files = ["path/or/glob", ...]    # required
strategy = "cached"                  # default; can be "incremental"

[on_start.<name>]                    # always-run, no cache
cmd = "<shell-command>"
```

### `[memory]`

Single `size` key, format `"<N>G"`. Override what `aq new --memory`
gets. Defaults today come from `max_snapshot_memory` across active
plugins. The `snapcompose.toml` value wins if both are present.

### `[prebuild.<name>]`

Each section becomes an independent snapshot layer at the **end** of
the resolved chain (after all explicitly-activated plugins). Synthesis
mechanism described below.

Fields:

- `cmd` — shell command executed inside the VM via `aq exec`, as the
  `rlock` user from `/home/rlock/repo`. Multi-line strings are
  allowed (TOML triple-quoted).
- `key_files` — required list of file paths or globs at the project
  root. Their concatenated content (in declared order) feeds the
  `snapshot_key` SHA. Globs expanded by bash at synthesis time.
  Empty list is an error — every cached layer needs an explicit
  invalidation signal.
- `strategy` — `cached` (default) or `incremental`. See contract
  below.

### `[on_start.<name>]`

Each section becomes a post-restore hook (rlock's `start` hook). Fires
**every** `snapc run` after the snapshot chain finishes restoring,
regardless of cache hit/miss. No cache key, no `key_files`. Only `cmd`.

Use for: refreshing per-session secrets, generating dev-only fixtures,
warming caches in the running stack, any command that's not safely
cacheable.

## Strategy contract

### `cached` (default)

On cache miss, boot the VM from the **parent** layer's qcow2 (= the
chain state right before this layer) and run `cmd`. The resulting disk
becomes the new layer's snapshot.

Contract on `cmd`: deterministic given `key_files` + the parent disk
state. Re-running the same `cmd` on the same parent + same key_files
content must produce the same effective end state.

Good fits: `rails db:schema:load`, `assets:precompile`, anything
that's a pure function of declared inputs.

### `incremental`

On cache miss, boot the VM from the **latest snapshot of this same
plugin** (any key), not the parent. Then run `cmd`. The previous
plugin's output is the starting state; `cmd` is expected to compute
the delta against current `key_files`.

Contract on `cmd`: **delta-aware** AND **idempotent** when re-run
against any prior state of itself. Must converge to "what the current
`key_files` describe" without manual intervention or full reset.

**Critical caveat — what `incremental` does NOT fit:**

Tools that look at *external state* (not declared `key_files`) to
decide what to do break incremental's invariant. The canonical
example: `rails db:migrate`. It checks `schema_migrations` table to
see what's applied. If an existing migration file is *edited*
(renamed table, dropped column, etc.) instead of *added*, the file
content changes — but `rails db:migrate` against the previous
snapshot's DB sees "20230101 already applied" and does nothing.
Result: DB schema silently diverges from `db/schema.rb`. Silent
correctness bug.

Therefore for Rails: `db:schema:load`, `db:migrate`, `db:seed` all
get `strategy = "cached"`. The full `db/migrate/` directory in
`key_files` invalidates the cache on any edit, forcing a fresh
schema:load + migrate from clean DB.

**Where incremental DOES fit**: language package managers whose
install command's input *is* the lockfile content, and that
internally reconcile vendor state to the lockfile.

- `bundle install`: looks at current `Gemfile.lock` vs current
  `vendor/bundle`, computes delta. ✓
- `npm install` (NOT `npm ci`): same. ✓
- `pnpm install`: same. ✓
- `uv sync`: same. ✓
- `poetry install`: same. ✓
- `cargo fetch`: same. ✓

This is exactly the set of dep-installer plugins snapcompose ships;
they all already declare `strategy = "incremental"`.

## Mixing layers and ordering — current limitation

`[prebuild.*]` sections become snapshot layers at **one position in
the chain**: at the end, after all activated plugins (the
`snapc-prebuild` synthesis plugin declares deps on every plugin it can
see at synthesis time, so the resolver places it last).

This means a `[prebuild.*]` step can't be interleaved BETWEEN existing
plugins. Specifically: you can't have a step that runs between
`docker-compose` and `mise`, or before `docker-engine`.

The order *within* `[prebuild.*]` sections is preserved (source order
in `snapcompose.toml`).

**Roadmap follow-up: `plugin = "<name>"` reference.** A future
`snapcompose.toml` form would allow each section to be either an inline
`cmd + key_files` step OR a reference to an existing plugin
(`plugin = "ruby-bundler"`). Then `snapcompose.toml` becomes the
authoritative chain definition, with interleaving by construction.
This pivots rlock's mental model (trigger-detection + dep DAG → explicit
linear chain spec). Deferred until prebuild-MVP is shipped and
demonstrates the need.

## Plugin synthesis (option B)

snapcompose.toml's `[prebuild.*]` sections become snapshot layers via
**B**: pre-walk file-system generation, plus environment-driven
discovery in rlock.

### rlock-side change (small, generic)

`discover_plugins` accepts `RLOCK_PLUGIN_PATH` — a colon-separated
PATH-like list of plugin directories. Defaults to
`~/.config/rl/plugins` when unset. Earlier entries win on name
conflicts. Generic — any distribution can compose extra plugin
sources without rlock learning their config files.

### snapcompose-side synthesis (in `bin/bake`)

`snapc run` (and any future `bake new` / `bake stop`) wraps `rl new`
with these steps:

1. Parse `snapcompose.toml` via rlock's shared `lib/toml.sh`. Run
   `toml_validate` first — duplicate `[prebuild.<name>]` is an
   immediate error.
2. For each `[prebuild.<name>]` section, generate a synthesised
   plugin under `$PROJECT/.snapcompose/plugins/_prebuild-<name>/`:
   - `plugin.toml`: `description`, `protocol_version = "1"`, `deps =
     [previous-section-name]` (preserving source order), `triggers
     = []`, `commands = []`, `[snapshot]` with declared `strategy`
     and `kind = "cold"`.
   - `plugin.sh`: `snapshot_key()` hashes the declared `key_files`
     contents plus the literal `cmd` string (changing the cmd
     should invalidate, even if files don't); `snapshot_build()`
     runs the cmd via `aq exec`.
3. For each `[on_start.<name>]`, generate or extend a single
   `snapc-prebuild-hooks` plugin's `start()` hook to run the cmd.
   (Or generate per-section start-hook plugins; smaller blast
   radius if one cmd fails.)
4. Prepend the synth dir to `RLOCK_PLUGIN_PATH` —
   `RLOCK_PLUGIN_PATH="$PROJECT/.snapcompose/plugins:$RLOCK_PLUGIN_PATH"` —
   so rlock's discover_plugins picks up the synthesised plugins
   alongside the existing user-global ones.
5. Call `rl new <activated-plugins>` with the synthesised plugin
   names appended.

### Regeneration timing

**Always regenerate at every `bake` invocation.** Parsing TOML + writing
3-5 small plugin dirs is milliseconds. No mtime tracking, no
cache-invalidation logic, no race conditions. Idempotent.

### Naming

`_prebuild-<name>` — underscore prefix matches rlock's existing
`_base` convention for framework-internal plugins. `discover_plugins`
already filters `_`-prefixed plugins from triggers and CLI surfaces.

### `.snapcompose/plugins/` and gitignore

YAGNI for CI — every job starts on a clean runner. Don't add a
`.gitignore` for this dir yet. Revisit if local-workflow users ask.

## `snapc run` lifecycle

### Auto-create on miss

`snapc run -- <cmd>` is the single entry command. Behaviour:

- VM doesn't exist for project → run synthesis + `rl new` (creates
  VM, restores or builds chain) → SSH into VM → exec `<cmd>` → exit
  with `<cmd>`'s exit code.
- VM exists and is running → SSH into VM → exec `<cmd>` → exit. No
  state mutation between calls.
- VM exists but is stopped → `aq start` → exec → exit.

No separate `bake new` / `bake create` step. The first `snapc run`
*is* creation. Power users wanting explicit control can still call
`rl new` directly.

### `bake stop` and `bake rm`

- `bake stop` — explicit pause (`aq stop`). For local users wanting
  to free RAM without losing state. On CI: never needed; the runner
  is destroyed after the job.
- `bake rm` — explicit teardown (`rl rm`). Wipes the VM. State gone.
  Cache layers persist.

### Multiple commands, one VM

```bash
bake run -- bundle exec rspec
bake run -- bundle exec rubocop
bake run -- npm run lint
```

Each invocation reuses the running VM. Each is an SSH exec (~200 ms
from the live-restore micro-bench).

### Parallel: one VM concurrent / many VMs

- **Concurrent commands on one VM**: technically works (parallel SSH
  exec'es into one Linux box). User's responsibility to avoid
  conflicts (DB races, port collisions).
- **Sharded tests across many VMs in one CI job**: not the primary
  pattern; sharding is usually via GH Actions matrix (= separate
  runners = separate VMs by construction).
- **`snapc run --vm-suffix=<tag> -- <cmd>`**: override VM name to
  `<basename-of-project>-<tag>`. Lets a single job run e.g.
  `--vm-suffix=lint` and `--vm-suffix=test` against independent VMs
  in parallel. Each VM has its own state, separate from the default
  `snapc run` VM. Small `bake`-side addition.

### Matrix sharding (typical CI pattern)

```yaml
strategy:
  matrix:
    shard: [1, 2, 3, 4]
steps:
  - actions/cache (restore the snapcompose layer cache)
  - bake run -- rspec --shard=${{ matrix.shard }}/4
  - actions/cache (save)
```

Each shard = its own runner = its own VM. Layer cache is shared
across shards (same `actions/cache` key derived from
`snapcompose.toml` + lockfile hashes). 4 parallel warm-restores at
~2.7 s each = 4 VMs ready in 2.7 s wall-clock. The competitive
edge vs Docker-based sharding.

## Cleanup: dep-installer plugin footguns

Before shipping `snapc-prebuild`, fix the silent-fallback pattern in
all 6 dep-installer plugins (`ruby-bundler`, `npm`, `pnpm`, `uv`,
`poetry`, `cargo`):

- `eval "$(mise activate bash 2>/dev/null)" || true` swallows the
  case where mise isn't installed. Falls through to system tools
  (system Ruby / Node / Python) which are the wrong versions. Hard
  to debug.
- "If no `bundle` then `gem install bundler`" fallback installs the
  *system* bundler against the *system* Ruby instead of using mise's
  Ruby.

Fix: remove `2>/dev/null || true` from `mise activate`. Remove
"tool not found" fallbacks. Let the plugin fail with a clear error
("mise not found — declare mise in deps") so the user knows what's
actually wrong. The dep chain (`ruby-bundler.deps = ["mise"]`)
already guarantees mise is installed by the time we reach this
plugin's snapshot_build; the swallowing is masking a regression
that shouldn't be possible.

## GH CI workflow integration (parallel track)

After `snapc-prebuild` MVP ships:

### Reference setup

- `snapcompose/.github/workflows/example-snapcompose-ci.yml` in the
  snapcompose repo. Shows the canonical pattern: restore cache, run
  `snapc run`, save cache. Users copy-paste-adapt for their project.

### Cache mechanism

**MVP: GitHub Actions native cache** (`actions/cache`). Free, no
setup, ~10 GB per repo limit, 7-day retention without use. The cache
key is derived from `hashFiles('snapcompose.toml')` + lockfile hashes,
so any input change naturally moves to a new cache slot.

**Roadmap (lower priority)**: OCI registry support for cross-repo /
unlimited-size caches. Mirrors depot.dev's approach — chunk-level
content-addressable storage. Tracked in snapcompose `TODO.md`.

### Action shape

Either:

- **Shell snippet in `example-snapcompose-ci.yml`**: install snapcompose
  + rlock + qemu, run `snapc run`. More setup but visible.
- **Packaged action `pirj/setup-snapcompose@v1`**: encapsulates the
  prereq install + cache-restore choreography. Cleaner UX.

Probably ship both: snippet first (lower-overhead reference), action
second once usage patterns settle.

## Roadmap items captured

These go into `snapcompose/TODO.md`:

- [ ] **snapc-prebuild MVP** (this spec). Includes rlock's
  `RLOCK_PLUGIN_PATH` extension as a prereq.
- [ ] **`snapc run` auto-create + `--vm-suffix`**.
- [ ] **Footgun fix in 6 dep-installer plugins** (`mise activate`
  swallow).
- [ ] **GH Actions CI integration**: example workflow YAML, action
  package, docs.
- [ ] **`plugin = "<name>"` reference in `[prebuild.<name>]`** — for
  interleaving prebuild steps between existing plugins. Pivots
  snapcompose.toml to be the authoritative chain spec. Deferred until
  prebuild MVP demonstrates the need.
- [ ] **OCI registry cache transport** (alt to GH Actions native
  cache) for cross-repo / unlimited size.
- [ ] **Local PR isolation as a future separate tool (p.rlock)** —
  not snapcompose scope; captured here so snapcompose roadmap doesn't
  absorb it.

## Documentation to write

After implementation:

- `snapcompose/docs/snapcompose-toml.md` — format reference. Every section,
  every field, examples per ecosystem.
- `snapcompose/docs/writing-a-plugin.md` — pattern for ecosystem-
  specific cases that don't fit the prebuild model (positioning,
  unusual cache keys, custom triggers). Aimed at users who outgrew
  `[prebuild.<name>]`.
- `snapcompose/docs/ci-integration.md` — once GH Actions integration
  lands.

## What `[prebuild.<name>]` does NOT cover

For honest scoping, things this design intentionally doesn't address:

- **Interleaving order** with existing plugins (deferred to
  `plugin = "<name>"` future work).
- **Per-section trigger detection** ("activate `[prebuild.bundler]`
  only if `Gemfile.lock` is present"). Today every declared section
  participates unconditionally; if `key_files` are absent the cmd
  still runs and presumably no-ops or fails. Users who want
  conditional activation should write their own plugin with a
  `snapshot_should_skip` hook.
- **Cross-project shared prebuild definitions**. Each `snapcompose.toml`
  is project-local. Multi-project shared snippets are a future doc
  pattern, not a code feature.
