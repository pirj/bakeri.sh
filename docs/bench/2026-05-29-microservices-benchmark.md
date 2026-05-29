# Multi-microservice benchmark — Design

**Date:** 2026-05-29
**Target:** snapcompose landing-page headline benchmark
**Status:** Design, pending implementation
**Runner:** GitHub Actions `ubuntu-latest` (4 vCPU / 16 GB RAM / 14 GB SSD)

## Goal

Show that snapcompose handles a complex multi-service project on a free GitHub Actions runner:

1. Up to **six concurrent service VMs** (one main app + five microservices) fit in the runner's RAM, disk, and 10 GB Actions cache.
2. **Warm restore** stays close to the monolith warm number even at the +5 cell — proving that snapshot layering does not pay a per-service tax once the layers exist.
3. **Warm-from-patch** restore (a small code change against a cached snapshot, shipped as a `zstd --patch-from` binary diff) is roughly as fast as warm, with a small fraction of warm's cache footprint.

The headline cell for the README is **(+5 microservices, warm-from-patch)**, contrasted with the same docker-compose cell.

## Service composition

The six-service set is fixed; each row of the table activates a subset.

| # | Stack inside the VM | Why it's in the set |
|---|---|---|
| 1 | Rails + Postgres + Redis + npm (asset precompile) | Main app. Always present. |
| 2 | Node.js + Postgres + Redis | Heterogeneous from #1; no Ruby base sharing. |
| 3 | Python + Postgres + Redis | New language family; no sharing yet. |
| 4 | Go (compiled binary) + Postgres + Redis | No language runtime → no mise/bundler cache help. |
| 5 | Ruby/Sinatra + Postgres + Redis | Shares mise + Ruby + bundler base with #1. |
| 6 | Python (different framework) + Postgres + Redis | Shares mise + Python base with #3. |

Each VM internally runs its app container plus its own dedicated Postgres and Redis via `docker compose`. Datastores stay inside the VM; they are not exposed on the host.

Row → active services:

| Row | Services | Heterogeneity / sharing |
|---|---|---|
| `monolith` | {1} | n/a |
| `+1 microservice` | {1, 2} | maximum heterogeneity (Rails + Node) |
| `+3 microservices` | {1, 2, 3, 4} | four distinct stacks; no Ruby or Python re-use yet |
| `+5 microservices` | {1, 2, 3, 4, 5, 6} | sharing activates: #5 reuses Ruby base from #1, #6 reuses Python base from #3 |

The progression is deliberate: docker-engine and pg+redis are shared by every row, but +1 and +3 each *add* a new language family (Node, then Python and Go) whose mise + deps layers are net-new. +5 demonstrates that the next two services (Sinatra and Python-alt) land almost free — their language bases are already in cache from #1 and #3.

## Topology

