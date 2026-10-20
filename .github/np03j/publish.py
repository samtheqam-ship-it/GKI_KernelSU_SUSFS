#!/usr/bin/env python3
"""Publish only a complete, verified NP03J pair; never replace previous assets."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from np03j import read_json, require


def gh(*args, capture=False):
    return subprocess.run(['gh', *args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def check_previous(previous, current):
    for key in ('package', 'certificate_sha256', 'certificate_size'):
        require(previous[key] == current[key], f'Persistent manager identity changed: {key}')
    require(current['version_code'] >= previous['version_code'], 'Manager downgrade is not allowed')


def main():
    current = read_json('manager-artifacts/manager-identity.json')
    meta = read_json('kernel-artifacts/kernel-metadata.json')
    require(re.fullmatch(r'[0-9a-f]{40}', os.environ['NP03J_TARGET_SHA']), 'Invalid workflow commit')
    # --paginate returns one JSON array per page; --slurp wraps them unambiguously.
    pages = json.loads(gh('api', '--paginate', '--slurp', 'repos/{owner}/{repo}/releases?per_page=100', capture=True))
    previous = [r for page in pages for r in page
                if r['tag_name'].startswith('np03j-6.1.') and not r['draft'] and not r['prerelease']]
    if previous:
        previous.sort(key=lambda r: r['published_at'], reverse=True)
        with tempfile.TemporaryDirectory(prefix='np03j-identity-') as temp:
            gh('release', 'download', previous[0]['tag_name'], '--pattern', 'manager-identity.json', '--dir', temp)
            check_previous(read_json(Path(temp) / 'manager-identity.json'), current)
    tag = f"np03j-6.1.{meta['sublevel']}-r{int(os.environ['GITHUB_RUN_NUMBER'])}-a{int(os.environ['GITHUB_RUN_ATTEMPT'])}"
    assets = Path('release-assets')
    subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=assets, check=True)
    files = sorted(p for p in assets.iterdir() if p.is_file())
    require(len(files) == 12, 'Incomplete or unexpected release asset set')
    title = f"NP03J · {meta['kernel_release']} · Next Spoofed · 4K"
    gh('release', 'create', tag, '--draft', '--target', os.environ['NP03J_TARGET_SHA'],
       '--title', title, '--notes-file', 'release-notes.md')
    # An upload failure leaves a draft; users never see a partly uploaded release.
    gh('release', 'upload', tag, *(str(p) for p in files))
    gh('release', 'edit', tag, '--draft=false', '--prerelease=false', '--latest')
    url = gh('release', 'view', tag, '--json', 'url', '--jq', '.url', capture=True).strip()
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'NP03J release: {url}\n\nPersistent manager identity and matching kernel verified before publication.\n')


if __name__ == '__main__':
    main()
