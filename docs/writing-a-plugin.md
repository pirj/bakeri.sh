# Writing a custom plugin

`[prebuild.<name>]` in `bakerish.toml` covers ~80% of project-specific
build steps with a few lines of TOML. This doc is for the other 20% —
when you need a custom rlock plugin.

## When you actually need a plugin

You need a plugin when `[prebuild.<name>]` can't express what you
want:

- **Interleave between specific plugins.** `[prebuild.*]` lands at the
  end of the chain. A custom plugin can declare `deps = ["mise"]` and
  sort between `mise` and `docker-compose`.
- **Conditional activation beyond file presence.** Prebuild's
  `snapshot_should_skip` only checks if `key_files` globs match. For
  "skip when `$RAILS_ENV=production`" or "skip when git tag matches
  `^prod-`", you need `snapshot_should_skip` with arbitrary shell.
- **Custom snapshot_key inputs.** E.g. hash the output of a command,
  not a file. Or include a constant version pin
  (`printf '%s' 'recipe-v3'`) so you can invalidate the cache without
  touching project files.
- **Per-plugin resource declarations.** Prebuild plugins inherit
  defaults. For `[snapshot] memory = "8G"` or `kind = "live"`, you
  need plugin.toml access.
- **Provision-time setup separate from snapshot layers.** Things that
  shouldn't be cached but also shouldn't run every `bake run` — e.g.
  installing dev-only host packages once per VM provision. Use the
  `provision` hook (runs once, after the chain).

For everything else — stick with `[prebuild.<name>]`.

## Layout

A plugin is a directory containing at minimum `plugin.toml`. With a
`[snapshot]` section, also `plugin.sh` implementing the hooks.

```
my-plugin/
├── plugin.toml
├── plugin.sh                 # only if you have a [snapshot] section or hooks
└── commands/                 # only if you ship CLI commands
    └── my-cmd.sh
```

## Where the plugin dir goes

rlock discovers plugins from every directory on `RLOCK_PLUGIN_PATH`
(colon-separated, like shell `PATH`). Default when unset is
`~/.config/rl/plugins/`. Two practical placements:

- **User-global**: drop your `my-plugin/` into `~/.config/rl/plugins/`.
  Available across every project on this host.
- **Project-local**: drop your `my-plugin/` somewhere in the project
  repo (e.g. `.rl/plugins/my-plugin/`), then prepend that dir to
  `RLOCK_PLUGIN_PATH` in your shell setup or in
  `.envrc` / direnv config. Git-tracked, travels with the project.

bakeri.sh's `bake run` already manages `RLOCK_PLUGIN_PATH` for
synthesised prebuild plugins — if you want to also drop in a custom
plugin per-project, you'll need to extend the env setup yourself
(roadmap: a `[plugins] path = [...]` field in `bakerish.toml`).

## plugin.toml

```toml
description = "Short human-readable description"
protocol_version = "1"
deps = ["mise"]                        # plugins this one needs first
host_deps = ["jq"]                     # host binaries required (rl new fails early if missing)
triggers = ["my-project-marker.toml"]  # auto-prompt user when these files are present
commands = ["my-cmd"]                  # CLI commands this plugin adds (dispatched via `rl my-cmd`)

[snapshot]
strategy = "cached"                    # cached | incremental
kind = "cold"                          # cold | live
memory = "4G"                          # optional; max() across active plugins becomes aq --memory
```

All fields except `description` are optional.

- No `[snapshot]` section → plugin is "lifecycle-only" — it can ship
  `provision` / `start` / `rm` hooks but doesn't participate in the
  snapshot chain.
- No `commands` → no CLI commands. Most plugins fall here.
- No `triggers` → user must list the plugin explicitly on `rl new`.

## plugin.sh — the hooks

