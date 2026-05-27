# Bug report draft for facebook/zstd

To be filed at https://github.com/facebook/zstd/issues/new?template=bug_report.md

---

**Title:** `--patch-from` on Linux produces patches whose decoder reports "Restored data doesn't match checksum" (XXH64) for ~1.6 GiB qemu live-snapshot memory references with --long=31

**Describe the bug**

`zstd --patch-from=<ref> <target> -o <patch> --long=31` produces a patch file whose decoder, fed the SAME (byte-identical) reference, errors out with:

```
<patch> : Decoding error (36) : Restored data doesn't match checksum
```

Encoder and decoder run consecutively on the same machine, against the same on-disk reference (verified byte-identical via `sha256sum` on both sides — `e6b527233120bf21640fef82dd8d10fc7ab2142bb15928f2a4e3d169adf3c14a` in our case). The reference is a 1.6–1.7 GiB QEMU live-snapshot memory dump; the target differs by a ~5–10 MiB region near the middle.

The same code path (same zstd binary, same flags, same reference + target sizes) **passes** on macOS aarch64 Homebrew zstd 1.5.7 against an identical workload. **Reproduces on**:
- Ubuntu 24.04 + apt zstd 1.5.5
- Ubuntu 24.04 + facebook/zstd v1.5.7 built from source
- Ubuntu 22.04 + apt zstd (older)

**Reproduction is workload-sensitive.** Synthetic inputs do NOT reproduce; the bug requires a specific qemu memory pattern:
- 1.7 GiB random data + 5 MiB delta + --long=31 → **passes** on all platforms.
- 1.7 GiB ~60% zero pages + ~30% repeating pages + ~10% random + 5 MiB delta + --long=31 → **passes** on all platforms.
- Real Alpine ISO live-boot memory dump (~175 MiB) + 5 MiB delta + --long=31 → **passes** on all platforms.
- Real docker-compose+postgres live-snapshot memory dump (~1.65 GiB) + 5 MiB delta + --long=31 → **fails consistently on Linux, passes on macOS**.

The triggering pattern is something specific to qemu-savevm output of a guest running a postgres + docker stack — possibly the distribution of shared_buffers + page tables + page cache that doesn't show up in synthetic input.

**To Reproduce**

The shortest reliable reproduction is the [`pirj/snapcompose-rails-pg-example`](https://github.com/pirj/snapcompose-rails-pg-example) `benchmark-r17-r18` GitHub Actions workflow:

1. Fork the repo (or use as-is).
2. Run the `benchmark-r17-r18` workflow on `workflow_dispatch`.
3. The `cold-zstd-patch` job reliably fails at "Decoding error (36)" after the `_prebuild-pg-prewarm` layer's patch is created and immediately consumed by the chain reconstruction step.
4. The `cold-zstd` job (same fixture, default zstd compression, no --patch-from) succeeds.

The bug surfaces inside an end-to-end snapshot pipeline; if a more minimal repro is required, the maintainers may need a sample memory dump (1.65 GiB compressed to ~480 MiB by pzstd) that we can share privately on request — the file is a process memory dump and contains keys + buffer data we'd rather not publish on a public release asset.

**Expected behavior**

`zstd -d --patch-from=<ref> <patch> -o <out>` should produce `<out>` byte-identical to the original `<target>` that was fed to the encoder, and the XXH64 checksum embedded in the patch frame should validate.

**Desktop (please complete the following information):**
- OS: Ubuntu 24.04 LTS (GitHub Actions ubuntu-latest runner; Azure VM, KVM-accel)
- zstd CLI versions tried: 1.5.5 (apt), 1.5.7 (built from facebook/zstd v1.5.7 tag)
- Compression flags used: `zstd -q --long=31 --patch-from=<ref> <new> -o <patch>` (default level 3)
- Decompression flags: `zstd -d --long=31 --patch-from=<ref> <patch> -o <out>`
- File sizes: reference 1734206607 bytes (1.7 GiB), target same size with ~5 MiB modified region near offset 900 MiB, patch ~6 MiB
- Reference bytes: verified byte-identical at encode time and decode time via `sha256sum` (`e6b527233120bf21...`)

**Additional context**

Our use case is layered VM live-snapshot deduplication: each snapshot's `memory.bin.zst` (~500 MiB compressed, ~1.65 GiB raw) is encoded as a delta against the immediately-previous layer's full snapshot. Across stacked plugin layers most pages don't change between layers, so the patches average ~5 MiB. On macOS this gives us a ~98 % disk saving per delta layer; on Linux the patch encoder reliably produces unusable patches at this size.

We've experimented with:
- pzstd (parallel multi-frame) vs zstd (single-frame) for compressing the reference — same failure.
- pzstd vs zstd for decompressing the reference (separately confirmed reference bytes match) — same failure.
- Without `--long=31` — encoder errors because reference exceeds default 128 MiB window.
- `--long=32` — same failure.

We've kept the original `memory.bin.zst` that triggers this and can supply it privately to maintainers if it helps. PATCH_DIAG sha256 diagnostic instrumentation in our wrapper (aq v2.5.38, rlock v0.1.10) confirms encode/decode reference bytes are identical, ruling out compression non-determinism between the two sides.

Happy to test fixes against our pipeline once a candidate lands in `dev` branch.
