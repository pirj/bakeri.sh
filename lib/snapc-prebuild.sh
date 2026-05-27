#!/usr/bin/env bash
# snapc-prebuild synthesiser — parses a project's snapcompose.toml and
# materialises one rlock plugin per `[prebuild.<name>]` section under
# the given synth directory. The synthesised plugins are normal rlock
# plugins as far as discovery / dep resolution / walk_chain are
# concerned; they're invisible to rlock's plugin-protocol internals.
#
# Designed for sourcing from `bin/bake`. Depends on rlock's lib/toml.sh
# for parsing (sourced separately by the caller via $RL_LIB_DIR).

# Synthesise prebuild plugins from a project's snapcompose.toml.
#
# Usage: snapc_prebuild_synthesize <project_root> <synth_dir> <template_path>
#
# Reads <project_root>/snapcompose.toml. For each `[prebuild.<name>]`
# section (in source order):
#   - Creates <synth_dir>/_prebuild-<name>/
#   - Writes plugin.toml with deps chaining each section to the previous
#     so walk_chain preserves source order (deps = ["_prebuild-<prev>"]
#     for the second + later sections; deps = [] for the first).
#   - Writes cmd.sh (raw shell text from the `cmd` field) and
#     key_files.txt (one declared glob per line).
#   - Copies <template_path> in as plugin.sh (the runtime hooks read
#     cmd.sh and key_files.txt at hook-call time).
#
# Prints the synthesised plugin names to stdout, one per line, in
# source order — the caller appends these to the `rl new` argument list.
#
# Returns 0 if no snapcompose.toml or no [prebuild.*] sections exist; the
# function is a no-op in that case (prints nothing). Returns non-zero
# on validation errors (toml_validate fails, missing required fields).
snapc_prebuild_synthesize() {
    local project_root="$1"
    local synth_dir="$2"
    local template_path="$3"

    local snapcompose_toml="$project_root/snapcompose.toml"
    [[ -f "$snapcompose_toml" ]] || return 0

    toml_validate "$snapcompose_toml" || return 1

    # Enumerate [prebuild.*] sections in source order. The grep matches
    # only single-bracket headers (`[prebuild.foo]`); `[[arrays-of-
    # tables]]` syntax isn't supported anywhere in our TOML usage.
    local -a sections=()
    local section_line
    while IFS= read -r section_line; do
        sections+=("$section_line")
    done < <(grep -E '^\[prebuild\.[^][]+\]' "$snapcompose_toml" \
        | sed -E 's/^\[prebuild\.(.+)\]/\1/')

    [[ ${#sections[@]} -eq 0 ]] && return 0

    mkdir -p "$synth_dir"

    local prev="" section plugin_name plugin_dir cmd strategy
    local -a key_files
    for section in "${sections[@]}"; do
        plugin_name="_prebuild-$section"
        plugin_dir="$synth_dir/$plugin_name"

        # Wipe any prior synthesis under this name so stale cmd.sh /
        # key_files.txt content can't leak into the new layer.
        rm -rf "$plugin_dir"
        mkdir -p "$plugin_dir"

        cmd=$(toml_get_in_section "$snapcompose_toml" "prebuild.$section" "cmd")
        strategy=$(toml_get_in_section "$snapcompose_toml" "prebuild.$section" "strategy")
        strategy="${strategy:-cached}"
        kind=$(toml_get_in_section "$snapcompose_toml" "prebuild.$section" "kind")
        kind="${kind:-cold}"
        memory=$(toml_get_in_section "$snapcompose_toml" "prebuild.$section" "memory")
        key_files=()
        local kf
        while IFS= read -r kf; do
            [[ -n "$kf" ]] && key_files+=("$kf")
        done < <(toml_get_array_in_section "$snapcompose_toml" "prebuild.$section" "key_files")

        if [[ -z "$cmd" ]]; then
            echo "Error: snapcompose.toml [prebuild.$section] missing required 'cmd'." >&2
            return 1
        fi
        if [[ ${#key_files[@]} -eq 0 ]]; then
            echo "Error: snapcompose.toml [prebuild.$section] missing required 'key_files' (or empty)." >&2
            return 1
        fi
        case "$kind" in
            cold|live) ;;
            *)
                echo "Error: snapcompose.toml [prebuild.$section] has invalid 'kind' = '$kind' (expected cold|live)." >&2
                return 1
                ;;
        esac

        # plugin.toml
        {
            printf 'description = "snapcompose.toml prebuild: %s"\n' "$section"
            printf 'protocol_version = "1"\n'
            if [[ -n "$prev" ]]; then
                printf 'deps = ["%s"]\n' "$prev"
            else
                printf 'deps = []\n'
            fi
            printf 'host_deps = []\n'
            printf 'triggers = []\n'
            printf 'commands = []\n'
            printf '\n'
            printf '[snapshot]\n'
            printf 'strategy = "%s"\n' "$strategy"
            printf 'kind = "%s"\n' "$kind"
            # Memory hint surfaces only on live layers — cold layers
            # don't pin RAM. Skip emitting the field if cold to avoid
            # surfacing a no-op knob in the synthesised manifest.
            if [[ "$kind" == "live" && -n "$memory" ]]; then
                printf 'memory = "%s"\n' "$memory"
            fi
        } > "$plugin_dir/plugin.toml"

        # cmd.sh — verbatim user shell. Wrapping `set -eu` at the top
        # so a typo in the user's cmd fails the layer cleanly.
        {
            printf '#!/usr/bin/env bash\n'
            printf 'set -eu\n'
            printf '%s\n' "$cmd"
        } > "$plugin_dir/cmd.sh"
        chmod +x "$plugin_dir/cmd.sh"

        # key_files.txt — one glob per line, for the runtime template's
        # snapshot_key + snapshot_should_skip readers.
        printf '%s\n' "${key_files[@]}" > "$plugin_dir/key_files.txt"

        # plugin.sh — verbatim copy of the template. Stable across all
        # synthesised plugins; only the sibling cmd.sh + key_files.txt
        # vary.
        cp "$template_path" "$plugin_dir/plugin.sh"
        chmod +x "$plugin_dir/plugin.sh"

        echo "$plugin_name"
        prev="$plugin_name"
    done
}
