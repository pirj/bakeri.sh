#!/usr/bin/env bash
#
# bake-cache — manage bakeri.sh's snapshot framework cache.
#
# Usage:
#   rl bake-cache                       # list all cached entries (default)
#   rl bake-cache --rm <plugin>         # remove every entry for a plugin
#   rl bake-cache --rm <plugin>:<key>   # remove one specific entry
#   rl bake-cache --rebuild <plugin>    # drop every entry for plugin + all
#                                       # descendants (whose parent_plugin
#                                       # is <plugin>); next `rl new` rebuilds.
#   rl bake-cache --push <oci-ref>      # push every cache entry as
#                                       # per-layer blobs in one OCI
#                                       # artifact. Identical blobs across
#                                       # pushes are dedup'd server-side
#                                       # by content hash.
#   rl bake-cache --pull <oci-ref>      # pull an OCI artifact and lay
#                                       # the entries back out under
#                                       # $RL_CACHE_DIR.
#
# List output is a table: plugin, key (truncated), kind, size, last-modified.
# Cold entries report disk.qcow2 size. Live entries also include
# memory.bin alongside the disk.
#
# Push / pull require the `oras` CLI on the host (brew install oras /
# apt install oras). Auth to the registry is whatever oras was last
# logged into (`oras login ghcr.io -u <user> -p <token>`).

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

CACHE_DIR="${RL_CACHE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aq/cache}"

