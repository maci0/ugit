# SPDX-License-Identifier: GPL-3.0-only
"""Release validation rejects mismatched, dynamic and malformed assets."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def elf(profile):
    data = bytearray(128)
    elf_class, machine = release.PROFILES[profile][3:]
    data[:7] = b'\x7fELF' + bytes((elf_class, 1, 1))
    struct.pack_into('<HH', data, 16, 2, machine)
    if elf_class == 2:
        struct.pack_into('<Q', data, 32, 64)
        struct.pack_into('<HH', data, 54, 56, 1)
        struct.pack_into('<I', data, 64, 1)
    else:
        struct.pack_into('<I', data, 28, 52)
        struct.pack_into('<I', data, 36, 0x5000400)
        struct.pack_into('<HH', data, 42, 32, 1)
        struct.pack_into('<I', data, 52, 1)
    return data


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '.scratch').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='release-tests-', dir=ROOT / '.scratch')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        commit_patch = patch.object(release, 'source_commit', return_value='a' * 40)
        commit_patch.start()
        self.addCleanup(commit_patch.stop)

    def archive(self, profile, *, commit='a' * 40, extra=None, version=None):
        target, cpu = release.PROFILES[profile][:2]
        files = {name: b'license or documentation\n' for name in release.DOCUMENTS}
        files['bin/ugit'] = elf(profile)
        files['BUILD.json'] = json.dumps({
            'version': version or release.version(), 'profile': profile,
            'target': target, 'cpu': cpu, 'zig': '0.17.0', 'commit': commit,
        }).encode()
        if extra:
            files.update(extra)
        path = self.directory / release.asset_name(profile)
        with tarfile.open(path, 'w:gz') as tar:
            for name, data in files.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                entry.mode = 0o755 if name == 'bin/ugit' else 0o644
                tar.addfile(entry, io.BytesIO(data))
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name + '.sha256').write_text(f'{checksum}  {path.name}\n')
        return path

    def test_both_static_profiles(self):
        for profile in release.PROFILES:
            release.validate_elf(elf(profile), profile)
            release.verify_archive(self.archive(profile), profile)
        release.verify_bundle(self.directory)
        self.assertEqual(len((self.directory / 'SHA256SUMS').read_text().splitlines()), 2)

    def test_dynamic_loader_rejected(self):
        for kind in (2, 3):
            data = elf('x86_64')
            struct.pack_into('<I', data, 64, kind)
            with self.assertRaisesRegex(ValueError, 'static'):
                release.validate_elf(data, 'x86_64')

    def test_wrong_machine_and_abi_rejected(self):
        with self.assertRaises(ValueError):
            release.validate_elf(elf('x86_64'), 'armv7')
        data = elf('armv7')
        struct.pack_into('<I', data, 36, 0x5000200)
        with self.assertRaisesRegex(ValueError, 'hard-float'):
            release.validate_elf(data, 'armv7')

    def test_truncated_program_headers_rejected(self):
        data = elf('x86_64')
        struct.pack_into('<Q', data, 32, 1024)
        with self.assertRaisesRegex(ValueError, 'truncated'):
            release.validate_elf(data, 'x86_64')

    def test_missing_profile_rejected(self):
        self.archive('x86_64')
        with self.assertRaisesRegex(ValueError, 'both supported'):
            release.verify_bundle(self.directory)

    def test_checksum_mismatch_rejected(self):
        self.archive('armv7')
        path = self.archive('x86_64')
        path.with_name(path.name + '.sha256').write_text('wrong\n')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            release.verify_bundle(self.directory)

    def test_different_source_commits_rejected(self):
        self.archive('armv7')
        self.archive('x86_64', commit='b' * 40)
        with self.assertRaisesRegex(ValueError, 'different source commits'):
            release.verify_bundle(self.directory)

    def test_same_but_wrong_source_commit_rejected(self):
        for profile in release.PROFILES:
            self.archive(profile, commit='b' * 40)
        with self.assertRaisesRegex(ValueError, 'does not match the checkout'):
            release.verify_bundle(self.directory)

    def test_wrong_version_and_traversal_rejected(self):
        with self.assertRaisesRegex(ValueError, 'version/profile'):
            release.verify_archive(self.archive('x86_64', version='999.0.0'), 'x86_64')
        with self.assertRaisesRegex(ValueError, 'archive members'):
            release.verify_archive(self.archive('x86_64', extra={'../escape': b'bad'}), 'x86_64')
        self.assertFalse((self.directory.parent / 'escape').exists())

    def test_manifest_tampering_rejected(self):
        for profile in release.PROFILES:
            self.archive(profile)
        (self.directory / 'SHA256SUMS').write_text('tampered\n')
        with self.assertRaisesRegex(ValueError, 'manifest mismatch'):
            release.verify_bundle(self.directory)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', self.directory, *args], stderr=subprocess.PIPE)

    def tag_repository(self):
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        (self.directory / 'build.zig.zon').write_text('.{ .name = .ugit,\n .version = "0.1.0",\n}\n')
        notes = self.directory / 'docs/releases'
        notes.mkdir(parents=True)
        (notes / 'v0.1.0.md').write_text('release notes\n')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')

    def test_dirty_source_rejected(self):
        self.tag_repository()
        with patch.object(release, 'ROOT', self.directory):
            release.require_clean_source()
            (self.directory / 'uncommitted.zig').write_text('not the recorded source\n')
            with self.assertRaisesRegex(ValueError, 'clean source checkout'):
                release.require_clean_source()

    def test_annotated_matching_tag(self):
        self.tag_repository()
        self.git('tag', '-a', 'v0.1.0', '-m', 'release')
        with patch.object(release, 'ROOT', self.directory):
            release.check_tag('v0.1.0')
            with self.assertRaisesRegex(ValueError, 'match build.zig.zon'):
                release.check_tag('v0.2.0')

    def test_lightweight_tag_rejected(self):
        self.tag_repository()
        self.git('tag', 'v0.1.0')
        with patch.object(release, 'ROOT', self.directory):
            with self.assertRaisesRegex(ValueError, 'annotated'):
                release.check_tag('v0.1.0')

    def test_tag_from_unmerged_commit_rejected(self):
        self.tag_repository()
        (self.directory / 'new').write_text('unmerged\n')
        self.git('add', '.')
        self.git('commit', '-m', 'unmerged')
        self.git('tag', '-a', 'v0.1.0', '-m', 'release')
        with patch.object(release, 'ROOT', self.directory):
            with self.assertRaises(subprocess.CalledProcessError):
                release.check_tag('v0.1.0')


if __name__ == '__main__':
    unittest.main()
