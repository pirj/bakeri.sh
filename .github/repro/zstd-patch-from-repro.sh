#!/usr/bin/env bash
# Minimal repro for zstd --patch-from corruption observed on
# ubuntu-latest with qemu memory.bin (1.7 GiB) references.
#
# Symptom: encoder emits a patch whose decoder reconstructs bytes
# that don't match the XXH64 checksum embedded in the patch frame.
# Error: "Decoding error (36) : Restored data doesn't match checksum".
#
# Encoder and decoder see byte-identical references (verified
# externally via sha256). Bug reproduces with various zstd versions
# (1.5.5 from Ubuntu apt; 1.5.7 from source); does NOT reproduce on
# macOS brew zstd 1.5.7 against the same code path.
#
# This repro builds a synthetic file with QEMU-memory-dump-like
# entropy: ~60% zero pages + ~30% repeating pages + ~10% random,
# 1.7 GiB total. Modifies a 5 MiB region for the delta target.
# Runs encode + decode + verify, exits 0 if round-trip clean, 1
# if checksum mismatch.

set -eu

REF=/tmp/zstd-repro-ref.bin
NEW=/tmp/zstd-repro-new.bin
PATCH=/tmp/zstd-repro.zstpatch
OUT=/tmp/zstd-repro-out.bin

TOTAL_MB=1700
DELTA_OFFSET_MB=900
DELTA_SIZE_MB=5

stat_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

echo "=== zstd version ==="
zstd --version
echo
echo "=== generating ${TOTAL_MB} MiB QEMU-memory-like reference ==="
# Mix: ~60% zero pages + ~30% repeating pages + ~10% random.
# Build in 64 KiB chunks to mimic qcow2 cluster / qemu RAM page
# granularity. Interleave so the entropy distribution roughly
# matches what a real qemu memory dump looks like (clusters of
# zeros punctuated by occasional non-zero pages).
TOTAL_CHUNKS=$((TOTAL_MB * 16))           # 64 KiB chunks
ZERO_CHUNKS=$((TOTAL_CHUNKS * 60 / 100))
REPEAT_CHUNKS=$((TOTAL_CHUNKS * 30 / 100))
RANDOM_CHUNKS=$((TOTAL_CHUNKS - ZERO_CHUNKS - REPEAT_CHUNKS))
echo "  total: $TOTAL_CHUNKS x 64 KiB chunks"
echo "  zero:   $ZERO_CHUNKS x 64 KiB"
echo "  repeat: $REPEAT_CHUNKS x 64 KiB"
echo "  random: $RANDOM_CHUNKS x 64 KiB"
{
  # Write interleaved batches to spread entropy across the address
  # space rather than concentrating each class at one end.
  for batch in 1 2 3 4; do
    dd if=/dev/zero bs=64K count=$((ZERO_CHUNKS / 4)) 2>/dev/null
    dd if=/dev/zero bs=64K count=$((REPEAT_CHUNKS / 4)) 2>/dev/null \
      | tr '\0' "K"
    dd if=/dev/urandom bs=64K count=$((RANDOM_CHUNKS / 4)) 2>/dev/null
  done
} > "$REF"

# Ensure exactly TOTAL_MB MiB by truncating any rounding overshoot.
truncate -s "${TOTAL_MB}M" "$REF" 2>/dev/null || dd if=/dev/null of="$REF" bs=1M seek="$TOTAL_MB" count=0 2>/dev/null

REF_SIZE=$(stat_size "$REF")
echo "  produced: $REF_SIZE bytes ($((REF_SIZE / 1024 / 1024)) MiB)"

# Create target by copying ref and modifying 5 MiB at fixed offset
cp "$REF" "$NEW"
dd if=/dev/urandom of="$NEW" bs=1M count=$DELTA_SIZE_MB seek=$DELTA_OFFSET_MB conv=notrunc status=none

echo
echo "ref: $(stat_size "$REF") bytes  sha=$(sha "$REF")"
echo "new: $(stat_size "$NEW") bytes  sha=$(sha "$NEW")"
echo
echo "=== encode (zstd --patch-from --long=31) ==="
zstd -q --long=31 --patch-from="$REF" "$NEW" -o "$PATCH" --force
echo "patch: $(stat_size "$PATCH") bytes"
echo
echo "=== decode ==="
if zstd -d --long=31 --patch-from="$REF" "$PATCH" -o "$OUT" --force 2>&1; then
    echo "decode: success"
else
    echo "decode: FAILED (this is the bug)"
    rm -f "$REF" "$NEW" "$PATCH" "$OUT"
    exit 1
fi
echo
echo "=== verify round-trip ==="
echo "out:  $(stat_size "$OUT") bytes  sha=$(sha "$OUT")"
if cmp -s "$NEW" "$OUT"; then
    echo "PASS: round-trip byte-identical"
    rm -f "$REF" "$NEW" "$PATCH" "$OUT"
    exit 0
else
    echo "FAIL: out != new (silent corruption — decoder didn't report error)"
    rm -f "$REF" "$NEW" "$PATCH" "$OUT"
    exit 2
fi
