#!/usr/bin/env python3
"""Retrieve pinned dependency inputs, preserving their upstream SHA-256 values."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def prepare_av3a(archive):
    vendor = ROOT / 'Vendor/AV3A'
    inventory = json.loads((vendor / 'SOURCE-INVENTORY.json').read_text())
    if all((vendor / item['path']).is_file() and digest(vendor / item['path']) == item['sha256']
           for item in inventory['files']):
        return
    if archive is None:
        raise SystemExit('AV3A reference input is not distributed in this package. Read Vendor/AV3A/UPSTREAM.md, '
                         'obtain the pinned archive under its terms, then pass --av3a-archive /path/to/archive.tar.gz.')
    if digest(archive) != inventory['archive_sha256']:
        raise SystemExit('AV3A archive SHA-256 mismatch')
    with tarfile.open(archive) as source:
        files = {item.name: item for item in source.getmembers() if item.isfile()}
        for item in inventory['files']:
            suffix = '/' + item['upstream_path']
            matches = [member for name, member in files.items() if name.endswith(suffix)]
            if len(matches) != 1:
                raise SystemExit('Missing or ambiguous AV3A member: ' + item['upstream_path'])
            data = source.extractfile(matches[0]).read()
            if hashlib.sha256(data).hexdigest() != item['sha256']:
                raise SystemExit('AV3A source member SHA-256 mismatch: ' + item['path'])
            destination = vendor / item['path']
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--av3a-archive', type=Path, help='Locally obtained pinned AV3A archive; see its upstream terms.')
    args = parser.parse_args()
    prepare_av3a(args.av3a_archive)
    lock = json.loads((ROOT / 'Vendor/dependency-downloads.json').read_text())
    for item in lock['archives']:
        target = ROOT / item['path']
        if not target.resolve().is_relative_to(ROOT):
            raise SystemExit('Invalid dependency path')
        if target.is_file() and digest(target) == item['sha256']:
            print('Ready: ' + item['path'])
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.dependency-', dir=target.parent) as directory:
            temporary = Path(directory) / 'download'
            subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '30',
                            '--max-time', '1800', '--output', str(temporary), item['url']], check=True)
            if digest(temporary) != item['sha256']:
                raise SystemExit('Dependency SHA-256 mismatch: ' + item['path'])
            temporary.replace(target)
        print('Prepared: ' + item['path'])


if __name__ == '__main__':
    main()