Star. The main app (#1) calls each downstream service over its forwarded host port. There is no traffic between services 2–6.

Each downstream answers one HTTP route (`/health`). Main calls each downstream's `/health` on startup as part of its own `/health`. Enough realism for a "really ready" signal, no synthetic load.

## Snapshot layer order

Shared layers go deeper. Postgres and Redis are in every VM, so they sit below mise (which only five of the six services need — Go skips it). Per-language deps and per-service code branch off at the leaf:

```
aq base
└─ docker-engine               (shared by all 6)
   └─ pg+redis (empty)         (shared by all 6)
      └─ mise                  (shared by 5; Go branches here)
         └─ per-language deps  (Ruby↔#1+#5, Python↔#3+#6, Node↔#2, Go-only↔#4)
            └─ per-service code + migrations
```

The Go service's chain forks at `pg+redis` and goes straight to its own `go build` step, skipping mise entirely. The Ruby pair (#1 main, #5 Sinatra) and the Python pair (#3, #6) each share the mise + base-language layer and diverge only at the bundler / pip layer.

This ordering is what `snapcompose.toml` of the fixture encodes. Verifying that the layering matches the diagram is part of the fixture's test suite.

## Port allocation

Predictable, derived from service index:

| Service | Host port |
|---|---|
| #1 main | 3001 |
| #2 Node | 3002 |
| #3 Python | 3003 |
| #4 Go | 3004 |
| #5 Sinatra | 3005 |
| #6 Python-alt | 3006 |

Postgres and Redis run inside each VM and are not exposed on the host.

## Measured cells

Two tables, identical shape. Every multi-VM cell is split into two sub-measurements: `par` (all VMs started concurrently with `rl new` / `docker compose up` of all services) and `seq` (one VM started, polled to ready, then the next). Monolith has only one VM so the distinction does not apply.

Each sub-measurement reports `<median wall-clock> ± <spread> (<cache size>)`. N ≥ 3 runs per sub-measurement.

### snapcompose

|  | cold | warm | warm-from-patch |
|---|---|---|---|
| monolith | … | … | … |
| +1 microservice | par …<br>seq … | par …<br>seq … | par …<br>seq … |
| +3 microservices | par …<br>seq … | par …<br>seq … | par …<br>seq … |
| +5 microservices | par …<br>seq … | par …<br>seq … | par …<br>seq … |

### docker (baseline)

|  | cold | warm | warm-from-patch |
|---|---|---|---|
| monolith | … | … | … |
| +1 microservice | par …<br>seq … | par …<br>seq … | par …<br>seq … |
| +3 microservices | par …<br>seq … | par …<br>seq … | par …<br>seq … |
| +5 microservices | par …<br>seq … | par …<br>seq … | par …<br>seq … |

Sequential variants exist for both stacks. For docker the sequential variant is `docker compose up -d svc1 && wait_healthy svc1 && docker compose up -d svc2 && wait_healthy svc2 && …`; the parallel variant is `docker compose up -d <all-services>` (compose starts services concurrently when there are no `depends_on` constraints).

If a cell trips a runner cap, it is reported as `✗ <cap>` with a footnote. That is itself a data point.

### Note on the flat docker warm-from-patch column

Docker has image-layer caching but no live memory snapshot. The cache hit between `cold` and `warm` skips pull and Dockerfile build, but every "warm" start still cold-boots every process (Postgres init, Redis init, app start). The `warm` → `warm-from-patch` delta is small for docker because docker has no equivalent of `zstd --patch-from` — its reuse granularity is one layer.

Reporting all three columns for docker is deliberate: the small `warm` → `warm-from-patch` delta on the docker side, contrasted with the small overhead on the snapcompose side too (where the cache contains a tiny patch instead of a duplicate snapshot), tells the storage story.

## Definitions

**cold** — empty cache. First `actions/cache` miss; build the snapshot chain (or, for docker, pull and build images) from scratch.

**warm** — cache hit on the previous run's snapshot chain. No code change since the cached snapshot. Restore is byte-equivalent.

**warm-from-patch** — cache hit on a *previous* snapshot, with a single small code change applied since.

- For **snapcompose**: the new snapshot is stored as `zstd --patch-from=<cached-snapshot> <new-snapshot>`. The cache holds the cached base plus a small binary patch. Restore = decompress base + apply patch.
- For **docker baseline**: layer cache hit on every preceding layer; the final `COPY` invalidates and rebuilds with the code change. Docker has no equivalent of a byte-level zstd patch; its reuse granularity is one layer. The wall-clock comparison is honest; the cache-size column shows snapcompose's storage win.

**ready** — the orchestrator polls `http://localhost:3001/health` on the main app. Main's `/health` itself calls each active downstream's `/health` and returns 200 only when every downstream returns 200. The cell timer stops at the first 200.

**sequential vs parallel `rl new`:**

- **monolith** — one service, the par/seq distinction does not apply. Cells report a single number.
- **+1 / +3 / +5** — both variants are measured.
  - `par`: all N services launched concurrently with `rl new <name-1> & rl new <name-2> & … wait`. Clock stops at the last-ready service. This is the real-world developer experience.
  - `seq`: each `rl new` issued only after the previous service is ready. Clock stops at the same last-ready point. This isolates the per-VM cost from CPU/IO contention.
- For **docker baseline**, par is `docker compose up -d <all-services>` (compose starts services concurrently when no `depends_on` chain forces ordering); seq is one-at-a-time `docker compose up -d svcN && wait_healthy svcN` then next.

**The code change for warm-from-patch:** one one-line edit in service #1's application code (e.g. a Rails controller). For every row, only service #1 is patched; services 2–6 (where present) are pure warm restore. This reflects the realistic dev cycle ("I touched one service") and produces an honest +5 number that says "in a six-service project, a code change in the main app does not slow restore down because the other five are pure-warm cache hits". The exact file and patch are committed to the fixture and pinned by SHA.

A stress-test variant (patch every activated service) is interesting but not part of this benchmark — it would belong in a separate "patch fan-out" measurement.

## Methodology

- N ≥ 3 runs per cell. Report **median** and **spread** (max − min). Outliers above 2× the median are flagged in a footnote, not silently dropped.
- One **runner instance per measurement**: each of the N runs of each cell uses a fresh `ubuntu-latest` runner so timings are not biased by warm host state.
- **Cache key shape:** one key per row (e.g. `bench-snapcompose-+3-<fixture-sha>`). The cold cell of a row populates it; warm and warm-from-patch cells of the same row restore from it. Warm-from-patch writes back an updated cache containing base + zstd patch; warm writes back the unchanged key (no-op on hit). This means cells within a row are *ordered* (cold → warm → warm-from-patch) but cells across rows are fully independent. Docker baseline mirrors this with one `actions/cache` key per docker row covering `~/.docker` + buildx cache.
- Cache size is measured post-`actions/cache save`, as the size GitHub records (i.e. server-side compressed if applicable).
- Wall-clock is measured inside the workflow with a step-scoped timer (`SECONDS=0` … `echo $SECONDS`), starting just before `rl new` (or `docker compose up`) and stopping when the orchestrator's HTTP probe returns 200.
- The fixture repo is pinned to a Git SHA per benchmark run; the run records the SHA alongside its result.

## GitHub Actions runner caps to watch

| Cap | Limit | Risk and mitigation |
|---|---|---|
| RAM | 16 GB total; ~7 GB usable after system + docker daemon | Six VMs at `aq -m 1G` = 6 GB. Plus host docker for docker baseline. The +5 row may need `aq -m 768M` per VM; if so, document and apply the same downsizing to the docker baseline (compose `mem_limit`) for fairness. |
| Disk | 14 GB SSD | Snapshot chain + actions/cache extraction tarball + docker layer cache during build. Cold +5 is the highest-risk cell. If it fails, switch fixture services to alpine-based images and document. |
| CPU | 4 vCPU | Six parallel boots contend during decompress + kernel init. The par-vs-seq delta in the +5 row of each table measures exactly this contention. |
| Actions cache | 10 GB per repo | All snapshot chains in one cache key. The +5 cell's cache size column must come in under 10 GB; if it doesn't, the docs say so and we sell that as a deliberate boundary (one project, one cache; spillover means split keys). |

Cap-trips are reported in the table, not papered over.

## What this benchmark deliberately does NOT measure

- Cross-machine cache transport overhead — covered by `setup-snapcompose` validation runs.
- OCI registry-backed cache transport — separate benchmark when it stabilises.
- Inter-service request latency under load — only readiness time.
- Failure recovery semantics.
- Local-developer machine performance — landing-page story is the GH Actions number; the local-laptop story belongs in a different doc.

## Where the result lands

- The two full tables go into `snapcompose/README.md` as the landing-page headline benchmark, alongside a one-sentence summary of the (+5 microservices, warm-from-patch) cell.
- Per-cell raw timings, fixture SHA, GH Actions run links, and any cap-trip notes go in `snapcompose/docs/bench/2026-MM-DD-results.md` (one file per benchmark pass, dated).
- This design doc stays as the methodology reference and does not change between runs unless the methodology itself changes.

## Fixture repo

A single GitHub repo `snapcompose-benchmark` holds the six-service codebase, the six Dockerfiles, and one `snapcompose.toml` per row. Workflows live in `.github/workflows/`:

- `bench-snapcompose.yml` — for each `+N` row, measures par and seq across cold / warm / warm-from-patch. Monolith measures one variant per mode. 21 cells per pass.
- `bench-docker.yml` — same shape against `docker compose`. 21 cells per pass.

Both workflows are **manual-dispatch only** (`workflow_dispatch`). They accept `row` and `mode` as inputs so individual cells can be re-run.

## When to run

Performance-related releases of `aq`, `rlock`, or `snapcompose` must run this benchmark and update the results in `snapcompose/README.md` before the release tag is cut. The CLAUDE.md of each repo notes this convention.

A "performance-related" change is anything that could shift cold / warm / warm-from-patch timings: aq's QEMU pin or snapshot format, rlock's plugin protocol or layer orchestration, snapcompose's plugin set or snapcompose.toml semantics, the kernel or initramfs build.
