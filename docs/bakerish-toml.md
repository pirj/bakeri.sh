# `bakerish.toml`

Project-level config for bakeri.sh. Lives at the project root next to
`Gemfile` / `package.json` / `Cargo.toml`. Visible (not a dotfile) and
checked into version control.

`bake run` reads this file on every invocation. Sections inside it
either:

- override aq/rlock framework defaults (`[memory]`, `[disk]`), OR
- declare additional snapshot layers run after the activated plugin
  chain (`[prebuild.<name>]`), OR
- declare always-run post-restore hooks (`[on_start.<name>]`).

If the file is absent, `bake run` behaves like `rl new` — discovers
plugins by triggers and provisions accordingly. The file is a strict
superset of the default behaviour; you only declare what you want to
customise.

## File location and validation

- `<project-root>/bakerish.toml`. No alternative location is searched.
- Parsed via rlock's shared `lib/toml.sh`. Same parser as `plugin.toml`
  manifests, so the same syntax rules apply.
- Duplicate `[section]` headers (e.g. two `[prebuild.migrate]` blocks
  in the same file) are a hard error per the TOML standard. Validated
  via `toml_validate` before any field is read.

## Sections

### `[memory]`

```toml
[memory]
size = "4G"
```

Overrides the guest RAM that `aq new --memory` is given. Takes
precedence over the per-plugin `max_snapshot_memory` derivation —
that is, declaring `4G` here pins the VM at 4 GiB regardless of what
the active plugins individually request. Useful when you need *more*
RAM than the chain's plugins ask for (extra headroom for your tests'
runtime memory), or when you want an explicit pin so it's visible in
project config.

If `[memory] size` is absent, the framework falls back to the per-
plugin max (e.g. `docker-compose` declares `memory = "4G"`, so a
chain including docker-compose ends up at 4G even without this
section).

Format: `<N>` or `<N>G` (the G suffix is tolerated either way).

### `[disk]`

```toml
[disk]
size = "4G"
```

Overrides the disk size that `aq new --size` is given. rlock's
default is `16G` — generous for arbitrary CI workloads (large dep
caches, multiple docker images, build artefacts). Small projects
(single-service compose fixture, tiny codebase, no large images)
benefit from dropping to `4G` or `8G`: the base image is sparse so
the host file is smaller, mkfs runs faster, and CI cache restores
move less data.

Format: `<N>` or `<N>G` (the G suffix is tolerated either way).

### `[prebuild.<name>]`

Declares an additional snapshot layer that runs after all activated
plugins. Each named section becomes its own cache slot — independent
key, independent invalidation, independent re-execution.

```toml
[prebuild.schema-load]
cmd = "docker compose exec app rails db:schema:load"
key_files = ["db/schema.rb"]
strategy = "cached"     # default; can be "incremental"
```

Fields:

| Field        | Required | Notes |
|--------------|----------|-------|
| `cmd`        | yes      | Shell command. Executed inside the VM as the `rlock` user, with login shell (mise + PATH loaded), from `/home/rlock/repo`. Multi-line via TOML triple-quoted strings. |
| `key_files`  | yes      | Array of paths / globs at the project root. Their concatenated content (in declared order) drives the cache key. Empty array is rejected — every cached layer needs an invalidation signal. |
| `strategy`   | no       | `cached` (default) or `incremental`. See "Strategy contract" below. |

Order in `bakerish.toml` source = order in the chain. Each section's
synthesised plugin declares `deps = ["_prebuild-<previous-name>"]`, so
walk_chain executes them sequentially.

