# GitHub Actions CI integration

bakeri.sh's headline use case is GitHub Actions. The pattern in this
doc gets you from "no CI" to "second-run sub-second-warm CI" by
copy-pasting one workflow file and adapting the test command.

## TL;DR

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pirj/setup-bakerish@v2
      - run: bake run -- bundle exec rspec
```

`pirj/setup-bakerish@v2` is a composite action that does the install
(qemu + ovmf + tio + aq/rlock/bakeri.sh) + cache restore + auto-save
in one step. See its
[README](https://github.com/pirj/setup-bakerish) for inputs (cache
key segmentation, `AQ_NO_SNAPSHOT_COMPRESS=1`, ref pinning, etc.).

For the expanded inline form (when you need to customize a step or
audit what runs under the hood), see
[`docs/example-bakerish-ci.yml`](example-bakerish-ci.yml) — it
ships both the packaged form and the unrolled equivalent side by
side. Don't roll your own host-deps install: at minimum you need
`qemu-system-x86 qemu-utils ovmf socat wget zstd` plus a
source-built tio ≥ 3.8 (Ubuntu 24.04 LTS ships tio 2.5).

## Why this works fast

- **`actions/cache` carries the snapshot layers between runs.** The
  cache dir `~/.local/share/aq/cache` holds one qcow2 per
  `(plugin, snapshot_key)` slot. Restoring it on the next run means
  walk_chain's lookups all hit cache and rebases skip the work.
- **Partial restore via `restore-keys`** is safe — the framework
  re-checks each layer's `snapshot_key` independently. If the cached
  tarball is from a prior commit and some layers' inputs have
  changed, only those layers rebuild; the rest stay warm.
- **Live restore** (the `docker-compose` `kind = "live"` layer) means
  even the warm path doesn't re-run `compose up` — the VM resumes
  mid-flight from the cached `memory.bin.zst`. Measured at ~1.3 s on
  the rails-pg-sample fixture.
- **zstd-compressed memory dumps** cut cache size ~3.5× for live
  layers. A typical 4 GiB-RAM live capture goes from 1.6 GiB on disk
  to ~470 MiB — matters because GH Actions' cache quota is 10 GB per
  repo.

## Cache size budget

GH Actions caches:
- **10 GB total per repo** (free tier; can be raised on Enterprise).
- **7 days of no-use** triggers eviction.

After one cold run on a typical Rails+PG project, expect ~2.5 GB in
the cache:

| Layer            | Disk |
|------------------|------|
| `_base`          | ~160 MB |
| `git`            | ~170 MB |
| `docker-engine`  | ~480 MB |
| `docker-compose` | ~1.8 GB (includes the 470 MB zstd-compressed memory.bin.zst) |
| **Total**        | ~2.6 GB |

Plus the per-size base image at `~/.local/share/aq/x86_64/`
(~50–80 MB built lazily).

For multi-project monorepos where the same chain plays out per app,
total stays under quota easily. For matrix-sharded jobs, each shard
reuses the same cache key — no multiplication.

## Matrix sharding

```yaml
strategy:
  matrix:
    shard: [1, 2, 3, 4]
steps:
  - uses: actions/checkout@v4
  - … (install + cache restore — same as TL;DR) …
  - run: bake run -- bundle exec rspec --shard=${{ matrix.shard }}/4
```

Each shard is a separate GH runner = separate filesystem = separate VM.
The cache is shared (same key per shard since it derives from the
same input files), restored independently on each runner. With four
shards, you get four parallel warm-restores at ~2.7 s each = four
ready-to-run VMs in 2.7 s wall-clock.

## Running multiple commands in one job

Multiple `bake run` invocations in the same job reuse the same VM —
each `bake run` is a sub-second SSH exec after the first:

```yaml
- run: bake run -- bundle exec rspec
- run: bake run -- bundle exec rubocop
- run: bake run -- npm run lint
```

No teardown between them. Each command's exit code propagates as the
step's exit code; failing one fails the job per GH Actions semantics.

If two commands genuinely conflict on shared state (e.g. both mutate
the DB) and you don't want them serialised, use `--vm-suffix=<tag>`
to give them independent VMs in the same job:

```yaml
- run: |
    bake run --vm-suffix=lint -- rubocop &
    bake run --vm-suffix=test -- bundle exec rspec &
    wait
