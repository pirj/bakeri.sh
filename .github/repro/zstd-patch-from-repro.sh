#!/usr/bin/env bash
# Minimal repro for zstd --patch-from corruption.
#
# Symptom: zstd decoder reconstructs different bytes than encoder
# expected. Encoder embeds an XXH64 of the original target in the
# patch frame; decoder applies patch against reference, computes
# XXH64 of result, mismatches → error 36 "Restored data doesn't
# match checksum".
#
# Confirmed: encoder and decoder see byte-identical reference
# (sha256 matches across save and load).
#
# Inputs:
#   reference: 1.7 GiB
#   target:    1.7 GiB (reference with ~5 MiB changed in the middle)
#   patch flag: --long=31  (2 GiB window — required for >128 MiB ref)
#
# Observed:
#   - facebook/zstd 1.5.7 (built from source on Ubuntu): FAILS
#   - Ubuntu 24.04 apt zstd 1.5.5: FAILS
#   - macOS brew zstd 1.5.7: SUCCEEDS
#
# This script: generates the inputs, runs encode/decode, reports result.

set -eu

REF=/tmp/zstd-repro-ref.bin
NEW=/tmp/zstd-repro-new.bin
PATCH=/tmp/zstd-repro.zstpatch
OUT=/tmp/zstd-repro-out.bin

REF_SIZE=$((1700 * 1024 * 1024))  # 1.7 GiB
DELTA_OFFSET=$((900 * 1024 * 1024))
DELTA_SIZE=$((5 * 1024 * 1024))   # 5 MiB

echo "=== zstd version ==="
zstd --version
echo
echo "=== generating ${REF_SIZE} bytes reference (random) ==="
dd if=/dev/urandom of="$REF" bs=1M count=$((REF_SIZE / 1024 / 1024)) status=progress 2>&1 | tail -1
cp "$REF" "$NEW"
echo "=== overwriting ${DELTA_SIZE} bytes at offset ${DELTA_OFFSET} of target ==="
dd if=/dev/urandom of="$NEW" bs=1M count=$((DELTA_SIZE / 1024 / 1024)) seek=$((DELTA_OFFSET / 1024 / 1024)) conv=notrunc status=progress 2>&1 | tail -1
echo
echo "ref: $(stat -c %s "$REF" 2>/dev/null || stat -f %z "$REF") bytes  sha256=$(sha256sum "$REF" | cut -d' ' -f1)"
echo "new: $(stat -c %s "$NEW" 2>/dev/null || stat -f %z "$NEW") bytes  sha256=$(sha256sum "$NEW" | cut -d' ' -f1)"
echo
echo "=== encode (zstd --patch-from --long=31) ==="
zstd -q --long=31 --patch-from="$REF" "$NEW" -o "$PATCH"
echo "patch: $(stat -c %s "$PATCH" 2>/dev/null || stat -f %z "$PATCH") bytes"
echo
echo "=== decode (zstd -dc --patch-from --long=31) ==="
if zstd -d --long=31 --patch-from="$REF" "$PATCH" -o "$OUT" --force 2>&1; then
    echo "decode: success"
else
    echo "decode: FAILED"
    exit 1
fi
echo
echo "=== verify round-trip ==="
echo "out:  $(stat -c %s "$OUT" 2>/dev/null || stat -f %z "$OUT") bytes  sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
if cmp -s "$NEW" "$OUT"; then
    echo "PASS: round-trip byte-identical"
else
    echo "FAIL: out != new"
    exit 2
fi
rm -f "$REF" "$NEW" "$PATCH" "$OUT"
