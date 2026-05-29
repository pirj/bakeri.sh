# Benchmark Walking Skeleton — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap the `snapcompose-benchmark` fixture repo with a Rails monolith service and a minimal `bench-snapcompose.yml` workflow that runs a single cold-cell measurement of the monolith row on GitHub Actions. End state: workflow runs green, records a wall-clock timing for monolith cold, and a placeholder result lands in `snapcompose/README.md`.

**Architecture:** New sibling repo at `~/source/ai.rlock/snapcompose-benchmark/`. One service `services/main/` is a Rails 8 app with `pg`, `redis-rb`, and `puma`, plus a `/health` endpoint that pings both backends. Internal `docker-compose.yml` brings up `app + pg + redis` together. `snapcompose.toml` activates the plugin chain `docker-engine → mise → ruby-bundler → docker-compose`. Workflow uses `pirj/setup-snapcompose@v3`, restores `actions/cache`, runs `rl new monolith`, polls `/health` for HTTP 200, records wall-clock + cache size.

**Tech Stack:** Ruby 4.x via mise, Rails 8 (no JS bundler / no assets in Phase 1), Postgres 16, Redis 7, Docker Compose 2.x, GitHub Actions, snapcompose, setup-snapcompose@v3.

---

## Phase 1 scope (this plan)

Phase 1 produces a runnable end-to-end pipeline with **one row, one mode, one variant** (monolith / cold / single timing). The fixture is real-looking but minimal — no npm + asset precompile yet, no microservices yet. CI is the canonical verification surface; local Docker / rlock are not required.

## Phase 0 — snapcompose features (added 2026-05-29 mid-execution)

The walking skeleton's first three workflow runs surfaced fundamental
gaps in snapcompose itself: it has no automatic CI source-delivery
path, and its plugin chain assumes the snapcompose project IS the git
repo root (no monorepo support). Both must land in snapcompose before
the walking skeleton's fixture (monorepo with `services/main/` as a
subproject) can run green.

See [`2026-05-29-snapcompose-monorepo-and-ci-auto-push.md`](2026-05-29-snapcompose-monorepo-and-ci-auto-push.md)
for the spec + plan. Three features land together:

- **F1 — subdir-as-project**: `snapcompose.toml` may live in a
  subdirectory of the git repo. Plugins inside the VM cd to the
  matching subdirectory of `/home/rlock/repo` before doing their
  work.
- **F2 — auto-push at cache-miss boundary**: snapc-run sets up the
  `rl` git remote automatically and pushes HEAD only when an
  upstream layer that needs source has a cache miss. Full warm runs
  skip the push.
- **F3 — drop redundant scp from docker-compose plugin**: once F2
  delivers source, the plugin doesn't need to scp Dockerfile +
  compose separately.

After F1+F2+F3 land and a new snapcompose tag is cut, this plan
resumes at Task 7 (the workflow already exists; only the fixture
layout needs to be reverted to the monorepo shape with `services/main/`
as the snapproject).

## Follow-up phases (separate plans, not in this plan)

- **Phase 2:** Add npm + asset precompile to main service. Match spec fidelity.
- **Phase 3:** Add five microservices (Node, Python, Go, Sinatra, Python-alt).
- **Phase 4:** Per-row `snapcompose.toml` configs (`+1` / `+3` / `+5`).
- **Phase 5:** Expand workflow to the full par/seq × cold/warm/wfp matrix.
- **Phase 6:** `bench-docker.yml` baseline workflow.
- **Phase 7:** First measurement pass + populate `snapcompose/README.md` tables.

---

## Task 1: Bootstrap `snapcompose-benchmark` repo

**Files:**
- Create: `/Users/pirj/source/ai.rlock/snapcompose-benchmark/README.md`
- Create: `/Users/pirj/source/ai.rlock/snapcompose-benchmark/.gitignore`

- [ ] **Step 1.1: Create directory and init git**

Run:
```bash
mkdir -p /Users/pirj/source/ai.rlock/snapcompose-benchmark
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark init -b main
```

Expected: an empty git repo on branch `main`.

- [ ] **Step 1.2: Write README**

Path: `/Users/pirj/source/ai.rlock/snapcompose-benchmark/README.md`

