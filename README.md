# ugit

[![CI](https://github.com/maci0/ugit/actions/workflows/ci.yml/badge.svg)](https://github.com/maci0/ugit/actions/workflows/ci.yml)

GPL-3.0-only. See [LICENSE](LICENSE); the bundled Zig standard-library notice
is in [ZIG_LICENSE](ZIG_LICENSE).

A small Git updater client written entirely in Zig 0.17.0. It implements the
command forms used by the pinned Moonraker and Phobos update paths. Runtime
repository access, pack/delta handling, smart HTTP(S), TLS, and working-tree
changes use Zig and its standard library. No Git process, libgit2, libc, curl,
or other runtime helper is used.

The command contract and input limits are in [docs/CONTRACT.md](docs/CONTRACT.md).
Your coding standard is recorded in [AGENTS.md](AGENTS.md); verification and the
manual safety review are in [docs/MISRA-REVIEW.md](docs/MISRA-REVIEW.md).
Measured build sizes and test results are in [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Build

```sh
zig build
zig build -Doptimize=ReleaseSmall
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall --prefix zig-out/arm
```

The executable is `zig-out/bin/ugit`. An updater invokes it with Git's argv,
for example:

```sh
ugit -C /path/to/repository fetch origin --prune --progress
ugit -C /path/to/repository describe --always --tags --long --dirty --abbrev=8
```

An isolated `git` symlink to `ugit` can provide the command name expected by
Moonraker/Phobos. Keep that directory separate from the system Git installation.
This project does not install that alias or change printer services.

## Verify

```sh
zig fmt --check build.zig tests.zig src
zig test tests.zig -target x86_64-linux-musl -ODebug
zig test tests.zig -target x86_64-linux-musl -OReleaseSafe
zig run -ODebug ../../misra-zig/tools/misra_lint.zig -- --root tests.zig build.zig tests.zig src/*.zig
zig build
python tests/conformance.py
```

The conformance test needs Python 3 and Git as an oracle and fixture server.
It creates owned temporary repositories under `.scratch`, binds HTTP only to
localhost, clears `PATH` for ugit, and removes its fixtures afterwards. It checks
read results and exit statuses, filtered clone and lazy blobs, incremental
updates, linked worktrees, detached HEAD, recovery, ignored files, nested
repositories, quoting, and rejection of a malicious tree.

The implementation targets public HTTP(S), SHA-1 updater repositories with
ordinary working trees and Git's default text behavior. It has not been
installed or memory-profiled on the printer. Review the documented bounds and
format restrictions before using it as the printer's Git replacement.

## Releases

Download static Linux x86-64 or ARM Cortex-A7 archives from
[GitHub Releases](https://github.com/maci0/ugit/releases). Each includes the
executable, source commit metadata, documentation and license notices. Check
`SHA256SUMS` before extracting; corresponding source is available at the release
tag and in GitHub's tagged source archives.

The [CI/release workflow](.github/workflows/ci.yml) runs formatting, MISRA-Zig,
unit tests and Git conformance before building verified static artifacts. The
packaged x86-64 binary is tested again. Only a matching annotated release tag
on a commit already on `main` can publish a release. The downloaded draft assets
are verified before publication. See [docs/RELEASING.md](docs/RELEASING.md).