Naming: `[prebuild.<name>]` — `<name>` becomes `_prebuild-<name>` as
the synthesised plugin's internal name. The underscore prefix marks
it as framework-internal (hidden from `rl new`'s trigger/CLI surface).

### `[on_start.<name>]`

Declares a command to run on **every** `bake run` after the snapshot
chain has restored. No cache. No `key_files`. Fires regardless of cache
hit/miss.

```toml
[on_start.refresh-jwt]
cmd = "docker compose exec app bin/rails dev:refresh-jwt"
```

Use for:

- Refreshing per-session secrets (JWT tokens, API keys, anything time-
  sensitive that mustn't be cached).
- Generating dev-only fixtures that need to look "new" each run.
- Warming caches in the running stack (e.g. precomputing slow lookups).
- Anything where the inputs aren't fully captured by a file you could
  put in `key_files`.

## Strategy contract

### `cached` (default)

On cache miss, boot the VM from the **parent** layer's qcow2 (= chain
state right before this layer) and run `cmd`. Save the resulting disk.

Contract on `cmd`: deterministic given `key_files` + the parent disk
state. Re-running the same `cmd` on the same parent + same key_files
content must produce the same effective end state.

Good fits: `rails db:schema:load`, `assets:precompile`, anything that's
a pure function of declared inputs.

### `incremental`

On cache miss, boot the VM from the **latest snapshot of this same
plugin** (any key), not the parent. Then run `cmd`. The previous run's
output is the starting state; `cmd` is expected to compute the delta
to current `key_files`.

Contract on `cmd`: **delta-aware** AND **idempotent** when re-run
against any prior state of itself. Must converge to "what the current
`key_files` describe" without manual intervention or full reset.

⚠️ **Critical caveat — what `incremental` does NOT fit:**

Tools that look at *external state* (not the declared `key_files`) to
decide what to do break incremental's invariant.

The canonical example: `rails db:migrate`. It checks the
`schema_migrations` table — not file content — to see what's applied.
If an existing migration file is **edited** (renamed table, dropped
column, changed type) instead of newly **added**, the file content
changes — but `rails db:migrate` against the previous snapshot's DB
sees "20230101 already applied" and does nothing. DB schema silently
diverges from `db/schema.rb`. Silent correctness bug.

Therefore for Rails: `db:migrate` gets `strategy = "cached"` with
`db/migrate` in `key_files`. Any edit forces a fresh schema:load +
migrate from a clean DB.

`incremental` is the right strategy for tools whose install command's
input *is* the lockfile content and that internally reconcile vendor
state to the lockfile:

- `bundle install` ✓
- `npm install` (NOT `npm ci` — `ci` wipes node_modules) ✓
- `pnpm install` ✓
- `uv sync` ✓
- `poetry install` ✓
- `cargo fetch` ✓

The shipped `ruby-bundler` / `npm` / `pnpm` / `uv` / `poetry` /
`cargo` plugins all declare `incremental` for this reason. If you're
writing a `[prebuild.<name>]` step for a tool that doesn't pattern-
match this shape — pick `cached`.

## Lifecycle interaction with the activated plugin chain

`bake run` provisions in this order:

1. Detect activated plugins (by file trigger if no explicit list).
2. Synthesise `_prebuild-*` from bakerish.toml's `[prebuild.<name>]`
   sections — one plugin per section, under
   `<project>/.bakerish/plugins/_prebuild-<name>/`.
3. `rl new <triggered-plugins> <_prebuild-*>` — chain order is:
   triggered plugins (deps resolved), then `_prebuild-*` in source
   order from bakerish.toml.
4. After the chain, run `[on_start.<name>]` cmds in source order via
   the framework's `start` hook.

The synthesised plugins are generated **on every `bake run`** — parse
+ write is millisecond-cheap. No mtime tracking, no cache logic for
the generator itself. If you edit bakerish.toml, the next `bake run`
sees fresh plugin shapes; if `key_files` content moved, snapshot_key
changes and walk_chain re-builds the affected layer.

## Per-ecosystem snippets

### Rails (Postgres via docker-compose)

```toml
[prebuild.schema-load]
cmd = "docker compose exec app rails db:schema:load"
key_files = ["db/schema.rb"]

[prebuild.migrate]
cmd = "docker compose exec app rails db:migrate"
key_files = ["db/schema.rb", "db/migrate"]
# NOT incremental — see "Strategy contract" caveat for the why.

[prebuild.seed]
cmd = "docker compose exec app rails db:seed"
key_files = ["db/seeds.rb"]
```

### Django

```toml
[prebuild.migrate]
cmd = "docker compose exec app python manage.py migrate --no-input"
key_files = ["**/migrations/*.py"]
# Same caveat as Rails — Django tracks applied migrations in
# django_migrations table, not file content. Use cached.

[prebuild.collectstatic]
cmd = "docker compose exec app python manage.py collectstatic --no-input"
key_files = ["**/static/**", "**/templates/**"]
```

### Phoenix / Ecto

```toml
[prebuild.ecto-migrate]
cmd = "docker compose exec app mix ecto.migrate"
key_files = ["priv/repo/migrations"]
```

### Go modules (no docker-compose; mise installs Go)

```toml
[prebuild.go-mod-download]
cmd = "go mod download"
key_files = ["go.sum"]
strategy = "incremental"
# `go mod download` is content-aware against ~/.cache/go-build —
# incremental is safe here.
```

### Custom build step (no docker-compose)

```toml
[prebuild.protoc]
cmd = "buf generate"
key_files = ["buf.yaml", "buf.gen.yaml", "**/*.proto"]
```

## When you outgrow `[prebuild.<name>]`

`[prebuild.<name>]` collapses three patterns into a clean declarative
form. If your workflow needs any of these, write a custom plugin
instead (see `docs/writing-a-plugin.md` for the pattern):

- **Positioning between specific plugins**, not just at chain end.
  E.g. "this step must run before docker-compose's `compose up`."
  Prebuild can't currently interleave (deferred roadmap item).
- **Conditional activation by something other than file presence.**
  Prebuild's `snapshot_should_skip` only checks `key_files` presence;
  for "skip when ENV var X is set" / "skip when git ref matches Y"
  semantics, a custom plugin's `snapshot_should_skip` hook gives you
  arbitrary shell.
- **Custom snapshot_key inputs that aren't just file contents.**
  E.g. hashing the output of a command instead of a file. Custom
  plugin's `snapshot_key` gives you full shell control.
- **Resource isolation per step.** If a step needs distinct memory
  limits or a non-default base image, that's a plugin-level
  declaration (`[snapshot] memory = "8G"`).

## File layout written into the project

After `bake run`, you'll see:

```
<project>/
├── bakerish.toml             ← yours, checked in
├── .bakerish/
│   └── plugins/
│       ├── _prebuild-schema-load/
│       │   ├── plugin.toml
│       │   ├── plugin.sh     ← copy of bakeri.sh/lib/bake-prebuild-template.sh
│       │   ├── cmd.sh        ← verbatim cmd from bakerish.toml
│       │   └── key_files.txt
│       ├── _prebuild-migrate/
│       │   └── …
│       └── _prebuild-seed/
│           └── …
```

`.bakerish/` is generated. Don't edit anything inside — every `bake
run` regenerates from `bakerish.toml`. If you want to gitignore it,
add `.bakerish/` to your project's `.gitignore`; on CI you don't need
to (the runner's filesystem is ephemeral).

## See also

- [design spec](superpowers/specs/2026-05-20-bakerish-toml-and-prebuild.md)
  — full reasoning behind the format choices, especially the strategy
  contract and the `[prebuild.<name>]`-as-one-position constraint.
- `writing-a-plugin.md` — escape hatch when prebuild doesn't fit.