Content:
```markdown
# snapcompose-benchmark

Fixture repository for the snapcompose multi-microservice benchmark.

Contents (planned):
- Six service codebases (`services/main`, `services/node`, ...)
- Six Dockerfiles
- Per-row `snapcompose.toml` configs
- Two GH Actions workflows (`bench-snapcompose.yml`, `bench-docker.yml`) — `workflow_dispatch` only

Phase 1 of the fixture is monolith-only. The rest comes in follow-up phases — see snapcompose's plan dir for the roadmap.

Methodology and result tables live in [pirj/snapcompose](https://github.com/pirj/snapcompose):
- Methodology: [docs/bench/2026-05-29-microservices-benchmark.md](https://github.com/pirj/snapcompose/blob/main/docs/bench/2026-05-29-microservices-benchmark.md)
- Headline tables: snapcompose `README.md`

This repo is only the fixture and the runners.
```

- [ ] **Step 1.3: Write .gitignore**

Path: `/Users/pirj/source/ai.rlock/snapcompose-benchmark/.gitignore`

Content:
```
.DS_Store
node_modules/
.bundle/
vendor/bundle/
log/
tmp/
.env
.env.local
*.swp
.aq/
.snapcompose/
services/*/storage/
```

- [ ] **Step 1.4: Initial commit**

Run:
```bash
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark add README.md .gitignore
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark commit -m "init benchmark fixture repo"
```

---

## Task 2: Scaffold Rails main service

Rails 8 generates ~30 standard files; this task uses `rails new` to produce them and then customizes the small surface we care about.

**Files (key ones; the rest are stock `rails new` output):**
- Create: `services/main/Gemfile`
- Modify: `services/main/config/database.yml`
- Create: `services/main/app/controllers/health_controller.rb`
- Modify: `services/main/config/routes.rb`

- [ ] **Step 2.1: Install Rails CLI**

Ruby 4.x is already on `PATH` (`/opt/homebrew/opt/ruby/bin/ruby`). Install Rails:

```bash
gem install rails --no-document
```

Expected: `rails -v` prints `Rails 8.x`.

- [ ] **Step 2.2: Generate Rails app**

```bash
cd /Users/pirj/source/ai.rlock/snapcompose-benchmark
rails new services/main \
  --database=postgresql \
  --skip-test \
  --skip-system-test \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-active-storage \
  --skip-action-cable \
  --skip-javascript \
  --skip-asset-pipeline \
  --skip-hotwire \
  --skip-jbuilder \
  --skip-bootsnap \
  --skip-git \
  --skip-keeps \
  --skip-decrypted-diffs
```

Expected: `services/main/` directory tree with a working Rails 8 skeleton; `services/main/bin/rails` is executable.

- [ ] **Step 2.3: Append `redis` gem to Gemfile**

In `services/main/Gemfile`, add after the existing `# Use Redis adapter to run Action Cable in production` block (or near the bottom):

```ruby
gem "redis", "~> 5.4"
```

Then run:

```bash
cd /Users/pirj/source/ai.rlock/snapcompose-benchmark/services/main
bundle install
```

Expected: `Gemfile.lock` updated; bundle install completes.

- [ ] **Step 2.4: Rewrite `config/database.yml` for fixed dev/prod DB names**

Replace `services/main/config/database.yml` with:

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  host: <%= ENV.fetch("DATABASE_HOST") { "db" } %>
  port: <%= ENV.fetch("DATABASE_PORT") { 5432 } %>
  username: <%= ENV.fetch("DATABASE_USER") { "postgres" } %>
  password: <%= ENV.fetch("DATABASE_PASSWORD") { "postgres" } %>

development:
  <<: *default
  database: bench_main_development

test:
  <<: *default
  database: bench_main_test

production:
  <<: *default
  database: <%= ENV.fetch("DATABASE_NAME") { "bench_main" } %>
```

- [ ] **Step 2.5: Add `/health` controller**

Create `services/main/app/controllers/health_controller.rb`:

```ruby
class HealthController < ApplicationController
  def show
    pg_ok = ActiveRecord::Base.connection.execute("SELECT 1").first["?column?"] == 1
    redis_ok = redis_client.ping == "PONG"
    if pg_ok && redis_ok
      render json: { status: "ok", pg: true, redis: true }
    else
      render json: { status: "degraded", pg: pg_ok, redis: redis_ok }, status: :service_unavailable
    end
  rescue => e
    render json: { status: "error", error: e.class.name, message: e.message }, status: :service_unavailable
  end

  private

  def redis_client
    @redis_client ||= Redis.new(
      host: ENV.fetch("REDIS_HOST", "redis"),
      port: ENV.fetch("REDIS_PORT", "6379").to_i,
    )
  end
