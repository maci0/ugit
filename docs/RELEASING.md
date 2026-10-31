# Releasing ugit

CI uses the checksum-pinned official Zig 0.17.0 Linux toolchain and actions
pinned to full commit IDs. The MISRA checker is pinned to the same public
`maci0/misra-zig` revision used for the initial review.

Every push to `main` and pull request runs formatting, ShellCheck, packaging
validator tests, MISRA reachability/lint, and the unit/conformance suite in
Debug, ReleaseSafe and ReleaseSmall. Two static ReleaseSmall profiles are built:

- `x86_64-linux-musl`, baseline CPU.
- `arm-linux-musleabihf`, Cortex-A7 hard-float ABI.

The packaging script checks ELF class, CPU architecture, ABI, program-header
bounds and absence of an ELF loader/dynamic segment. Archives have fixed
ownership, permissions and timestamps, and include GPL and Zig notices.
`BUILD.json` records the version, source commit, compiler, target and CPU.
Individual and combined SHA-256 manifests cover the exact archives. Matrix
outputs must have the same source commit, and CI runs the conformance suite
against the executable extracted from the x86-64 archive.

## Cut a release

1. Update `build.zig.zon` and add `docs/releases/v<version>.md`.
2. Commit and push to `main`; wait for CI to pass.
3. Create and push an annotated tag matching the package version:

   ```sh
   git tag -a v0.1.0 -m 'ugit v0.1.0'
   git push origin v0.1.0
   ```

The tag run repeats all checks and requires that its commit is on `origin/main`.
Publication starts as a draft. CI downloads and revalidates the uploaded assets
and their checksum manifest before making the release public. A rerun can
resume a draft; an already published release is verified without replacing its
assets. Only the publish job receives repository write permission. Pull requests
never receive release credentials.

CI artifacts are retained for 14 days. Published releases contain the two
archives, individual `.sha256` files, and `SHA256SUMS`. Standard GitHub source
archives provide the corresponding source at the exact tag.

## Local checks

```sh
python3 -m unittest discover -s tests/release -v
zig fmt --check build.zig build.zig.zon tests.zig src
shellcheck scripts/setup-zig.sh
python3 scripts/release.py build x86_64 --output .scratch/bundle
python3 scripts/release.py build armv7 --output .scratch/bundle
python3 scripts/release.py verify .scratch/bundle
python3 scripts/release.py extract-native .scratch/bundle --output .scratch/smoke/bin/ugit
python3 tests/conformance.py --binary .scratch/smoke/bin/ugit
```

Release builds require an existing Git commit for provenance. ARM artifacts are
cross-built and inspected; CI does not execute them or validate printer RAM.
