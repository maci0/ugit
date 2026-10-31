#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Git is a test oracle only. All mutations stay under .scratch/owned temp dirs."""
import argparse
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
LOG_FORMAT = 'sha:%H%x1Dauthor:%an%x1Ddate:%ct%x1Dsubject:%s%x1Dmessage:%b%x1E'
REF_FORMAT = '%(if)%(*objecttype)%(then)%(*objecttype) %(*objectname)%(else)%(objecttype) %(objectname)%(end) %(refname)'


def run(argv, *, env=None):
    if Path(argv[0]).name == 'ugit':
        env = dict(os.environ if env is None else env, PATH='/nonexistent')
    return subprocess.run([str(x) for x in argv], capture_output=True, env=env, check=False)


def checked(argv, *, env=None):
    result = run(argv, env=env)
    if result.returncode:
        raise AssertionError((argv, result.returncode, result.stdout, result.stderr))
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=ROOT / 'zig-out/bin/ugit')
    args = parser.parse_args()
    binary = args.binary.resolve()
    (ROOT / '.scratch').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='conformance-', dir=ROOT / '.scratch') as scratch:
        directory = Path(scratch)
        repo = directory / 'source'
        checked(['git', 'init', '-b', 'main', repo])
        def git(*argv):
            return checked(['git', '-C', repo, *argv])
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        (repo / '.gitignore').write_text('ignored/\n*.tmp\n')
        (repo / 'tracked').write_text('hello\n')
        (repo / 'src').mkdir()
        (repo / 'src/code.zig').write_text('const value = 1;\n')
        git('add', '.')
        git('commit', '-m', 'first')
        git('tag', 'v1.0.0')
        initial = git('rev-parse', 'HEAD').strip()
        for i in range(12):
            (repo / 'tracked').write_text(('hello\n' * 200) + str(i) + '\n')
            git('add', 'tracked')
            git('commit', '-m', f'change {i}', '-m', 'body\nline two')
        git('tag', '-a', 'v1.1.0', '-m', 'release')
        checked(['git', '-C', repo, 'tag', '-a', 'v1.1.1', '-m', 'newer annotated alias'], env=dict(os.environ, GIT_COMMITTER_DATE='1900000000 +0000'))
        git('branch', 'other', initial.decode())
        checked(['git', 'clone', '--bare', repo, directory / 'remote.git'])
        git('remote', 'add', 'origin', str(directory / 'remote.git'))
        git('fetch', 'origin')
        git('gc', '--prune=now')
        worktree_repo = directory / 'linked-worktree'
        git('worktree', 'add', '-b', 'linked', str(worktree_repo), 'main')
        assert checked([binary, '-C', worktree_repo, 'rev-parse', 'HEAD']) == git('rev-parse', 'HEAD')
        assert checked([binary, '-C', worktree_repo, 'status', '--porcelain']) == b''
        total = 2
        def compare(*argv, returncode=0, sorted_lines=False):
            nonlocal total
            expected = run(['git', '-C', repo, *argv])
            actual = run([binary, '-C', repo, *argv])
            left, right = expected.stdout, actual.stdout
            if sorted_lines:
                left, right = sorted(left.splitlines()), sorted(right.splitlines())
            assert expected.returncode == actual.returncode == returncode, (argv, expected.returncode, actual.returncode, actual.stderr)
            assert left == right, (argv, expected.stdout, actual.stdout, actual.stderr)
            total += 1
        compare('rev-parse', 'HEAD')
        compare('rev-parse', '--abbrev-ref', 'HEAD')
        compare('rev-parse', 'origin/main')
        compare('branch', '--list', '--no-color')
        compare('branch', '--no-color')
        compare('rev-list', '--tags', '--max-count=1')
        compare('remote')
        compare('remote', 'get-url', 'origin')
        compare('config', '--get', 'remote.origin.url')
        compare('config', '--get', 'missing.key', returncode=1)
        compare('status', '--porcelain', '-b')
        compare('cat-file', '-e', initial[:8].decode() + '^{commit}')
        compare('cat-file', '-e', 'v1.1.0^{commit}')
        compare('rev-list', 'HEAD', '--count')
        compare('rev-list', 'other..HEAD', '--count')
        compare('merge-base', '--is-ancestor', 'other', 'HEAD')
        compare('merge-base', '--is-ancestor', 'HEAD', 'other', returncode=1)
        compare('cat-file', '-e', 'HEAD^{commit}')
        compare('describe', '--tags', '--always', '--long', '--dirty', '--abbrev=8')
        compare('describe', '--tags', 'other', '--always')
        compare('log', 'other..HEAD', f'--format={LOG_FORMAT}', '--max-count=100')
        compare('for-each-ref', '--count=100', '--sort=-creatordate', '--contains=other', '--merged=HEAD', f'--format={REF_FORMAT}', 'refs/tags')
        compare('status', '--porcelain')
        (repo / 'tracked').write_text('dirty\n')
        compare('status', '--porcelain')
        compare('describe', '--tags', '--always', '--long', '--dirty')
        (repo / 'extra.zig').write_text('untracked\n')
        (repo / 'ignored').mkdir()
        (repo / 'ignored/file').write_text('preserve\n')
        (repo / 'new-dir').mkdir()
        (repo / 'new-dir/file.zig').write_text('new\n')
        (repo / 'space name').write_text('quoted\n')
        (repo / 'line\nname').write_text('quoted\n')
        (repo / 'café.zig').write_text('quoted\n')
        compare('status', '--porcelain', sorted_lines=True)
        compare('status', '--porcelain', '--ignored')
        checked([binary, '-C', repo, 'checkout', '-q', '--', '.'])
        assert (repo / 'tracked').read_text() != 'dirty\n'
        checked([binary, '-C', repo, 'clean', '-fd'])
        assert not (repo / 'extra.zig').exists()
        assert (repo / 'ignored/file').exists()
        checked([binary, '-C', repo, 'reset', '--hard', initial.decode()])
        compare('status', '--porcelain')
        compare('rev-parse', 'HEAD')
        checked([binary, '-C', repo, 'checkout', 'other'])
        compare('rev-parse', '--abbrev-ref', 'HEAD')
        checked([binary, '-C', repo, 'fsck', '--full'])
        total += 4
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.backend()
            def do_POST(self):
                self.backend()
            def log_message(self, *unused):
                pass
            def backend(self):
                path, _, query = self.path.partition('?')
                env = dict(os.environ, GIT_PROJECT_ROOT=str(directory), GIT_HTTP_EXPORT_ALL='1',
                           PATH_INFO=path, QUERY_STRING=query, REQUEST_METHOD=self.command,
                           CONTENT_TYPE=self.headers.get('Content-Type', ''),
                           CONTENT_LENGTH=self.headers.get('Content-Length', '0'))
                body = self.rfile.read(int(env['CONTENT_LENGTH']))
                result = subprocess.run(['git', 'http-backend'], input=body, env=env, capture_output=True)
                head, payload = result.stdout.split(b'\r\n\r\n', 1)
                headers = [line.split(b':', 1) for line in head.split(b'\r\n')]
                status = next((int(value.strip().split()[0]) for key, value in headers if key.lower() == b'status'), 200)
                self.send_response(status)
                for key, value in headers:
                    if key.lower() != b'status':
                        self.send_header(key.decode(), value.strip().decode())
                self.end_headers()
                self.wfile.write(payload)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            checked(['git', '--git-dir', directory / 'remote.git', 'config', 'uploadpack.allowFilter', 'true'])
            checked(['git', '--git-dir', directory / 'remote.git', 'config', 'uploadpack.allowAnySHA1InWant', 'true'])
            url = f'http://127.0.0.1:{server.server_port}/remote.git'
            destination = directory / 'clone'
            checked([binary, 'clone', '--branch', 'main', '--filter=blob:none', url, destination])
            assert checked(['git', '-C', destination, 'rev-parse', 'HEAD']) == checked(['git', '--git-dir', directory / 'remote.git', 'rev-parse', 'main'])
            checked(['git', '-C', destination, 'fsck', '--full'])
            assert (destination / 'tracked').exists()
            checked([binary, '-C', destination, 'fetch', 'origin', '--prune', '--progress'])
            checked([binary, '-C', destination, 'pull', '--progress'])
            checked([binary, '-C', destination, 'checkout', 'origin/main'])
            assert checked([binary, '-C', destination, 'branch', '--list', '--no-color']) == checked(['git', '-C', destination, 'branch', '--list', '--no-color'])
            checked([binary, '-C', destination, 'checkout', 'main'])
            tracked_status = run([binary, '-C', destination, 'status', '--porcelain', '-b'])
            assert tracked_status.stdout == checked(['git', '-C', destination, 'status', '--porcelain', '-b'])
            git('reset', '--hard', 'origin/main')
            (repo / 'tracked').write_text('network update\n')
            (repo / 'src/code.zig').chmod(0o755)
            (repo / 'link').symlink_to('tracked')
            git('add', '.')
            git('commit', '-m', 'network update')
            git('push', '--force', 'origin', 'HEAD:main')
            checked([binary, '-C', destination, 'fetch', '--all', '-p'])
            checked([binary, '-C', destination, 'pull', '--progress'])
            assert (destination / 'tracked').read_text() == 'network update\n'
            assert (destination / 'link').is_symlink()
            assert (destination / 'src/code.zig').stat().st_mode & 0o111
            assert checked(['git', '-C', destination, 'status', '--porcelain']) == b''
            checked(['git', '-C', destination, 'pack-refs', '--all'])
            checked(['git', '--git-dir', directory / 'remote.git', 'update-ref', '-d', 'refs/heads/other'])
            checked([binary, '-C', destination, 'fetch', 'origin', '--prune'])
            assert run(['git', '-C', destination, 'show-ref', '--verify', 'refs/remotes/origin/other']).returncode != 0
            checked([binary, '-C', destination, 'remote', 'set-url', 'origin', url])
            assert checked([binary, '-C', destination, 'remote', 'get-url', 'origin']).strip() == url.encode()
            (destination / 'untracked.zig').write_text('delete me\n')
            (destination / 'nested').mkdir()
            checked(['git', 'init', destination / 'nested'])
            checked([binary, '-C', destination, 'clean', '-fd'])
            assert not (destination / 'untracked.zig').exists()
            assert (destination / 'nested/.git').is_dir()
            original_config = (destination / '.git/config').read_bytes()
            original_head = checked(['git', '-C', destination, 'rev-parse', 'HEAD'])
            head_path = destination / '.git/HEAD'
            head_bytes = head_path.read_bytes()
            head_path.write_text('invalid-head\n')
            assert run([binary, '-C', destination, 'fsck', '--full']).returncode != 0
            head_path.write_bytes(head_bytes)
            tracked_before = (destination / 'tracked').read_bytes()
            blob = checked(['git', '-C', destination, 'hash-object', '-w', 'tracked']).strip()
            tree_bytes = b'100644 .git\0' + bytes.fromhex(blob.decode())
            bad_tree = subprocess.run(['git', '-C', str(destination), 'hash-object', '--literally', '-w', '-t', 'tree', '--stdin'], input=tree_bytes, capture_output=True, check=True).stdout.strip()
            bad_commit = checked(['git', '-C', destination, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit-tree', bad_tree.decode(), '-m', 'unsafe tree']).strip()
            rejected = run([binary, '-C', destination, 'reset', '--hard', bad_commit.decode()])
            assert rejected.returncode != 0
            assert (destination / '.git/config').read_bytes() == original_config
            assert (destination / 'tracked').read_bytes() == tracked_before
            assert checked(['git', '-C', destination, 'rev-parse', 'HEAD']) == original_head
            assert not (destination / '.git/index.lock').exists()
            assert run([binary, '-C', destination, 'fsck', '--full']).returncode != 0
            for command in ['init', 'add', 'commit', 'push', 'merge', 'rebase', 'tag']:
                assert run([binary, command]).returncode != 0
            total += 20
        finally:
            server.shutdown()
            worker.join()
            server.server_close()
        print(f'{total} conformance checks passed')

if __name__ == '__main__':
    main()