end
```

- [ ] **Step 2.6: Route `/health` to the controller**

Edit `services/main/config/routes.rb`. Replace the body of `Rails.application.routes.draw do … end` with:

```ruby
Rails.application.routes.draw do
  get "/health", to: "health#show"
  root "health#show"
end
```

- [ ] **Step 2.7: Commit the scaffolded service**

```bash
cd /Users/pirj/source/ai.rlock/snapcompose-benchmark
git add services/main Gemfile* .gitignore 2>/dev/null; true
git add services/main
git commit -m "add monolith main service (Rails 8 + pg + redis + /health)"
```

Expected: one commit containing the `services/main/` tree.

---

## Task 3: Dockerfile for main service

**Files:**
- Create: `services/main/Dockerfile`
- Create: `services/main/.dockerignore`

- [ ] **Step 3.1: Write `services/main/Dockerfile`**

Multi-stage Dockerfile for Rails:

```dockerfile
# syntax=docker/dockerfile:1.7

FROM ruby:3.4-slim AS base
ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV=production
WORKDIR /app
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential libpq-dev libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

FROM base AS deps
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

FROM base AS app
COPY --from=deps /usr/local/bundle /usr/local/bundle
COPY . .
ENV PORT=3000
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

Note: this is `ruby:3.4-slim`, not `:4.x`. Phase 2 will move to a mise-managed Ruby once Rails 8 + Ruby 4 compatibility is confirmed; for Phase 1 the published ruby:3.4-slim image is the safe path.

- [ ] **Step 3.2: Write `services/main/.dockerignore`**

```
.git
.gitignore
.bundle
log
tmp
storage
node_modules
*.log
```

- [ ] **Step 3.3: Commit**

```bash
cd /Users/pirj/source/ai.rlock/snapcompose-benchmark
git add services/main/Dockerfile services/main/.dockerignore
git commit -m "main: Dockerfile + dockerignore"
```

---

## Task 4: docker-compose.yml for monolith row

**Files:**
- Create: `compose/monolith.yml`

- [ ] **Step 4.1: Write `compose/monolith.yml`**

```yaml
services:
  app:
    build:
      context: ../services/main
    environment:
      RAILS_ENV: production
      RAILS_MASTER_KEY: dummy_phase1_not_used
      DATABASE_HOST: db
      DATABASE_USER: postgres
      DATABASE_PASSWORD: postgres
      DATABASE_NAME: bench_main
      REDIS_HOST: redis
    ports:
      - "3001:3000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:3000/health || exit 1"]
      interval: 2s
      timeout: 3s
      retries: 30

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: bench_main
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      timeout: 3s
      retries: 30

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 30
```

Notes:
- `RAILS_MASTER_KEY` is a dummy placeholder for Phase 1; Rails refuses to boot in production without one. The benchmark never reads secrets, so the value is irrelevant.
- Host port `3001` per the spec's port allocation table.
- The compose file lives under `compose/` so per-row variants (`compose/+1.yml`, etc.) can sit alongside it in later phases.

- [ ] **Step 4.2: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark add compose/monolith.yml
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark commit -m "compose: monolith row (app + pg + redis)"
```

---

## Task 5: `snapcompose.toml` for monolith row

**Files:**
- Create: `snapcompose.monolith.toml`

- [ ] **Step 5.1: Write `snapcompose.monolith.toml`**

```toml
protocol_version = 1

[memory]
size = "4G"

[prebuild.mise]
# uses .tool-versions / .ruby-version from services/main if present

[prebuild.ruby-bundler]
gemfile = "services/main/Gemfile"

[prebuild.docker-compose]
file = "compose/monolith.yml"
```

The plugin chain `mise → ruby-bundler → docker-compose` is what produces the layered snapshot. `docker-engine` is implicit (a base plugin snapcompose always activates when `docker-compose` is in the chain).

- [ ] **Step 5.2: Add `services/main/.ruby-version`**

```
3.4.5
```

(or the latest 3.4.x at the time of running — mise will pick it up.)

- [ ] **Step 5.3: Commit**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark add snapcompose.monolith.toml services/main/.ruby-version
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark commit -m "snapcompose: monolith row config"
```

---

## Task 6: GitHub remote + push

- [ ] **Step 6.1: Create GitHub repo**

```bash
gh repo create pirj/snapcompose-benchmark \
  --public \
  --description "Fixture and workflow runners for the snapcompose multi-microservice benchmark." \
  --source /Users/pirj/source/ai.rlock/snapcompose-benchmark \
  --remote origin \
  --push
```

