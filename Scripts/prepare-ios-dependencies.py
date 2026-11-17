#!/usr/bin/env python3
"""Prepare the pinned dependencies and Swift packages needed for the iOS IPA build."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--av3a-archive', type=Path, help='Locally obtained AV3A reference archive, according to its terms.')
    args = parser.parse_args()
    if sys.version_info < (3, 10):
        raise SystemExit('Python 3.10 or newer is required.')
    for name in ['xcrun', 'xcodebuild', 'git', 'curl', 'rg', 'pkg-config', 'patch']:
        if shutil.which(name) is None:
            raise SystemExit('Missing build tool: ' + name + '. See README.md.')
    if not (os.environ.get('XCODEGEN') or shutil.which('xcodegen')
            or (ROOT / 'build/tools/xcodegen/xcodegen/bin/xcodegen').is_file()):
        raise SystemExit('Install XcodeGen or set XCODEGEN. See README.md.')
    subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], check=True)
    command = [sys.executable, 'Scripts/fetch-vendor-dependencies.py']
    if args.av3a_archive:
        command += ['--av3a-archive', str(args.av3a_archive.resolve())]
    subprocess.run(command, cwd=ROOT, check=True)
    node = ROOT / 'build/RuntimeDependencies/NodeMobile'
    if not (node / 'NodeMobile.xcframework').is_dir():
        subprocess.run(['bash', 'Scripts/fetch-node-mobile.sh', 'ios'], cwd=ROOT, check=True)
        node.parent.mkdir(parents=True, exist_ok=True)
        if node.exists() or node.is_symlink():
            raise SystemExit('Incomplete Node dependency exists; inspect ' + str(node))
        node.symlink_to((ROOT / 'build/NodeMobile').resolve(), target_is_directory=True)
    if not (ROOT / 'build/ApplePython/iphoneos/Frameworks/Python.framework/Python').is_file():
        subprocess.run(['bash', 'Scripts/build-apple-python.sh', 'ios'], cwd=ROOT, check=True)
    env = dict(os.environ, TVBOX_FFMPEG_SLICES='ios', TVBOX_FFMPEG_CACHE=str(ROOT / 'build/FFmpeg/cache'))
    subprocess.run(['bash', 'Scripts/build-ios-disc.sh'], cwd=ROOT, env=env, check=True)
    subprocess.run(['bash', 'Scripts/build-apple-ffmpeg.sh'], cwd=ROOT, env=env, check=True)
    link = ROOT / 'Vendor/FFmpeg/FFmpeg.xcframework'
    if not link.exists() and not link.is_symlink():
        link.symlink_to('../../build/FFmpeg/FFmpeg.xcframework', target_is_directory=True)
    subprocess.run([sys.executable, 'Scripts/prepare-ios-asr.py'], cwd=ROOT, check=True)
    subprocess.run([sys.executable, 'Scripts/generate-ios-project.py'], cwd=ROOT, check=True)
    resolved = ROOT / 'Yingxia-iOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    resolved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'Package.resolved', resolved)
    subprocess.run(['xcodebuild', '-resolvePackageDependencies', '-project', 'Yingxia-iOS.xcodeproj',
                    '-scheme', 'TVBox-iOS', '-clonedSourcePackagesDirPath', 'build/SourcePackages',
                    '-onlyUsePackageVersionsFromResolvedFile'], cwd=ROOT, check=True)
    print('Dependencies prepared. Run python3 Scripts/build-ios-ipa.py --build-number 1')


if __name__ == '__main__':
    main()
