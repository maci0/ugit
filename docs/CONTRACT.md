# Updater command contract

Scope is the union of runtime Git calls in these source snapshots, including
shared version discovery and Feather recovery, not commands
used only to create test fixtures:

- Printer `/opt/config/mod/.root/moonraker/components/update_manager/git_deploy.py`,
  read from Forge-X 1.4.2 on 2026-10-31. SHA-256:
  `73361916310ad82335e3b39814822be3827cd733f242a1f79cff27af74d224aa`.
- Phobos `src/components/update_manager.zig`, commit
  `6d2a94283ce257abc744b22b4312515f08176f8e`. SHA-256:
  `899c980443063e0c8afc89a8eb8ffba526ce1fe6e5c05da5013ed9c269b0ec10`.

- Forge-X vendored `moonraker/utils/__init__.py`, SHA-256
  `f9252faa005cfb31993d48c2ef87a2f31422e9944a079d759e8a82ff1e566c3b`.
- Phobos `src/components/feather_updates.zig`, SHA-256
  `38dae9a5c08cc63e7ba01015504033cea30cb7bdd41240f878ae8e39816cbd45`.

ugit accepts an optional `-C <directory>` before a command. No shell is used.
There are 18 command families:

| Command | Caller forms |
| --- | --- |
| `status` | `--porcelain`, optionally `-b` or `--ignored` |
| `branch` | `--list --no-color`; `--no-color` |
| `config` | `--get <key>` |
| `remote` | no arguments; `get-url <remote>`; `set-url <remote> <url>` |
| `fetch` | `<remote> --prune [--progress]`; `--all -p` |
| `rev-parse` | `HEAD`; `<ref>`; `--abbrev-ref HEAD` |
| `describe` | caller combinations of `--always --tags --long --dirty --abbrev=8` and an optional ref |
| `rev-list` | `<ref> --count`; `<base>..<tip> --count`; `--tags --max-count=1` |
| `merge-base` | `--is-ancestor <base> <tip>` |
| `log` | `<base>..<tip> --format=<Moonraker format> --max-count=100` |
| `for-each-ref` | optional `--count=100`, `--sort=-creatordate --contains=HEAD --merged=<remote/branch> --format=<Moonraker format> refs/tags` |
| `pull` | `--progress [--rebase] [<remote> <commit>]` |
| `checkout` | `[-q] <branch-or-ref>`; `-q -- .` |
| `reset` | `--hard <ref>` |
| `clone` | `--branch <branch> --filter=blob:none <url> <destination>` |
| `cat-file` | `-e <commit>^{commit}` |
| `fsck` | `--full` |
| `clean` | `-fd`; `-d -f` |

The changelog and tag formats are constants in `src/display.zig`. Generic Git
format languages are outside this contract. Dead Moonraker config setter
helpers, and Git commands appearing only in Phobos fixture setup, do not expand
the runtime surface. Unsupported commands and options return an error.

Moonraker fetches and checks ancestry before choosing reset, checkout, or pull.
Pull handles its fast-forward path; a newly diverged history is refused rather
than merged or rebased. There is no commit-authoring interface.

Clone requests `blob:none` when the server advertises filtering. Omitted blobs
are fetched by object ID for checkout, with promisor metadata and pack indexes
written in Git's formats. A server without filtering supplies a full pack.

## Repository and transport formats

The target is a public smart HTTP(S) SHA-1 repository. HTTPS certificate checking
uses the system CA store through Zig's HTTP client. SSH, file transports,
credential helpers, external filters, hook execution, and SHA-256 repositories
are outside this target configuration.

Supported storage is loose zlib objects, pack versions 2/3, pack-index version 2,
and ordinary Git index versions 2/3. Both OFS_DELTA and REF_DELTA are decoded.
Gitdir pointers and common directories are followed for linked worktrees.
Sparse indexes, conflicted indexes, submodule checkout, custom text conversion,
and arbitrary revision expressions are not implemented. Existing repositories
must use the target configuration; this is not a general replacement for Git.

Network object IDs, packet lengths, inflated sizes, pack/index checksums, tree
paths, delta offsets and reference paths are validated. Index/ref replacement
uses exclusive lock files, file synchronization and rename. Worktree files are
replaced through checked parent handles, and `reset` holds `index.lock` while
it changes the working tree. An I/O failure can leave a partially changed
working tree and returns an error; there is no whole-tree rollback journal.

`clean` preserves ignored files and nested repositories. Source files are
checked before applying a tree. `.git`, traversal, duplicate tree entries and
file/directory prefix collisions are rejected. Mutations are not advertised as
safe against a hostile process concurrently rewriting the same repository.

## Fixed bounds

| Input | Bound |
| --- | --- |
| CLI argv | 32 arguments, 4096 bytes per argument |
| Inflated object | 16 MiB |
| Pack / metadata file | 64 MiB |
| Ref advertisement | 8 MiB |
| Pack objects | 1,000,000 |
| Refs / paths / commits | 100,000 each |
| Delta depth | 64 |
| Aggregate inflated delta chain | 64 MiB |
| Commit parents | 64 |
| Pack directory entries / linked worktrees | 1024 |
| Ignore rule / path | 4096 bytes |
| Ignore matcher | 256 pending states, 1,000,000 steps |

These are error boundaries, not promises about printer RAM use. Transfer and
pack buffers are currently held in memory; their peak can exceed the free RAM
on an AD5M. The binary's small size does not establish its runtime memory budget.
No printer deployment or hardware-memory validation was performed.

Protocol references: [Git pack transport](https://git-scm.com/docs/gitprotocol-pack),
[pack/index format](https://git-scm.com/docs/gitformat-pack), and
[working index format](https://git-scm.com/docs/gitformat-index).