Expected: repo created at `https://github.com/pirj/snapcompose-benchmark`, local `main` pushed.

If `gh repo create` errors because the repo already exists, fall back to:
```bash
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark remote add origin git@github.com:pirj/snapcompose-benchmark.git
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark push -u origin main
```

---

## Task 7: Minimal `bench-snapcompose.yml` workflow

**Files:**
- Create: `.github/workflows/bench-snapcompose.yml`

- [ ] **Step 7.1: Write the workflow**

Path: `/Users/pirj/source/ai.rlock/snapcompose-benchmark/.github/workflows/bench-snapcompose.yml`

```yaml
name: bench-snapcompose

on:
  workflow_dispatch:
    inputs:
      row:
        description: Row to benchmark
        type: choice
        options: [monolith]
        default: monolith
      mode:
        description: Cache mode
        type: choice
        options: [cold]
        default: cold

jobs:
  bench:
    name: ${{ inputs.row }} / ${{ inputs.mode }}
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v5

      - name: Install snapcompose
        uses: pirj/setup-snapcompose@v3
        with:
          cache-key: bench-snapcompose-${{ inputs.row }}-${{ github.sha }}
          # On cold we deliberately bypass any restore.
          restore-only: false
          skip-cache-restore: ${{ inputs.mode == 'cold' }}

      - name: Run rl new with the row's snapcompose.toml
        id: run
        env:
          SNAPCOMPOSE_CONFIG: snapcompose.${{ inputs.row }}.toml
        run: |
          set -euo pipefail
          export SNAPCOMPOSE_CONFIG
          start=$(date +%s)
          rl new bench --plugin-config "${SNAPCOMPOSE_CONFIG}"
          end=$(date +%s)
          elapsed=$((end - start))
          echo "rl_new_seconds=${elapsed}" >> "${GITHUB_OUTPUT}"
          echo "rl new ${elapsed}s"

      - name: Wait for /health on main
        id: ready
        run: |
          set -euo pipefail
          deadline=$(($(date +%s) + 180))
          start=$(date +%s)
          until curl -sf http://localhost:3001/health > /dev/null; do
            if (( $(date +%s) > deadline )); then
              echo "::error::/health never returned 200 within 180s"
              exit 1
            fi
            sleep 1
          done
          end=$(date +%s)
          echo "ready_seconds=$((end - start))" >> "${GITHUB_OUTPUT}"

      - name: Measure cache size
        id: cache_size
        run: |
          cache_dir="${HOME}/.local/share/aq/cache"
          if [[ -d "${cache_dir}" ]]; then
            bytes=$(du -sb "${cache_dir}" | cut -f1)
          else
            bytes=0
          fi
          echo "cache_bytes=${bytes}" >> "${GITHUB_OUTPUT}"

      - name: Summarize
        run: |
          row='${{ inputs.row }}'
          mode='${{ inputs.mode }}'
          rl_new='${{ steps.run.outputs.rl_new_seconds }}'
          ready='${{ steps.ready.outputs.ready_seconds }}'
          total=$(( rl_new + ready ))
          cache='${{ steps.cache_size.outputs.cache_bytes }}'
          {
            echo "### Result"
            echo
            echo "| row | mode | wall-clock (s) | cache size (B) |"
            echo "|---|---|---|---|"
            echo "| ${row} | ${mode} | ${total} | ${cache} |"
          } >> "${GITHUB_STEP_SUMMARY}"
```

Notes for the implementer:
- `pirj/setup-snapcompose@v3` is the published action — see its README for input names. The `skip-cache-restore` input may need to be renamed to whatever the v3 action exposes (e.g. `cache-restore`, `restore`, etc.). If the action lacks a cold-mode toggle, work around it by using a one-time-unique cache key for cold runs (e.g. include `github.run_id` so cache restore always misses).
- `rl new bench --plugin-config <file>` is the assumed CLI shape for picking a non-default `snapcompose.toml`. If the actual flag is named differently (e.g. `--config`, `-c`), swap accordingly; verify by running `rl new --help` once.
- Timing here is wall-clock seconds. The methodology asks for higher resolution (`SECONDS=0 … $SECONDS` gives integer seconds), which is good enough for a walking skeleton; refine later if numbers are too coarse.