# --- subcommand: --rm ------------------------------------------------------
do_rm() {
    local target="$1"
    local plugin="${target%%:*}"
    local key=""
    if [[ "$target" == *:* ]]; then
        key="${target#*:}"
    fi
    [[ -n "$plugin" ]] || { stderr "Usage: rl bake-cache --rm <plugin>[:<key>]"; exit 2; }

    local plugin_dir="$CACHE_DIR/$plugin"
    if [[ ! -d "$plugin_dir" ]]; then
        info "No cache entries for plugin '$plugin'."
        return 0
    fi

    if [[ -n "$key" ]]; then
        local entry="$plugin_dir/$key"
        if [[ ! -d "$entry" ]]; then
            info "No entry '$plugin:$key' in cache."
            return 0
        fi
        rm -rf "$entry"
        # Drop empty plugin dir.
        rmdir "$plugin_dir" 2>/dev/null || true
        info "Removed $plugin:$key"
    else
        local count
        count=$(find "$plugin_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')
        rm -rf "$plugin_dir"
        info "Removed $count entries for plugin '$plugin'"
    fi
}

# --- subcommand: --rebuild -------------------------------------------------
# Drop a plugin's entries AND any entry whose meta.json names it as
# parent_plugin (one level deep). This avoids the dangling-ancestor
# problem where a descendant cache hit points at a no-longer-existing
# parent snapshot.
do_rebuild() {
    local plugin="$1"
    [[ -n "$plugin" ]] || { stderr "Usage: rl bake-cache --rebuild <plugin>"; exit 2; }

    if [[ ! -d "$CACHE_DIR/$plugin" ]]; then
        info "No cache entries for plugin '$plugin'."
        return 0
    fi

    # Collect descendants first (before removing the target).
    local -a descendants=()
    local meta
    while IFS= read -r meta; do
        [[ -f "$meta" ]] || continue
        local parent
        parent=$(grep -E '"parent_plugin":' "$meta" 2>/dev/null \
            | sed -E 's/.*"parent_plugin": "([^"]*)".*/\1/' | head -1)
        if [[ "$parent" == "$plugin" ]]; then
            descendants+=("$(dirname "$meta")")
        fi
    done < <(find "$CACHE_DIR" -name meta.json -type f 2>/dev/null)

    rm -rf "$CACHE_DIR/$plugin"
    info "Removed entries for plugin '$plugin'"

    local d
    for d in "${descendants[@]}"; do
        rm -rf "$d"
        info "Removed descendant: $(basename "$(dirname "$d")"):$(basename "$d")"
    done
}

# --- subcommand: --push ----------------------------------------------------
#
# Per-layer push: each (plugin, key) entry becomes its own tarball,
# and all tarballs go into one OCI artifact at <ref>. Identical
# tarballs are dedup'd server-side by sha256 (oras + the registry's
# blob mount semantics), so an unchanged layer doesn't re-upload
# bytes — only its manifest entry changes.
#
# The tar root inside each blob is "<plugin>/<key>/<files>" so pull
# can just untar into $CACHE_DIR without parsing filenames.
do_push() {
    local ref="$1"
    [[ -n "$ref" ]] || { stderr "Usage: rl bake-cache --push <oci-ref>"; exit 2; }
    command -v oras >/dev/null 2>&1 \
        || { stderr "Error: oras CLI required. Install: brew install oras / apt install oras"; exit 1; }

    if [[ ! -d "$CACHE_DIR" ]]; then
        info "Cache empty (no entries at $CACHE_DIR) — nothing to push."
        return 0
    fi

    local staging
    staging=$(mktemp -d)
    trap "rm -rf '$staging'" EXIT

    local -a artifacts=()
    local plugin_dir plugin key_dir key tar_name
    for plugin_dir in "$CACHE_DIR"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        plugin=$(basename "$plugin_dir")
        for key_dir in "$plugin_dir"*/; do
            [[ -d "$key_dir" ]] || continue
            key=$(basename "$key_dir")
            tar_name="${plugin}__${key}.tar.gz"
            # Tar root inside the blob is `<plugin>/<key>/…`, so pull
            # untars at $CACHE_DIR and the entry lands at the right
            # path with no per-file rewriting.
            tar czf "$staging/$tar_name" -C "$CACHE_DIR" "$plugin/$key"
            # Custom media type makes the artifact identifiable as
            # bakerish-specific in registry tooling. Standard OCI
            # consumers ignore unknown types. Store the basename — oras
            # is invoked from the staging dir so it resolves the tarball
            # itself; the `:<media-type>` suffix is parsed by oras.
            artifacts+=("${tar_name}:application/vnd.bakerish.layer.v1+gzip")
        done
    done

    if [[ ${#artifacts[@]} -eq 0 ]]; then
        info "Cache empty — nothing to push."
        return 0
    fi

    info "Pushing ${#artifacts[@]} layers to ${ref}…"
    ( cd "$staging" && oras push "$ref" \
        --artifact-type application/vnd.bakerish.cache.v1+json \
        "${artifacts[@]}" ) || die "oras push failed."
    info "Push complete."
}

# --- subcommand: --pull ----------------------------------------------------
#
# Pulls the OCI artifact at <ref> and untars every layer blob back
# under $CACHE_DIR. Idempotent — if an entry already exists locally
# (same plugin / key), tar overwrites it with the registry version.
do_pull() {
    local ref="$1"
    [[ -n "$ref" ]] || { stderr "Usage: rl bake-cache --pull <oci-ref>"; exit 2; }
    command -v oras >/dev/null 2>&1 \
        || { stderr "Error: oras CLI required. Install: brew install oras / apt install oras"; exit 1; }

    local staging
    staging=$(mktemp -d)
    trap "rm -rf '$staging'" EXIT

    info "Pulling ${ref}…"
    oras pull "$ref" -o "$staging" 2>&1 | tail -5 \
        || die "oras pull failed."

    mkdir -p "$CACHE_DIR"
    local tar count=0
    for tar in "$staging"/*.tar.gz; do
        [[ -f "$tar" ]] || continue
        tar xzf "$tar" -C "$CACHE_DIR"
        count=$((count + 1))
    done
    if [[ $count -eq 0 ]]; then
        warn "Pulled artifact contained no layer tarballs (looked for *.tar.gz)."
        return 0
    fi
    info "Pull complete — restored $count layer(s) under $CACHE_DIR."
}

# --- arg parse -------------------------------------------------------------
case "${1:-}" in
    --rm)        shift; do_rm      "${1:-}"; exit 0 ;;
    --rm=*)      do_rm      "${1#--rm=}"; exit 0 ;;
    --rebuild)   shift; do_rebuild "${1:-}"; exit 0 ;;
    --rebuild=*) do_rebuild "${1#--rebuild=}"; exit 0 ;;
    --push)      shift; do_push    "${1:-}"; exit 0 ;;
    --push=*)    do_push    "${1#--push=}"; exit 0 ;;
    --pull)      shift; do_pull    "${1:-}"; exit 0 ;;
    --pull=*)    do_pull    "${1#--pull=}"; exit 0 ;;
esac

# Default: list.
if [[ ! -d "$CACHE_DIR" ]]; then
    info "Cache empty (no entries at $CACHE_DIR)"
    exit 0
fi

# Find every disk.qcow2 under $CACHE_DIR. Path shape is
#   $CACHE_DIR/<plugin>/<key>/disk.qcow2
# Print one row per entry.
total_bytes=0
total_entries=0

printf '%-22s %-16s %-6s %10s %10s   %s\n' "PLUGIN" "KEY" "KIND" "SIZE" "MEMORY" "LAST_MODIFIED"
printf '%-22s %-16s %-6s %10s %10s   %s\n' "----------------------" "----------------" "------" "----------" "----------" "-------------------"

while IFS= read -r disk; do
    [[ -f "$disk" ]] || continue
    entry_dir=$(dirname "$disk")
    key=$(basename "$entry_dir")
    plugin=$(basename "$(dirname "$entry_dir")")
    meta="$entry_dir/meta.json"

    kind="cold"
    if [[ -f "$meta" ]]; then
        k=$(grep -E '"kind":' "$meta" 2>/dev/null \
            | sed -E 's/.*"kind": "([^"]*)".*/\1/' | head -1)
        kind="${k:-cold}"
    fi

    disk_size=$(stat -f%z "$disk" 2>/dev/null || stat -c%s "$disk" 2>/dev/null || echo 0)
    mem_size=0
    if [[ -f "$entry_dir/memory.bin" ]]; then
        mem_size=$(stat -f%z "$entry_dir/memory.bin" 2>/dev/null \
                || stat -c%s "$entry_dir/memory.bin" 2>/dev/null || echo 0)
    fi

    # Human-readable size formatter inline (avoid `numfmt` portability).
    fmt_size() {
        local b=$1
        if   [[ $b -gt 1073741824 ]]; then printf '%.1fG' "$(echo "scale=1; $b/1073741824" | bc)"
        elif [[ $b -gt 1048576    ]]; then printf '%.1fM' "$(echo "scale=1; $b/1048576"    | bc)"
        elif [[ $b -gt 1024       ]]; then printf '%.1fK' "$(echo "scale=1; $b/1024"       | bc)"
        else                              printf '%dB'    "$b"
        fi
    }

    mtime=$(stat -f%Sm -t '%Y-%m-%d %H:%M' "$disk" 2>/dev/null \
         || stat -c '%y' "$disk" 2>/dev/null | cut -d'.' -f1)

    printf '%-22s %-16s %-6s %10s %10s   %s\n' \
        "$plugin" "${key:0:16}" "$kind" "$(fmt_size "$disk_size")" \
        "$(if [[ "$mem_size" -gt 0 ]]; then fmt_size "$mem_size"; else echo '-'; fi)" \
        "$mtime"

    total_bytes=$(( total_bytes + disk_size + mem_size ))
    total_entries=$(( total_entries + 1 ))
done < <(find "$CACHE_DIR" -name disk.qcow2 -type f 2>/dev/null | sort)

if [[ $total_entries -eq 0 ]]; then
    info "Cache empty (no disk.qcow2 entries found in $CACHE_DIR)"
    exit 0
fi

printf '\n'
total_human=$(
    if   [[ $total_bytes -gt 1073741824 ]]; then printf '%.1fG' "$(echo "scale=1; $total_bytes/1073741824" | bc)"
    elif [[ $total_bytes -gt 1048576    ]]; then printf '%.1fM' "$(echo "scale=1; $total_bytes/1048576"    | bc)"
    else                                        printf '%dB'    "$total_bytes"
    fi
)
printf '%d entries, %s on disk.\n' "$total_entries" "$total_human"
printf 'Last prune: '
if [[ -f "$CACHE_DIR/.last-prune.log" ]]; then
    cat "$CACHE_DIR/.last-prune.log"
else
    echo "never"
fi
