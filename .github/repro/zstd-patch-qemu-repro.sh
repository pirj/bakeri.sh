#!/usr/bin/env bash
# Self-contained repro for the zstd --patch-from corruption observed
# with qemu live-snapshot memory dumps on Linux.
#
# This script:
#   1. Boots a minimal Alpine VM with 2 GiB RAM under qemu.
#   2. Captures the running VM's memory via qmp `migrate file:...`.
#   3. Modifies a small region of the captured memory.
#   4. Runs zstd --patch-from encode + decode.
#   5. Reports whether the round-trip is byte-clean.
#
# Designed to be portable: no aq, no rlock, no snapcompose deps.
# Just qemu + zstd. If this script fails on Linux but passes on
# macOS, the failure isolates to zstd's handling of qemu memory
# patterns.

set -eu

VM_DIR=$(mktemp -d)
MEM_BIN=$VM_DIR/memory.bin
MEM_NEW=$VM_DIR/memory-new.bin
PATCH=$VM_DIR/memory.zstpatch
OUT=$VM_DIR/memory-out.bin
QMP_SOCK=$VM_DIR/qmp.sock
SERIAL_SOCK=$VM_DIR/serial.sock
ALPINE_ISO=$VM_DIR/alpine.iso

stat_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

cleanup() {
  set +e
  [ -f "$VM_DIR/qemu.pid" ] && kill -9 "$(cat "$VM_DIR/qemu.pid")" 2>/dev/null
  rm -rf "$VM_DIR"
}
trap cleanup EXIT

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) QEMU=qemu-system-x86_64; QEMU_MACHINE=q35; ACCEL=kvm ;;
  aarch64|arm64) QEMU=qemu-system-aarch64; QEMU_MACHINE='virt,highmem=on'; ACCEL=hvf ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

ALPINE_VER=3.22.2
echo "=== fetch Alpine ${ALPINE_VER} ISO ==="
case "$ARCH" in
  x86_64)
    curl -fsSL -o "$ALPINE_ISO" "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-virt-${ALPINE_VER}-x86_64.iso"
    ;;
  aarch64|arm64)
    curl -fsSL -o "$ALPINE_ISO" "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-virt-${ALPINE_VER}-aarch64.iso"
    ;;
esac
echo "iso: $(stat_size "$ALPINE_ISO") bytes"
echo

echo "=== zstd version ==="
zstd --version
echo

echo "=== boot Alpine VM (2 GiB RAM) ==="
"$QEMU" \
  -machine $QEMU_MACHINE -accel $ACCEL -cpu host -m 2G \
  -cdrom "$ALPINE_ISO" \
  -nic user,model=virtio-net-pci \
  -qmp unix:"$QMP_SOCK",server=on,wait=off \
  -serial unix:"$SERIAL_SOCK",server=on,wait=off,nodelay=on \
  -monitor none -display none -parallel none \
  -daemonize -pidfile "$VM_DIR/qemu.pid"

echo "qemu pid: $(cat "$VM_DIR/qemu.pid")"
echo "wait 25s for Alpine ISO to boot"
sleep 25

echo
echo "=== capture memory via qmp migrate file: ==="
{
  echo '{"execute":"qmp_capabilities"}'
  echo '{"execute":"stop"}'
  echo "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"file:${MEM_BIN}\"}}"
  # Poll until migration done
  for i in $(seq 1 60); do
    sleep 1
    echo '{"execute":"query-migrate"}'
  done
} | socat - UNIX-CONNECT:"$QMP_SOCK" | grep -E 'status|return' | head -20
# QMP migrations can take a moment to flush; wait extra
sleep 5

echo
if [ ! -f "$MEM_BIN" ]; then
  echo "FAIL: memory dump file not created"
  exit 1
fi

MEM_SIZE=$(stat_size "$MEM_BIN")
echo "memory.bin: $MEM_SIZE bytes ($((MEM_SIZE / 1024 / 1024)) MiB)"
echo "  sha256: $(sha "$MEM_BIN")"

# Create the modified target
cp "$MEM_BIN" "$MEM_NEW"
# Modify 5 MiB in the middle of the memory dump
HALF=$((MEM_SIZE / 2 / 1024 / 1024))
dd if=/dev/urandom of="$MEM_NEW" bs=1M count=5 seek="$HALF" conv=notrunc status=none
echo "  new sha:    $(sha "$MEM_NEW")"
echo

echo "=== encode patch (zstd --long=31 --patch-from) ==="
time zstd -q --long=31 --patch-from="$MEM_BIN" "$MEM_NEW" -o "$PATCH" --force
echo "patch: $(stat_size "$PATCH") bytes"
echo

echo "=== decode patch ==="
if time zstd -d --long=31 --patch-from="$MEM_BIN" "$PATCH" -o "$OUT" --force 2>&1; then
  echo "decode: returned success"
  if cmp -s "$MEM_NEW" "$OUT"; then
    echo
    echo "RESULT: PASS — round-trip byte-identical"
    exit 0
  else
    echo
    echo "RESULT: SILENT FAIL — decoder claimed success but bytes differ"
    echo "  expected sha: $(sha "$MEM_NEW")"
    echo "  got      sha: $(sha "$OUT")"
    exit 2
  fi
else
  echo
  echo "RESULT: DECODE ERROR (this is the bug)"
  exit 1
fi