- [ ] **Step 7.2: Commit and push**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark add .github/workflows/bench-snapcompose.yml
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark commit -m "ci: minimal bench-snapcompose workflow (monolith cold)"
git -C /Users/pirj/source/ai.rlock/snapcompose-benchmark push
```

---

## Task 8: Trigger the workflow + diagnose

- [ ] **Step 8.1: Run the workflow**

```bash
gh -R pirj/snapcompose-benchmark workflow run bench-snapcompose --field row=monolith --field mode=cold
```

- [ ] **Step 8.2: Watch the run**

```bash
gh -R pirj/snapcompose-benchmark run watch
```

Expected: workflow finishes green; step summary contains a single-row results table with `monolith / cold / <seconds>`.

- [ ] **Step 8.3: If it fails, diagnose**

Common failure modes and fixes:
- `gem install rails` not on the runner: Phase 1 doesn't run rails on the runner — Rails only runs inside the container during the docker-compose build. If errors mention Ruby/Rails outside the container, re-check Dockerfile.
- `setup-snapcompose@v3` input mismatch: read the action's README and adjust input names.
- `rl new --plugin-config` flag unknown: replace with the correct flag (see `rl new --help`).
- `/health` returns 503 with `pg: false` or `redis: false`: dependencies in docker-compose aren't reaching healthy state inside the 180s budget. Check `docker logs` of the failing container by adding `docker compose logs --tail=200` to the workflow on failure.
- Container fails to start because of missing `RAILS_MASTER_KEY`: ensure the env var is set as in `compose/monolith.yml`.

No retry loop in this plan — diagnose, fix, re-run.

---

## Task 9: Wire placeholder result into `snapcompose/README.md`

**Files:**
- Modify: `/Users/pirj/source/ai.rlock/snapcompose/README.md`

- [ ] **Step 9.1: Insert the benchmark section**

Append the following just after the existing "Design" section (so the top of the README still leads with the install/usage story, but the benchmark is prominent):

```markdown
## Benchmark

Headline performance numbers from the `snapcompose-benchmark` fixture, run on a GitHub Actions `ubuntu-latest` runner.

Methodology: [docs/bench/2026-05-29-microservices-benchmark.md](docs/bench/2026-05-29-microservices-benchmark.md). Workflows: [`snapcompose-benchmark/.github/workflows/`](https://github.com/pirj/snapcompose-benchmark/.github/workflows). Triggered manually before any performance-related release.

### snapcompose

|  | cold | warm | warm-from-patch |
|---|---|---|---|
| monolith | _N s (Phase 1 walking skeleton — single cold timing landed)_ | — | — |
| +1 microservice | — | — | — |
| +3 microservices | — | — | — |
| +5 microservices | — | — | — |

### docker (baseline)

|  | cold | warm | warm-from-patch |
|---|---|---|---|
| monolith | — | — | — |
| +1 microservice | — | — | — |
| +3 microservices | — | — | — |
| +5 microservices | — | — | — |

Cells marked `—` are pending — they get populated as Phases 2–6 of the implementation plan land.
```

Replace `_N s …_` with the actual seconds from the Step 8 run.

- [ ] **Step 9.2: Commit on snapcompose**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose add README.md
git -C /Users/pirj/source/ai.rlock/snapcompose commit -m "README: add benchmark section with Phase 1 monolith cold timing"
```

- [ ] **Step 9.3: Push to snapcompose remote**

```bash
git -C /Users/pirj/source/ai.rlock/snapcompose push
```

(Only push if the user authorizes. If not, leave the commit local for review.)

---

## Spec-coverage self-review (notes for the implementer)

This plan covers only Phase 1 of the spec. After Phase 1 lands, the remaining spec requirements map to follow-up plans:

- **Six services + per-row activation:** Phases 3 + 4.
- **Snapshot layer order with pg+redis below mise:** Phase 1 already places `mise → ruby-bundler → docker-compose` correctly; Phase 3 will explicitly split out a `pg-redis` snapshot strategy so the layer becomes share-able across services. For Phase 1 (one service) the share question doesn't arise.
- **par/seq inline in tables:** Phase 5 (workflow matrix expansion). Phase 1 measures one variant.
- **`zstd --patch-from` warm-from-patch:** Phase 5 (workflow logic). The capability is in snapcompose itself; the workflow just has to opt in.
- **Docker baseline:** Phase 6.
- **Results auto-published to snapcompose README:** Phase 7. Phase 1 only stages the README section so subsequent phases have a place to write.

End of Phase 1 plan.
