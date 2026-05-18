#!/usr/bin/env bash
#
# bake-cache — show what bakeri.sh's snapshot framework has cached.
#
# Output is a table: plugin, key (truncated), kind, size, last-modified.
# Cold entries report disk.qcow2 size. Live entries also include
# memory.bin alongside the disk.
#
# Future subcommands (not implemented yet): `--rm <plugin>[:<key>]`,
# `--rebuild <plugin>`.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

CACHE_DIR="${RL_CACHE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aq/cache}"

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
