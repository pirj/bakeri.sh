#!/usr/bin/env bash
# Template plugin.sh — copied verbatim into every synthesised
# _prebuild-<name>/ directory by lib/bake-prebuild.sh. Reads sibling
# files cmd.sh and key_files.txt; the synthesiser writes those per
# section. Keeping the logic uniform here means a fix in this file
# applies to every prebuild step after the next `bake run` regenerates
# the plugins.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

_pdir=$(dirname "${BASH_SOURCE[0]}")

# Tell the framework to skip this layer when every declared key_files
# glob expands to nothing in the project root. Means an "optional"
# prebuild step naturally short-circuits when its inputs are absent.
snapshot_should_skip() {
    local kf any=0
    while IFS= read -r kf; do
        [[ -n "$kf" ]] || continue
        local f
        for f in $kf; do
            if [ -f "$f" ]; then any=1; break 2; fi
        done
    done < "$_pdir/key_files.txt"
    # Explicit `if` (not `[ ] && cmd`) — under set -e, a false test as
    # the last command of a function aborts the parent script.
    if [ "$any" = "0" ]; then
        echo "skip"
    fi
}

# snapshot_key = hash of (cmd text + concatenated contents of every
# glob-expanded key_files entry, in declared order). Changing the
# command invalidates; changing any input file invalidates.
snapshot_key() {
    {
        cat "$_pdir/cmd.sh"
        local kf f
        while IFS= read -r kf; do
            [[ -n "$kf" ]] || continue
            for f in $kf; do
                [ -f "$f" ] && cat "$f"
            done
        done < "$_pdir/key_files.txt"
    } | sha256sum | cut -d' ' -f1
}

# snapshot_build = scp cmd.sh into the VM, run it as the rlock user
# under bash -l (so mise/PATH from the previous layers is loaded),
# from /home/rlock/repo.
snapshot_build() {
    local vm="$1"
    aq scp "$_pdir/cmd.sh" "$vm:/tmp/_prebuild-cmd.sh"
    aq exec "$vm" sh <<'SH'
set -eu
chown rlock:rlock /tmp/_prebuild-cmd.sh
chmod 755 /tmp/_prebuild-cmd.sh
su -l rlock -c 'set -eu; cd ~/repo; bash /tmp/_prebuild-cmd.sh'
rm -f /tmp/_prebuild-cmd.sh
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