```

Each suffixed VM (`<project-basename>-lint`, `<project-basename>-test`)
gets its own state and snapshot cache slot. The cache RESTORE step
above still seeds both — they share `~/.local/share/aq/cache/` (which
keys by `(plugin, snapshot_key)`, not by VM name).

Caveat for local mixed-suffix use: bake-run reconfigures the `rl`
git remote on every `rl new`, so if you alternate `bake run
--vm-suffix=A` and `bake run --vm-suffix=B` from the same project
dir, the rl remote points at whichever VM was last provisioned. The
push step inside bake-run may go to the wrong VM. On CI this is a
non-issue (each shard's runner has its own filesystem).

## Two-tier cache (GH cache + OCI fallback)

GH Actions cache has a **10 GB / repo** quota and **7-day inactivity
eviction**. For multi-project orgs or repos with high churn, that's
limiting. OCI registries (GHCR, ECR, ...) have neither limit.

Use OCI as a **second-tier backstop**: GH cache primary (fast,
ephemeral), OCI fallback when the GH cache evicts or misses.

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: pirj/setup-bakerish@v2
    with:
      oci-cache-ref: ghcr.io/${{ github.repository_owner }}/bakerish-cache:latest
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  - run: bake run -- bundle exec rspec

  # Push on main only — avoid per-PR-commit churn in the long-term store.
  - name: Push cache to OCI (main only)
    if: always() && github.ref == 'refs/heads/main'
    run: bake cache --push ghcr.io/${{ github.repository_owner }}/bakerish-cache:latest
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

`bake cache --push` is **per-layer**: each `(plugin, snapshot_key)`
slot becomes its own blob in the OCI artifact. Identical slot
content across pushes dedups server-side by sha256, so an unchanged
`_base` / `docker-engine` / `ruby-bundler` slot doesn't re-upload —
only the changed layer (e.g. updated `db/migrate/` re-runs
`rails db:migrate`) actually transfers bytes.

Active PR with 10 commits each touching one migration: ~50 MB
upload per push, not 2.6 GB.

**GHCR auth** is via `GITHUB_TOKEN`. Workflow permissions must
include `packages: write` for push, `packages: read` for pull-only
jobs.

**Cache TTL**: GHCR has no automatic eviction — blobs persist until
deleted. Run a periodic GC job (`bake cache --gc <ref>` — TBD
roadmap) to prune stale layer manifests; or rely on registry-side
lifecycle policies when the provider supports them (ECR does, GHCR
doesn't yet).

## Cold first-run wall-clock

First CI run on a fresh cache key: expect the cold path's full
duration (≈250 s on the rails-pg-sample fixture). This is unavoidable
— the docker-compose layer needs to `docker pull` postgres + build
your app image + `compose up` + capture the live memory dump. After
that, every run on the same cache key is warm (~2.7 s + your test's
own runtime).

If the cold time is a concern in early adoption, two levers (both
roadmap):

- **OCI registry cache transport** (instead of `actions/cache`):
  chunk-level, cross-repo, no 10 GB limit. Useful when many repos
  share a cache namespace.
- **`docker-registry-cache` plugin**: host-side Docker pull-through
  cache. Saves ~60 s of `docker pull` on first cold per host. On CI
  this is "first cold per cache miss" — not a perfect fit (the runner
  is destroyed after the job), but a CI runner that lives long enough
  to serve multiple jobs (self-hosted runners with persistent
  storage) would benefit.

## Self-hosted runners

bakeri.sh works on self-hosted runners with no extra setup, provided
the host has qemu + KVM and zstd installed (typically the case on
modern Linux distros). The cache dir `~/.local/share/aq/cache`
persists across jobs naturally if the runner is configured with
persistent storage, removing the need for `actions/cache` round-trip
entirely for repeated jobs on the same runner.

This is the sweet spot for high-volume CI: self-hosted runners get
both the warm-snapshot win AND the no-network-cache-fetch win.

## macOS runners

bakeri.sh works on macOS runners too (`runs-on: macos-latest`), but:

- HVF acceleration on Apple Silicon runners (`macos-14`) needs the
  QEMU 11.0.0 HVF live-restore workaround currently active in aq
  (pinned to QEMU 10.0.3 until upstream's 11.1.0 ships). See aq's
  ROADMAP for the current status.
- macOS runners cost ~5× as much per minute as Linux runners under
  GH Actions billing. For commodity CI, Linux is the right choice.

## Troubleshooting

### "qemu: KVM not supported"

The runner doesn't have `/dev/kvm`. Verify with `ls -la /dev/kvm` —
on `ubuntu-latest` this should exist and be world-rw. If you're on a
self-hosted runner, install kvm and add the runner user to the
`kvm` group.

### Cache always misses

Check the `hashFiles(...)` glob list against your project's actual
file layout. If `Gemfile.lock` is in a sub-directory you didn't
include, every lockfile bump invalidates the cache for the wrong
reason. Use `**/Gemfile.lock` for monorepos.

### `bake run` times out on first run

First cold runs through the full snapshot chain — for a Rails+PG
fixture this is ~4 minutes. If your project is much bigger (heavy
container build, many dep installers), it could be longer. GH
Actions' default job timeout is 6 hours, so this isn't a hard limit
— but bumping `timeout-minutes` on the job to be explicit is good
hygiene.

## See also

- [`bakerish-toml.md`](bakerish-toml.md) — project config format.
- [`writing-a-plugin.md`](writing-a-plugin.md) — escape hatch when
  prebuild doesn't fit.
- `superpowers/specs/2026-05-20-bakerish-toml-and-prebuild.md` —
  design spec.
- bakeri.sh's `TODO.md` "North-star: GitHub Actions CI integration"
  section — roadmap (packaged `setup-bakerish` action, OCI registry
  transport, etc.).
