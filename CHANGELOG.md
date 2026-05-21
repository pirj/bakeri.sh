# Changelog

All notable changes to bakeri.sh — one-liner per change.

## Unreleased

- (nothing pending)

## v0.1.0 — 2026-05-21

Initial public release.

### Distribution plugins
- `mise` (cached cold, tool-version manager).
- `ruby-bundler` / `npm` / `pnpm` / `uv` / `poetry` / `cargo` — dep-installer plugins (incremental cold, `deps = ["mise"]`).
- `docker-engine` (cached cold, host-shared).
- `docker-compose` (cached live, 4G memory, `compose up + healthcheck wait` baked into the snapshot).
- `docker-registry-cache` (cached cold) — host-side pull-through Docker registry mirror (~60 s saved off every cold).

### Project config: `bakerish.toml`
- `[memory]`, `[prebuild.<name>]`, `[on_start.<name>]` sections (TOML-1.0 strict, duplicate-section rejection).
- Synthesiser (`lib/bake-prebuild.sh` + `lib/bake-prebuild-template.sh`) generates one `_prebuild-<name>` plugin per section into `.bakerish/plugins/`.
- Each prebuild step is its own snapshot layer with its own cache slot.
- `[memory] size` wired to `rl new --memory`.

### Commands
- `bake run [--no-push] [--vm-suffix=<tag>] -- <cmd>` — one-shot CI runner; auto-creates VM on first call; pushes HEAD via the `rl` git remote; reuses VM across invocations.
- `bake pr <pr-ref> [--cmd=<cmd>] [--no-isolation]` — runs a GitHub PR / GitLab MR (or local ref under `--no-isolation`) in the project VM. Host-mediated push of the PR head; VM never sees the fork URL.
- `bake cache` — ls / `--rm <plugin>[:<key>]` / `--rebuild <plugin>` / `--push <oci-ref>` / `--pull <oci-ref>`.

### CI integration
- `.github/workflows/example-bakerish-ci.yml` — reference workflow with `actions/cache` choreography.
- Companion action `pirj/setup-bakerish@v1` (separate repo) for one-liner adoption.
- Two-tier cache: `actions/cache` primary, OCI fallback via `bake cache --push/--pull`. Per-layer dedup means active-PR churn uploads ~50 MB per push (the changed slot), not 2.6 GB.

### Documentation
- `docs/bakerish-toml.md` — format reference + per-ecosystem snippets (Rails, Django, Phoenix, Go).
- `docs/writing-a-plugin.md` — escape-hatch guide for cases that outgrow `[prebuild.<name>]`.
- `docs/ci-integration.md` — GH Actions workflow guide (one-liner + inline forms + two-tier cache + matrix sharding + `--vm-suffix`).
- `docs/superpowers/specs/` — design specs.

### Tests
- 125/125 bats (plugin TOML / snapshot_key / snapshot_should_skip × every shipped plugin, bake-run / bake-pr / bake-cache flag parsing + flows, `bake-prebuild` synthesis, OCI push/pull mock, TOML reuse contract).

### Removed
- Per-ecosystem rails-* lifecycle plugins (rails-db-migrations / rails-db-seeds / rails-load-db-schema). Folded into `bakerish.toml [prebuild.<name>]` sections (one-line shims compound forever across ecosystems; the declarative form generalises).