`plugin.sh` is invoked as `bash plugin.sh <hook-name> [args...]`. The
canonical bottom of the file:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() { … }
snapshot_key()         { … }
snapshot_build()       { … }
provision()            { … }
start()                { … }
rm()                   { … }

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

The dispatcher pattern at the bottom is what makes the same file
respond to multiple hook names.

### Snapshot hooks (only when `[snapshot]` is declared)

| Hook | Where it runs | Purpose |
|---|---|---|
| `snapshot_should_skip` | host | Print `skip` to stdout to bail out of this layer (no rebase, no boot, no build). Otherwise stay silent. Saves ~5–7 s when the layer has nothing to do for the current project. |
| `snapshot_key` | host | Print a SHA-256 (or any stable hex string) to stdout. The framework uses this as the cache key. Same input → same key → cache hit. |
| `snapshot_build` | host (orchestrates the VM) | Receives `vm_name` as `$1`. Run whatever installation / setup work this layer represents. Framework boots the VM first; you `aq exec` / `aq scp` into it. |

```bash
snapshot_should_skip() {
    [ -f Gemfile.lock ] || echo "skip"
}

snapshot_key() {
    {
        cat Gemfile.lock      2>/dev/null || true
        cat .ruby-version     2>/dev/null || true
        cat .bundler-version  2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'SH'
set -eu
apk add build-base libffi-dev openssl-dev readline-dev yaml-dev zlib-dev

su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
eval "$(mise activate bash)"
cd ~/repo
command -v bundle >/dev/null 2>&1
bundle config set --local path vendor/bundle
bundle install --jobs=4 --retry=3
RLOCK
SH
}
```

That's the `ruby-bundler` plugin verbatim. Use it as your reference
for the dep-installer pattern.

### Lifecycle hooks (with or without `[snapshot]`)

| Hook | Where it runs | Purpose |
|---|---|---|
| `provision` | host | Once per `rl new`, after the snapshot chain finishes. For plugins WITHOUT `[snapshot]` only — lets you do setup that shouldn't be cached. |
| `start` | host | Every `rl new` / `rl ssh`, after the VM is up. Use for ephemeral always-run work (refreshing tokens, starting host-side services, opening tunnels). |
| `rm` | host | On `rl rm`. Tear down anything your plugin set up on the host (kill background processes, drop iptables rules, etc.). |

```bash
start() {
    local vm="$1"
    info "Adding the project's git remote to push code into the VM..."
    git remote add rl "ssh://rlock@localhost:$(get_ssh_port "$vm")/home/rlock/repo" 2>/dev/null || true
}
```

That's a simplified `git` plugin's `start`. Look at
`rlock/plugins/git/plugin.sh` for the full version.

### Helpers available via `${RL_LIB_DIR}/`

`RL_LIB_DIR` is exported by the framework before invoking any plugin
hook. Source what you need:

- `ui.sh` — `info` / `warn` / `success` / `die` / `spinner_start` /
  `spinner_stop` colorised output helpers.
- `util.sh` — `is_vm_running`, `wait_for_ssh`, `get_ssh_port`,
  `resolve_vm_name`, `get_active_plugins`, `save_active_plugins`.
- `toml.sh` — `toml_get`, `toml_get_array`, `toml_get_in_section`,
  `toml_get_array_in_section`, `toml_validate`. Generic TOML reader;
  use it to parse your own config files.
