#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build, validate and package the two supported static Linux release profiles."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
MAX_BINARY = 16 * 1024 * 1024
PROFILES = {
    'x86_64': ('x86_64-linux-musl', 'baseline', 'x86_64-linux-musl', 2, 62),
    'armv7': ('arm-linux-musleabihf', 'cortex_a7', 'armv7-cortex-a7-linux-musleabihf', 1, 40),
}
DOCUMENTS = ('README.md', 'LICENSE', 'ZIG_LICENSE', 'docs/CONTRACT.md')
MEMBERS = {'bin/ugit', 'BUILD.json', *DOCUMENTS}


def version():
    text = (ROOT / 'build.zig.zon').read_text()
    match = re.search(r'^\s*\.version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', text, re.MULTILINE)
    if match is None:
        raise ValueError('build.zig.zon must contain a stable semantic version')
    return match[1]


def asset_name(profile):
    return f'ugit-v{version()}-{PROFILES[profile][2]}.tar.gz'


def validate_elf(data, profile):
    if len(data) < 64 or len(data) > MAX_BINARY or data[:4] != b'\x7fELF':
        raise ValueError('invalid or oversized ELF binary')
    elf_class, machine = PROFILES[profile][3:]
    if data[4] != elf_class or data[5:7] != b'\x01\x01':
        raise ValueError('incorrect ELF class, byte order or version')
    if struct.unpack_from('<HH', data, 16) != (2, machine):
        raise ValueError('incorrect ELF executable type or machine')
    if elf_class == 2:
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phsize, phcount = struct.unpack_from('<HH', data, 54)
        minimum_phsize = 56
    else:
        phoff = struct.unpack_from('<I', data, 28)[0]
        phsize, phcount = struct.unpack_from('<HH', data, 42)
        minimum_phsize = 32
        flags = struct.unpack_from('<I', data, 36)[0]
        if not flags & 0x400 or flags & 0x200:
            raise ValueError('printer binary must use the hard-float ABI')
    if not phcount or phcount > 1024 or phsize < minimum_phsize:
        raise ValueError('invalid ELF program header table')
    if phoff + phsize * phcount > len(data):
        raise ValueError('truncated ELF program header table')
    for index in range(phcount):
        kind = struct.unpack_from('<I', data, phoff + index * phsize)[0]
        if kind in (2, 3):  # PT_DYNAMIC / PT_INTERP
            raise ValueError('release binary must be static without a loader')


