# Initial implementation verification — 2026-10-31

This records the pre-CI implementation build. Current release archives and
checksums are produced by the release workflow; see `RELEASING.md`.

Zig 0.17.0, Linux x86-64 host. Initial implementation gates:

| Gate | Result |
| --- | --- |
| `zig fmt --check build.zig tests.zig src` | Passed, exit 0 |
| User's `misra-lint --root tests.zig build.zig tests.zig src/*.zig` | No findings, exit 0 |
| Debug unit tests | 16 passed, exit 0 |
| ReleaseSafe unit tests | 16 passed, exit 0 |
| Debug conformance | 56 checks passed, exit 0 |
| ReleaseSafe conformance | 56 checks passed, exit 0 |
| ReleaseSmall conformance | 56 checks passed, exit 0 |
| Native ReleaseSmall build | Passed |
| ARM Cortex-A7 ReleaseSmall cross-build | Passed; not executed |

The conformance suite uses owned temporary repositories, clears `PATH` for ugit,
and uses Git only as a fixture builder, reference implementation and localhost
HTTP server. It exercises all 18 command families, normal and filtered pack
transfers, incremental updates, startup discovery, date ties between annotated
tags, gitdir/common-dir worktrees, branch/reflog state, ignore and quoting
behavior, nested repository preservation, independent malformed-HEAD validation,
and rejection of a `.git` tree entry before HEAD or tracked files change.

An additional read-only HTTPS fetch from
`https://github.com/DrA1ex/ff5m.git` into a temporary repository succeeded with
certificate verification enabled. Its filtered pack was 1,402,257 bytes, and
Git's `fsck --full` returned 0. That fixture was removed afterwards.

## Build artifacts

Both ELF files have no dynamic section or dynamic library dependencies.

| Target | Path | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| Native x86-64 | `zig-out/bin/ugit` | 724,504 | `348cb475834f134843a2f3eb88a03dfd20fb5d0717f31569647030fa29795b4f` |
| ARM Cortex-A7 | `zig-out/arm/bin/ugit` | 850,664 | `2ae6ac724cf187945f3768ebc6728bcb3d3844438734115c869ce3be95a9e7a9` |

`readelf` confirms the ARM artifact is little-endian ELF32, ARMv7, Cortex-A7,
EABI5 with the hard-float/VFP calling convention. No foreign executable was run
on the host.

The [manual MISRA-Zig review](MISRA-REVIEW.md) states what the scanner cannot
prove. No printer deployment, hardware execution, RAM measurement, large-pack
soak, power-failure experiment, or claim of universal Git semantic parity is
included. The supported configuration and error limits are in
[CONTRACT.md](CONTRACT.md).