- `snapshot.sh` — only if you want to manage cache slots directly
  (advanced — most plugins don't need this).

### Commands (CLI surface)

If your plugin declares `commands = ["my-cmd"]`, you also need
`commands/my-cmd.sh`. `rl my-cmd <args>` dispatches there.

```bash
# my-plugin/commands/my-cmd.sh
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

vm_name=$(resolve_vm_name) || die "No airlock found in this directory"
info "Doing my custom thing in $vm_name…"
do_ssh "$vm_name" "echo Hello from my-cmd"
```

`dispatch_command` finds commands in two passes: first plugins active
for the current project (per `.rl/plugins`), then any discoverable
plugin. A command-only plugin (`[snapshot]`-less, `triggers = []`,
`commands = ["foo"]`) is reachable via `rl foo` without being
"activated" anywhere.

## Worked example: a custom step that doesn't fit `[prebuild.<name>]`

You want a step that:
- Runs the project's `bin/check-licenses` script.
- Should skip when `vendor/license-cache.json` is fresh (mtime < 7
  days) — file presence isn't enough; we need a real freshness check.
- Should sort right after `ruby-bundler` (gems must be installed
  first) and before any other custom build.

This is outside `[prebuild.<name>]`'s range. Custom plugin:

```toml
# ~/.config/rl/plugins/license-check/plugin.toml
description = "Check gem licenses for forbidden licenses"
protocol_version = "1"
deps = ["ruby-bundler"]
host_deps = []
triggers = ["Gemfile.lock"]    # auto-prompt when project has Ruby

[snapshot]
strategy = "cached"
kind = "cold"
```

```bash
# ~/.config/rl/plugins/license-check/plugin.sh
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    # Real freshness check, not just file presence.
    if [ -f vendor/license-cache.json ]; then
        local age_days
        age_days=$(( ( $(date +%s) - $(stat -f %m vendor/license-cache.json) ) / 86400 ))
        if [ "$age_days" -lt 7 ]; then
            echo "skip"
        fi
    fi
}

snapshot_key() {
    {
        cat Gemfile.lock
        cat config/forbidden-licenses.txt 2>/dev/null || true
        printf 'recipe-v1\n'    # bump to force invalidation
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'SH'
set -eu
su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
eval "$(mise activate bash)"
cd ~/repo
bundle exec bin/check-licenses
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

## Reference plugins

Read these for working examples of each pattern:

- **Cold cached, content-hashed**: `bakeri.sh/plugins/mise/`.
- **Cold cached, constant key (one-shot per host)**:
  `rlock/plugins/_base/`, `rlock/plugins/git/`,
  `bakeri.sh/plugins/docker-engine/`,
  `bakeri.sh/plugins/docker-registry-cache/`.
- **Cold incremental (lockfile-driven)**:
  `bakeri.sh/plugins/ruby-bundler/`, `npm/`, `pnpm/`, `uv/`,
  `poetry/`, `cargo/`.
- **Live kind**: `bakeri.sh/plugins/docker-compose/` — pause + memory
  capture + resume; the `[snapshot] memory = "4G"` declaration; the
  per-service healthcheck wait inside `snapshot_build`.
- **Command-only (no snapshot)**: `bakeri.sh/plugins/bake-run/`,
  `bake-pr/`, `bake-cache/`. `triggers = []`, `commands = [...]`.
- **Provision-only (no snapshot, no command)**: `ai.rlock`'s
  `auth-proxy` (provisioning the in-VM proxy config).

## Testing your plugin

Use bats. The pattern repeated across bakeri.sh's plugins:

```bash
# test/my_plugin.bats
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/my-plugin"
    cd "$BATS_TEST_TMPDIR"
}

@test "snapshot_key changes when Gemfile.lock changes" {
    echo 'a' > Gemfile.lock
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    echo 'b' > Gemfile.lock
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "snapshot_should_skip prints 'skip' when no Gemfile.lock" {
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_should_skip
    assert_success
    assert_output "skip"
}
```

Test hooks at the unit level: invoke `plugin.sh <hook>` with controlled
inputs and assert on outputs. `snapshot_build` is harder to unit-test
since it needs a VM; cover it via integration tests when you have a
fixture.

## See also

- `bakerish-toml.md` — for cases that DO fit `[prebuild.<name>]`,
  start there. This doc is the escape hatch.
- `rlock/docs/superpowers/specs/2026-04-22-plugin-architecture.md` —
  full plugin protocol spec (historical but still accurate on the
  hook contract).
