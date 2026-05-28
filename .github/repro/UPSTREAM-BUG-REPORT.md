# RETRACTED — not a zstd bug

This draft alleged a `zstd --patch-from` corruption on Linux x86_64 native
when used against ~1.7 GiB qemu live-snapshot memory dumps with `--long=31`.

**It was wrong.** zstd is fine. The bug was in our own `_snapshot_reconstruct_memory_chain`
implementation in [`rlock/lib/snapshot.sh`](https://github.com/pirj/rlock/blob/main/lib/snapshot.sh).
Fixed in `rlock v0.1.11`.

## What actually happened

`snapshot_save` walks back to the most-recent FULL ancestor (a layer with
`memory.bin.zst`) and encodes the leaf's memory delta as a single
`.zstpatch` against THAT ancestor's raw bytes. So on a chain
`[compose(full) → git(patch) → pg-prewarm(patch)]`, both `git.zstpatch`
and `pg-prewarm.zstpatch` are encoded against `compose.raw`, NOT against
each other.

The restore side was applying patches **sequentially** through the chain:

```
base = decompress(compose.zst)
base' = apply(git.zstpatch, base)         # ok — git was encoded against compose
base'' = apply(pg-prewarm.zstpatch, base')   # WRONG — pg-prewarm was encoded against compose, not git_reconstructed
```

The second step fed `pg-prewarm.zstpatch` an input it was never encoded
against → garbage output → zstd's XXH64 frame checksum tripped → error 36
"Restored data doesn't match checksum".

## Why we mis-blamed zstd

- Platform asymmetry was a red herring. M3 local fixture chain depth was
  2 (no git layer auto-detected), CI fixture chain depth was 3 (git layer
  auto-detected because `.git` exists in the repo). Depth-2 only does
  one patch-apply step which happened to be correct; depth-3 triggered
  the buggy second step.
- TCG vs native KVM was a red herring. Both ran the same buggy
  reconstruction logic; both would have failed if the TCG fixture had
  chain depth ≥3.
- Build-flag bisection (`ZSTD_NO_ASM=1`, `-DZSTD_NO_INTRINSICS`,
  `-O0 -fno-tree-vectorize`) all showed "FAIL" — because the bug wasn't
  in zstd at all, so disabling parts of zstd didn't help.

## How we found it

The post-failure valgrind step in
[`.github/workflows/benchmark-r17-r18.yml`](https://github.com/pirj/snapcompose-rails-pg-example/blob/main/.github/workflows/benchmark-r17-r18.yml)
ran the same zstd decode against the same on-disk `.zstpatch` files in
isolation and showed **PASS**. That is: the same `zstd` binary, same
patch file, same reference file, but invoked standalone, succeeded.
That ruled out zstd and pointed at the orchestration around it.

## Fix

`_snapshot_reconstruct_memory_chain` now walks back to the chain base
(first `memory.bin.zst` ancestor), decompresses it, and applies the
LEAF's `.zstpatch` directly against the base — skipping every
intermediate `.zstpatch` layer. This matches the encoder's semantics.

```bash
_snapshot_reconstruct_memory_chain() {
    local leaf_cache_dir="$1" out_raw="$2"
    local base="$leaf_cache_dir"
    while [[ -f "$base/memory.bin.zstpatch" && ! -f "$base/memory.bin.zst" ]]; do
        base=$(_snapshot_parent_dir "$base")
    done
    zstd -dc "$base/memory.bin.zst" > "$out_raw"
    if [[ "$leaf_cache_dir" != "$base" ]]; then
        local leaf_patch="$leaf_cache_dir/memory.bin.zstpatch"
        zstd -dc --long=31 --patch-from="$out_raw" "$leaf_patch" > "$out_raw.tmp"
        mv "$out_raw.tmp" "$out_raw"
    fi
}
```

## Takeaways for next time

- "Sub-flag bisection of the suspect dependency" is wasted effort if the
  failing call is not isolated end-to-end first. Always reproduce the
  failure against the **standalone CLI** of the dependency before
  blaming its internals.
- Workload-sensitive failures that don't reproduce on synthetic data are
  more often a sign of bugged orchestration around the data than of a
  data-shape-sensitive dep.