def source_commit():
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def build(profile, output):
    if subprocess.check_output(['zig', 'version'], text=True).strip() != '0.17.0':
        raise ValueError('release builds require Zig 0.17.0')
    output.mkdir(parents=True, exist_ok=True)
    prefix = ROOT / '.scratch' / 'release-build' / profile
    target, cpu = PROFILES[profile][:2]
    subprocess.run(['zig', 'build', f'-Dtarget={target}', f'-Dcpu={cpu}',
                    '-Doptimize=ReleaseSmall', '-j2', '--prefix', str(prefix)], cwd=ROOT, check=True)
    executable = prefix / 'bin/ugit'
    if executable.stat().st_size > MAX_BINARY:
        raise ValueError('oversized release binary')
    binary = executable.read_bytes()
    validate_elf(binary, profile)
    metadata = json.dumps({
        'version': version(), 'profile': profile, 'target': target, 'cpu': cpu,
        'zig': '0.17.0', 'commit': source_commit(),
    }, sort_keys=True, indent=2).encode() + b'\n'
    files = {'bin/ugit': binary, 'BUILD.json': metadata}
    files.update({name: (ROOT / name).read_bytes() for name in DOCUMENTS})
    archive = output / asset_name(profile)
    # Fixed metadata and gzip time make packaging deterministic for equal inputs.
    with archive.open('wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as tar:
                for name, content in sorted(files.items()):
                    entry = tarfile.TarInfo(name)
                    entry.size = len(content)
                    entry.mode = 0o755 if name == 'bin/ugit' else 0o644
                    tar.addfile(entry, io.BytesIO(content))
    verify_archive(archive, profile)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_name(archive.name + '.sha256').write_text(f'{digest}  {archive.name}\n')
    print(archive)


def verify_archive(archive, profile):
    if archive.stat().st_size > MAX_BINARY * 2:
        raise ValueError('oversized release archive')
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        if len(members) != len(MEMBERS) or {item.name for item in members} != MEMBERS:
            raise ValueError('incorrect release archive members')
        for item in members:
            if not item.isfile() or item.size > MAX_BINARY:
                raise ValueError('release members must be bounded regular files')
        metadata = json.load(tar.extractfile('BUILD.json'))
        if metadata['version'] != version() or metadata['profile'] != profile:
            raise ValueError('incorrect release version/profile')
        if (metadata['target'], metadata['cpu']) != PROFILES[profile][:2] or metadata['zig'] != '0.17.0':
            raise ValueError('incorrect release toolchain/target')
        if not re.fullmatch(r'[0-9a-f]{40}', metadata['commit']):
            raise ValueError('invalid source commit')
        if tar.getmember('bin/ugit').mode != 0o755:
            raise ValueError('release binary must be executable')
        binary = tar.extractfile('bin/ugit').read()
        validate_elf(binary, profile)
        return binary, metadata['commit']


def verify_bundle(directory):
    expected = {asset_name(profile) for profile in PROFILES}
    if {item.name for item in directory.glob('*.tar.gz')} != expected:
        raise ValueError('release bundle must contain exactly both supported profiles')
    lines = []
    commits = set()
    for profile in PROFILES:
        archive = directory / asset_name(profile)
        _, commit = verify_archive(archive, profile)
        commits.add(commit)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        line = f'{digest}  {archive.name}\n'
        if archive.with_name(archive.name + '.sha256').read_text() != line:
            raise ValueError('release checksum mismatch')
        lines.append(line)
    if len(commits) != 1:
        raise ValueError('release profiles come from different source commits')
    if commits != {source_commit()}:
        raise ValueError('release source commit does not match the checkout')
    checksum_file = directory / 'SHA256SUMS'
    expected_checksums = ''.join(sorted(lines))
    if checksum_file.exists() and checksum_file.read_text() != expected_checksums:
        raise ValueError('bundle checksum manifest mismatch')
    checksum_file.write_text(expected_checksums)


def check_tag(tag):
    if tag != f'v{version()}':
        raise ValueError('release tag must match build.zig.zon')
    if not (ROOT / 'docs/releases' / f'{tag}.md').is_file():
        raise ValueError('release notes are required')
    ref = f'refs/tags/{tag}'
    kind = subprocess.check_output(['git', 'cat-file', '-t', ref], cwd=ROOT, text=True).strip()
    if kind != 'tag':
        raise ValueError('release tag must be annotated')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT)
    if subprocess.check_output(['git', 'rev-parse', ref + '^{commit}'], cwd=ROOT) != head:
        raise ValueError('release tag must identify the checked-out commit')
    subprocess.run(['git', 'merge-base', '--is-ancestor', 'HEAD', 'origin/main'], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    build_parser = commands.add_parser('build')
    build_parser.add_argument('profile', choices=PROFILES)
    build_parser.add_argument('--output', type=Path, required=True)
    verify_parser = commands.add_parser('verify')
    verify_parser.add_argument('directory', type=Path)
    extract_parser = commands.add_parser('extract-native')
    extract_parser.add_argument('directory', type=Path)
    extract_parser.add_argument('--output', type=Path, required=True)
    tag_parser = commands.add_parser('check-tag')
    tag_parser.add_argument('tag')
    args = parser.parse_args()
    if args.command == 'build':
        build(args.profile, args.output)
    elif args.command == 'verify':
        verify_bundle(args.directory)
    elif args.command == 'check-tag':
        check_tag(args.tag)
    else:
        binary, _ = verify_archive(args.directory / asset_name('x86_64'), 'x86_64')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(binary)
        args.output.chmod(0o755)


if __name__ == '__main__':
    main()
