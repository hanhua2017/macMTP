#!/usr/bin/env python3
"""检查工作区中 Git 可发布文件；可导出不含 Git 历史的源码快照。"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--export', type=Path, help='创建新的源码 tar.gz，不包含 .git、忽略文件或个人 owner 元数据')
args = parser.parse_args()

def git(*parts):
    return subprocess.check_output(['git', *parts], cwd=ROOT)

names = sorted(set(filter(None, git('ls-files', '-co', '--exclude-standard', '-z').decode().split('\0'))))
files = [name for name in names if (ROOT / name).is_file() or (ROOT / name).is_symlink()]
local_user = Path.home().name
patterns = {
    'personal-account': re.compile(re.escape(local_user), re.I) if local_user not in ('root', 'runner', 'user') else re.compile(r'(?!)'),
    'personal-home-path': re.compile(r'(?<![A-Za-z0-9_/])/(?:Users|home)/[^/\s`"<>]+', re.I),
    'workspace-path': re.compile(re.escape(str(ROOT))),
    'credential-in-url': re.compile(r'https?://[^\s/@]+:[^\s/@]+@', re.I),
    'private-key': re.compile(r'-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----'),
    'access-token': re.compile(r'\b(?:ghp_|github_pat_|sk_live_)[A-Za-z0-9_]{16,}'),
    'internal-host': re.compile(r'code[.]' + r'iflytek[.]com|ingest[.][^\s/]*sentry', re.I),
}
findings = []

def inspect(label, data, depth=0):
    # Do not print matched values: findings may contain secrets.
    for kind, pattern in patterns.items():
        text = data.decode('utf-8', errors='replace')
        if pattern.search(text):
            findings.append({'file': label, 'kind': kind})
    if label.endswith(('.tar.gz', '.tgz', '.tar.bz2', '.tar')):
        if depth >= 4:
            findings.append({'file': label, 'kind': 'archive-depth-limit'})
            return
        try:
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                for member in archive:
                    inspect(label + '::metadata', (' '.join([member.name, member.linkname, member.uname, member.gname, str(member.pax_headers)])).encode(), depth + 1)
                    if member.isfile():
                        inspect(label + '::' + member.name, archive.extractfile(member).read(), depth + 1)
        except tarfile.TarError:
            findings.append({'file': label, 'kind': 'invalid-archive'})

for name in files:
    path = ROOT / name
    inspect(name + '::filename', name.encode())
    if path.is_symlink():
        inspect(name + '::symlink', os.readlink(path).encode())
        if os.path.isabs(os.readlink(path)):
            findings.append({'file': name, 'kind': 'absolute-symlink'})
    else:
        inspect(name, path.read_bytes())

# Check ignore behavior for hypothetical files, without creating secret files.
ignored_samples = ['.env', '.env.production', '.swiftpm/local-state', '.codex/state.json', '.superpowers/local.md',
                   'test.key', 'test.pem', 'test.p12', '.build/private.txt', 'release/test.dmg',
                   'thirdparty/sources/sample/a.c', 'thirdparty/downloads/a.tar.gz',
                   'thirdparty/build/arm64/a.o', 'thirdparty/runtime/arm64-macos14/lib/a.dylib', 'backups/private.txt']
for name in ignored_samples:
    if subprocess.run(['git', 'check-ignore', '-q', '--', name], cwd=ROOT).returncode:
        findings.append({'file': name, 'kind': 'ignore-rule-missing'})
for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'LICENSES/README.md', 'thirdparty/dependencies.tsv', 'scripts/download.sh', '.env.example']:
    if subprocess.run(['git', 'check-ignore', '-q', '--', name], cwd=ROOT).returncode == 0:
        findings.append({'file': name, 'kind': 'required-public-file-ignored'})
# An ignore rule never removes a file already tracked in the index.
for raw in git('ls-files', '-ci', '--exclude-standard', '-z').decode().split('\0'):
    if raw and (ROOT / raw).exists():
        findings.append({'file': raw, 'kind': 'ignored-but-still-tracked'})

if findings:
    print(json.dumps({'status': 'FAIL', 'findings': findings}, ensure_ascii=False, indent=2))
    raise SystemExit(1)
print(f'PUBLICATION PASS: {len(files)} files scanned; no target personal paths, account identifiers or credential patterns')
print('IGNORE PASS: private files excluded; license texts, dependency manifest and download script retained')

# Audit metadata separately; never rewrite history or expose matching identities.
commits = git('rev-list', '--all').decode().splitlines()
history_count = 0
for commit in commits:
    metadata = git('show', '-s', '--format=%an%x00%ae%x00%cn%x00%ce', commit).decode(errors='replace')
    if patterns['personal-account'].search(metadata):
        history_count += 1
print(f'HISTORY AUDIT: {history_count} of {len(commits)} commits match the local account in author/committer metadata; history is excluded from exports')

if args.export:
    target = args.export.resolve()
    if target.exists():
        parser.error('导出文件已存在，请使用新文件名')
    if target.is_relative_to(ROOT) and not subprocess.run(['git', 'check-ignore', '-q', '--', str(target.relative_to(ROOT))], cwd=ROOT).returncode == 0:
        parser.error('项目内导出必须放在 Git 忽略的目录中')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(target, 'w:gz', format=tarfile.USTAR_FORMAT) as archive:
        for name in files:
            path = ROOT / name
            member = tarfile.TarInfo('macMTP/' + name)
            member.uid = member.gid = 0
            member.uname = member.gname = ''
            member.mtime = 0
            if path.is_symlink():
                member.type = tarfile.SYMTYPE
                member.linkname = os.readlink(path)
                archive.addfile(member)
            else:
                data = path.read_bytes()
                member.size = len(data)
                member.mode = 0o755 if os.access(path, os.X_OK) else 0o644
                archive.addfile(member, io.BytesIO(data))
    with tarfile.open(target) as archive:
        members = archive.getmembers()
        assert len(members) == len(files)
        for member in members:
            assert not member.uname and not member.gname and member.uid == member.gid == 0
            assert '/.git/' not in member.name
            if member.isfile():
                name = member.name.removeprefix('macMTP/')
                assert archive.extractfile(member).read() == (ROOT / name).read_bytes()
    print(f'EXPORT PASS: {len(files)} files reopened and verified; clean owner metadata and no Git history')
    print('EXPORT SHA256: ' + hashlib.sha256(target.read_bytes()).hexdigest())
