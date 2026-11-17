#!/usr/bin/env python3
"""Build the current local source as an unsigned iOS device IPA."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='Check prepared dependencies and print the build command.')
parser.add_argument('--build-number', type=int, help='Override the default latest build number plus one.')
parser.add_argument('--jobs', type=int, help='Parallel build operations (default: physical cores, capped by available RAM and 8).')
args = parser.parse_args()
if args.jobs is not None and not 1 <= args.jobs <= 32:
    parser.error('--jobs must be between 1 and 32')
def sysctl_number(name, fallback):
    try:
        return int(subprocess.check_output(['sysctl', '-n', name], text=True, stderr=subprocess.DEVNULL).strip())
    except (OSError, ValueError, subprocess.CalledProcessError):
        return fallback
physical_cores = sysctl_number('hw.physicalcpu', os.cpu_count() or 4)
memory_bytes = sysctl_number('hw.memsize', 16 * 1024 ** 3)
# Leave room for Xcode/SwiftSyntax while each Swift frontend imports the large
# app module. A user can deliberately override the conservative local default.
memory_jobs = max(1, int(memory_bytes / (1024 ** 3) - 4) // 3)
jobs = args.jobs if args.jobs is not None else max(1, min(8, physical_cores, memory_jobs))
host_arch = platform.machine()
if host_arch not in ('arm64', 'x86_64'):
    parser.error('Unsupported Xcode host architecture: ' + host_arch)
excluded_host_arch = 'arm64' if host_arch == 'x86_64' else 'x86_64'
latest = root / 'artifacts/latest/ipa-delivery.json'
previous = json.loads(latest.read_text()) if latest.exists() else {'build': '0'}
number = args.build_number if args.build_number is not None else int(previous['build']) + 1
if number < 1:
    parser.error('--build-number must be positive')
required = [
    'build/ApplePython/iphoneos/Frameworks/Python.framework/Python',
    'build/FFmpeg/FFmpeg.xcframework/ios-arm64/libFFmpeg.a',
    'build/RuntimeDependencies/NodeMobile/NodeMobile.xcframework/ios-arm64/NodeMobile.framework/NodeMobile',
    'build/RuntimeDependencies/NodeMobile/LICENSE.node',
]
missing = [name for name in required if not (root / name).is_file()]
generator = os.environ.get('XCODEGEN') or shutil.which('xcodegen')
if not generator and not (root / 'build/tools/xcodegen/xcodegen/bin/xcodegen').is_file():
    missing.append('XcodeGen (install on PATH or set XCODEGEN)')
if missing:
    raise SystemExit('Run python3 Scripts/prepare-ios-dependencies.py first. Missing: ' + ', '.join(missing))
out = root / 'build/ipa'
command = [
    'xcodebuild', 'archive', '-project', 'Yingxia-iOS.xcodeproj', '-scheme', 'TVBox-iOS',
    '-xcconfig', 'Config/LocalIPA.xcconfig',
    '-configuration', 'Release', '-destination', 'generic/platform=iOS',
    '-derivedDataPath', 'build/DerivedData-iOS16',
    '-clonedSourcePackagesDirPath', 'build/SourcePackages',
    '-disableAutomaticPackageResolution', '-skipMacroValidation', '-parallelizeTargets', '-jobs', str(jobs),
    '-showBuildTimingSummary',
    '-archivePath', str(out / 'Yingxia-local-iOS16.2.xcarchive'),
    f'CURRENT_PROJECT_VERSION={number}', 'CODE_SIGNING_ALLOWED=NO',
    'CODE_SIGNING_REQUIRED=NO', 'DEVELOPMENT_TEAM=',
    # SDK-scoped settings propagate to SwiftPM host macros too. A global
    # ARCHS=arm64 would build the wrong executable on this Intel build machine.
    f'LOCAL_EXCLUDED_HOST_ARCHS={excluded_host_arch}',
    'DEBUG_INFORMATION_FORMAT=dwarf', 'COMPILER_INDEX_STORE_ENABLE=NO',
    f'LOCAL_SWIFT_JOBS={jobs}',
]
config = {'cwd': str(root), 'command': command, 'build_number': number,
          'node_mobile_dir': str(root / 'build/RuntimeDependencies/NodeMobile'),
          'build_optimization': {
              'device_architecture': 'arm64', 'host_architecture': host_arch,
              'physical_cores': physical_cores, 'memory_gib': round(memory_bytes / 1024 ** 3, 1), 'jobs': jobs,
              'app_compilation': 'singlefile + incremental + batch, -O',
              'core_compilation': 'wholemodule, -O (unchanged)',
              'debug_information': 'dwarf (no local dSYM bundle)',
              'third_party_warning_suppression': ['KSPlayer', 'QuickJS', 'DisplayCriteria'],
              'preserved_caches': ['build/DerivedData-iOS16', 'build/SourcePackages', 'build/FFmpeg/cache'],
          }}
if args.check:
    print(json.dumps(config, indent=2))
    sys.exit(0)

# Both native dependency scripts build only the iPhoneOS arm64 slice here. Their
# source signatures make the normal, already prepared build a cache lookup.
native_env = dict(os.environ, TVBOX_FFMPEG_SLICES='ios',
                  TVBOX_FFMPEG_CACHE=str(root / 'build/FFmpeg/cache'))
subprocess.run(['bash', str(root / 'Scripts/build-ios-disc.sh')], cwd=root, env=native_env, check=True)
subprocess.run(['bash', str(root / 'Scripts/build-apple-ffmpeg.sh')], cwd=root, env=native_env, check=True)
subprocess.run([sys.executable, str(root / 'Scripts/prepare-ios-asr.py')], cwd=root, check=True)
subprocess.run([sys.executable, str(root / 'Scripts/generate-ios-project.py')], cwd=root, check=True)
if out.is_symlink():
    raise SystemExit('Refusing to replace a symlink at build/ipa')
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
from source_snapshot import source_paths
paths = source_paths(root)
snapshot = {p: hashlib.sha256((root / p).read_bytes()).hexdigest()
            for p in sorted(set(paths)) if p and (root / p).is_file()}
(out / 'source-sha256-before.json').write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + '\n')
native_inputs = {}
for directory in ['build/FFmpeg/FFmpeg.xcframework', 'Vendor/DiscNative/DiscNative.xcframework',
                  'Vendor/NativeASR/TVASR.xcframework']:
    for path in sorted((root / directory).rglob('*')):
        if path.is_file():
            native_inputs[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
if not native_inputs:
    raise SystemExit('Prepared native playback dependencies are missing')
(out / 'native-sha256-before.json').write_text(json.dumps(native_inputs, indent=2) + '\n')
(out / 'build-command.json').write_text(json.dumps(config, indent=2) + '\n')
env = dict(os.environ, NODE_MOBILE_DIR=config['node_mobile_dir'])
started = time.time()
print(f'Building iOS IPA build {number}; log: {out / "archive.log"}', flush=True)
with (out / 'archive.log').open('w') as log:
    result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
(out / 'archive-result.json').write_text(json.dumps({
    'exit_code': result.returncode, 'elapsed_seconds': round(time.time() - started, 2),
    'log': str(out / 'archive.log'),
}, indent=2) + '\n')
if result.returncode:
    print((out / 'archive.log').read_text(errors='replace')[-8000:], file=sys.stderr)
    sys.exit(result.returncode)
subprocess.run([sys.executable, str(root / 'Scripts/package-ios-ipa.py'), str(out)], cwd=root, check=True)
