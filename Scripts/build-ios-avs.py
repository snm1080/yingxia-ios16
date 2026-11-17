#!/usr/bin/env python3
"""Build pinned AVS2/AVS3 static libraries offline for iOS 16.2.

The default is iPhoneOS arm64. Simulator targets require --platform
iphonesimulator and an explicit architecture; no app, signing or Xcode build
is performed. All source adaptations and outputs stay under project build/.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/AVSNative'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, *, cwd=None, env=None, log: Path | None = None) -> str:
    command = [str(value) for value in args]
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.with_suffix('.command.json').write_text(json.dumps(command, indent=2) + '\n')
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=cwd, env=env, text=True,
                                    stdout=stream, stderr=subprocess.STDOUT)
        output = log.read_text()
    else:
        result = subprocess.run(command, cwd=cwd, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = result.stdout
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {command}\n' + '\n'.join(output.splitlines()[-35:]))
    return output.strip()


def extract(archive: Path, destination: Path) -> None:
    temporary = destination.with_name(destination.name + '.extract')
    temporary.mkdir()
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if not (temporary / member.name).resolve().is_relative_to(temporary.resolve()):
                raise RuntimeError(f'Unsafe archive path: {member.name}')
            if member.issym() or member.islnk():
                raise RuntimeError(f'Unexpected source archive link: {member.name}')
        source.extractall(temporary)
    members = list(temporary.iterdir())
    if len(members) != 1 or not members[0].is_dir():
        raise RuntimeError(f'Expected one source directory in {archive}')
    members[0].rename(destination)
    temporary.rmdir()


def validate_archive(archive: Path, arch: str, sdk_name: str, required: list[str], work: Path) -> dict:
    if run(['lipo', '-archs', archive]) != arch:
        raise RuntimeError(f'Wrong architecture: {archive}')
    symbols = run(['nm', '-gU', archive], log=work / 'logs' / (archive.stem + '-symbols.log'))
    for symbol in required:
        if not re.search(r'\b[TDS] _' + re.escape(symbol) + r'$', symbols, re.MULTILINE):
            raise RuntimeError(f'Missing implementation {symbol} in {archive}')
    if re.search(r'\bT _(?:JNI_|Java_)', symbols):
        raise RuntimeError(f'Unexpected Java execution implementation in {archive}')
    member = next(value for value in run(['ar', '-t', archive]).splitlines() if value.endswith('.o'))
    obj = work / (archive.stem + '-metadata.o')
    obj.write_bytes(subprocess.check_output(['ar', '-p', str(archive), member]))
    metadata = run(['xcrun', 'vtool', '-show-build', obj])
    expected = 'IOS' if sdk_name == 'iphoneos' else 'IOSSIMULATOR'
    if not re.search(r'platform\s+' + expected + r'\s*\n', metadata) or not re.search(r'minos\s+16\.2\s*\n', metadata):
        raise RuntimeError(f'Wrong iOS deployment metadata:\n{metadata}')
    return {'sha256': sha(archive), 'bytes': archive.stat().st_size,
            'architecture': arch, 'platform': expected, 'minimum_os': '16.2',
            'required_symbols': required, 'build_metadata': metadata}


def build(prefix: Path, sdk_name: str, arch: str, jobs: int) -> None:
    if sdk_name == 'iphoneos' and arch != 'arm64':
        raise RuntimeError('The iPhoneOS dependency target must be arm64')
    if not prefix.is_relative_to(ROOT / 'build') or len(prefix.relative_to(ROOT / 'build').parts) < 2:
        raise RuntimeError('AVS output prefix must be a dedicated directory inside project build/')
    inventory = json.loads((VENDOR / 'SOURCE-INVENTORY.json').read_text())
    for item in inventory['files']:
        if sha(VENDOR / item['path']) != item['sha256']:
            raise RuntimeError('Pinned AVS input changed: ' + item['path'])
    sdk = run(['xcrun', '--sdk', sdk_name, '--show-sdk-path'])
    cc = run(['xcrun', '--sdk', sdk_name, '--find', 'clang'])
    cxx = run(['xcrun', '--sdk', sdk_name, '--find', 'clang++'])
    target = f'{arch}-apple-ios16.2' + ('-simulator' if sdk_name == 'iphonesimulator' else '')
    fingerprint = hashlib.sha256(Path(__file__).read_bytes())
    for path in sorted(VENDOR.rglob('*')):
        if path.is_file():
            fingerprint.update(str(path.relative_to(VENDOR)).encode())
            fingerprint.update(path.read_bytes())
    fingerprint.update((sdk + target + run([cc, '--version'])).encode())
    signature = fingerprint.hexdigest()
    manifest = prefix / 'build-manifest.json'
    if manifest.is_file():
        saved = json.loads(manifest.read_text())
        if saved.get('signature') == signature and saved.get('outputs') and all(
            (prefix / name).is_file() and sha(prefix / name) == checksum
            for name, checksum in saved['outputs'].items()
        ):
            print(f'AVS native dependencies are up to date: {prefix}', flush=True)
            return

    prefix.parent.mkdir(parents=True, exist_ok=True)
    lock = prefix.with_name(prefix.name + '.lock')
    try:
        lock.mkdir()
    except FileExistsError as exc:
        raise RuntimeError(f'Another AVS build is using {prefix}; inspect {lock}') from exc
    work = prefix.with_name(prefix.name + '.work')
    partial = prefix.with_name(prefix.name + '.partial')
    try:
        for path in [work, partial]:
            shutil.rmtree(path, ignore_errors=True)
            path.mkdir()
        (partial / 'lib/pkgconfig').mkdir(parents=True)
        (partial / 'include').mkdir()
        davs = work / 'davs2'
        uavs = work / 'uavs3d'
        extract(VENDOR / 'sources/davs2.tar.gz', davs)
        extract(VENDOR / 'sources/uavs3d.tar.gz', uavs)
        for path in (davs / 'source').rglob('*'):
            if path.is_file() and path.suffix in {'.cc', '.c', '.h'}:
                path.write_bytes(path.read_bytes().replace(b'\r\n', b'\n'))
        for item in inventory['files']:
            if item['path'].startswith('patches/'):
                run(['patch', '-p1', '-i', VENDOR / item['path']], cwd=davs,
                    log=work / 'logs' / (item['name'] + '.log'))
        # Upstream embeds wall-clock time. Keep generated build metadata stable.
        version = davs / 'version.sh'
        version.write_text(version.read_text().replace('BUILD_TIME=`date "+%Y-%m-%d %H:%M:%S"`',
                                                       'BUILD_TIME="pinned-source"')
                           .replace("VER_SHA='not-in-git-tree'", "VER_SHA='21d64c8f8e36af71'"))
        flags = f'-target {target} -isysroot {sdk} -fPIC'
        env = dict(os.environ, CC=cxx, ZERO_AR_DATE='1')
        run(['bash', 'configure', f'--prefix={partial}', '--disable-cli', '--enable-pic',
             '--disable-asm', '--bit-depth=10',
             '--host=' + ('aarch64' if arch == 'arm64' else arch) + '-apple-darwin',
             '--extra-cflags=' + flags, '--extra-ldflags=' + flags],
            cwd=davs / 'build/linux', env=env, log=work / 'logs/davs2-configure.log')
        run(['make', '-j', jobs, 'install-lib-static'], cwd=davs / 'build/linux', env=env,
            log=work / 'logs/davs2-make.log')
        # The source accepts both 8/10-bit samples with this 10-bit build.
        (uavs / 'version.h').write_text(
            '#define VER_MAJOR 1\n#define VER_MINOR 2\n#define VER_BUILD 0\n'
            '#define VERSION_TYPE "release"\n#define VERSION_STR "1.2.0"\n'
            '#define VERSION_SHA1 "0e20d2c291853f196c68922a264bcd8471d75b68"\n')
        files = sorted((uavs / 'source/decoder').glob('*.c')) + sorted((uavs / 'source/decore').glob('*.c'))
        if arch == 'arm64':
            files += sorted((uavs / 'source/decore/arm64').glob('*.c')) + sorted((uavs / 'source/decore/arm64').glob('*.S'))
        else:
            files += sorted((uavs / 'source/decore/sse').glob('*.c')) + sorted((uavs / 'source/decore/avx2').glob('*.c'))
        objects = work / 'uavs3d-objects'
        objects.mkdir()
        def compile_one(source: Path) -> Path:
            obj = objects / ('_'.join(source.relative_to(uavs).parts) + '.o')
            command = [cc, '-target', target, '-isysroot', sdk, '-O2', '-fPIC',
                       '-D__MACOSX__', '-DCOMPILE_10BIT=1', '-I', uavs / 'source/decore']
            if source.suffix == '.c':
                command += ['-std=c99']
            if '/sse/' in str(source):
                command += ['-msse4.2']
            if '/avx2/' in str(source):
                command += ['-mavx2']
            if arch == 'arm64':
                command += ['-D_arm64']
            run([*command, '-c', source, '-o', obj], log=work / 'logs' / (obj.stem + '.log'))
            return obj
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            object_files = list(pool.map(compile_one, files))
        run(['xcrun', '--sdk', sdk_name, 'libtool', '-static', '-no_warning_for_no_symbols',
             '-o', partial / 'lib/libuavs3d.a', *object_files], env=env,
            log=work / 'logs/uavs3d-archive.log')
        shutil.copy2(uavs / 'source/decoder/uavs3d.h', partial / 'include/uavs3d.h')
        for name, version in [('davs2', '1.6.0'), ('uavs3d', '1.2.0')]:
            (partial / f'lib/pkgconfig/{name}.pc').write_text(
                f'prefix={prefix}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\n'
                f'Name: {name}\nDescription: Native AVS video decoder\nVersion: {version}\n'
                f'Libs: -L${{libdir}} -l{name} -lm -lpthread\n'
                + ('Libs.private: -lc++\n' if name == 'davs2' else '')
                + 'Cflags: -I${includedir}\n')
        # Force every object into a disposable image so missing dependencies fail now.
        run([cxx, '-target', target, '-isysroot', sdk, '-dynamiclib', '-Wl,-all_load',
             partial / 'lib/libdavs2.a', partial / 'lib/libuavs3d.a', '-lm',
             '-o', work / 'dependency-link.dylib'], log=work / 'logs/dependency-link.log')
        dependencies = run(['otool', '-L', work / 'dependency-link.dylib'])
        for line in dependencies.splitlines()[2:]:
            dependency = line.strip().split(' ', 1)[0]
            if dependency not in ['/usr/lib/libc++.1.dylib', '/usr/lib/libSystem.B.dylib']:
                raise RuntimeError('Unexpected AVS link dependency: ' + dependency)
        libraries = {}
        for name, required in [('davs2', ['davs2_decoder_open', 'davs2_decoder_send_packet', 'davs2_decoder_recv_frame']),
                               ('uavs3d', ['uavs3d_create', 'uavs3d_decode', 'uavs3d_delete'])]:
            libraries[name] = validate_archive(partial / f'lib/lib{name}.a', arch, sdk_name, required, work)
        outputs = {str(path.relative_to(partial)): sha(path) for path in sorted(partial.rglob('*')) if path.is_file()}
        (partial / 'build-manifest.json').write_text(json.dumps({
            'signature': signature, 'target': target, 'source_inventory_sha256': sha(VENDOR / 'SOURCE-INVENTORY.json'),
            'libraries': libraries, 'outputs': outputs, 'bit_depth': 10, 'all_objects_linked': True,
            'link_dependencies': dependencies, 'java': False, 'device_runtime_verified': False,
            'licenses': {'davs2': 'GPL-2.0-or-later', 'uavs3d': 'BSD-3-Clause'},
        }, indent=2) + '\n')
        shutil.rmtree(prefix, ignore_errors=True)
        partial.rename(prefix)
        print(f'AVS2/AVS3 native dependencies built: {target} -> {prefix}', flush=True)
    finally:
        lock.rmdir()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['iphoneos', 'iphonesimulator'], default='iphoneos')
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--prefix', type=Path)
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if args.platform == 'iphoneos' and args.arch != 'arm64':
        parser.error('iPhoneOS supports only arm64 in this local edition')
    default = ROOT / 'build/AVSNative' / ('iphoneos' if args.platform == 'iphoneos' else 'iphonesimulator-' + args.arch)
    prefix = (args.prefix or default).absolute()
    if prefix.is_symlink() or prefix.with_name(prefix.name + '.work').is_symlink():
        parser.error('AVS output/work directory must not be a symlink')
    build(prefix.resolve(), args.platform, args.arch, max(1, min(args.jobs, 4)))


if __name__ == '__main__':
    main()
