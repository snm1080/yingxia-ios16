#!/usr/bin/env python3
"""Prepare the pinned no-TTS sherpa/ONNX iOS arm64 dependency entirely offline.

The upstream iOS static library supplies the engine. Five model objects are
rebuilt for iOS 16.2 to pass cancellable Ort::RunOptions to every inference.
No simulator, host app, model download, signing or Git operation is performed.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/NativeASR'
OUTPUT = ROOT / 'build/NativeASR'
MODELS = {
    'online-zipformer-transducer-model': 3,
    'online-zipformer2-transducer-model': 3,
    'offline-wenet-ctc-model': 1,
    'offline-moonshine-model-v2': 2,
    'silero-vad-model': 2,
}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(args, log=None):
    args = list(map(str, args))
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        Path(log).write_text(proc.stdout)
    if proc.returncode:
        raise RuntimeError(f'Command failed: {args}\n' + '\n'.join(proc.stdout.splitlines()[-40:]))
    return proc.stdout.strip()


def extract(archive, target):
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        # Training/examples carry convenience symlinks unrelated to the native
        # dependency. Compile only regular source inputs; never materialize links.
        members = [item for item in members if not item.issym() and not item.islnk()]
        for item in members:
            full = (target / item.name).resolve()
            if not full.is_relative_to(target.resolve()):
                raise RuntimeError('Unsafe archive path: ' + item.name)
        source.extractall(target, members=members)


def archive_metadata(library, destination):
    if run(['lipo', '-archs', library]) != 'arm64':
        raise RuntimeError('Expected iOS arm64 archive: ' + str(library))
    thin = destination / (library.name + '.thin.a')
    # The ONNX framework wraps its static archive in a single-slice fat container.
    if Path(library).read_bytes()[:8] != b'!<arch>\n':
        run(['lipo', library, '-thin', 'arm64', '-output', thin])
    else:
        shutil.copyfile(library, thin)
    members = run(['ar', '-t', thin]).splitlines()
    member = next(name for name in members if name.endswith('.o'))
    obj = destination / (library.name + '.metadata.o')
    obj.write_bytes(subprocess.check_output(['ar', '-p', str(thin), member]))
    metadata = run(['xcrun', 'vtool', '-show-build', obj])
    if not re.search(r'platform\s+IOS\s*\n', metadata):
        raise RuntimeError('Expected iOS object metadata: ' + metadata)
    minimum = re.search(r'minos\s+([\d.]+)', metadata).group(1)
    if tuple(map(int, minimum.split('.'))) > (16, 2):
        raise RuntimeError('Dependency requires newer iOS: ' + metadata)
    return thin, {'architecture': 'arm64', 'platform': 'IOS', 'minimumOS': minimum,
                  'sha256': digest(library), 'bytes': Path(library).stat().st_size}


def main():
    inventory = json.loads((VENDOR / 'SOURCE-INVENTORY.json').read_text())
    for item in inventory['files']:
        path = VENDOR / item['path']
        if not path.is_file() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise RuntimeError('Pinned ASR input changed: ' + str(path))
    sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'])
    compiler = run(['xcrun', '--sdk', 'iphoneos', '--find', 'clang++'])
    signature = hashlib.sha256()
    inputs = [Path(__file__), VENDOR / 'SOURCE-INVENTORY.json', VENDOR / 'TVASR.cpp', VENDOR / 'TVASRRunOptions.h',
              *sorted((VENDOR / 'include').rglob('*'))]
    for path in inputs:
        if path.is_file():
            signature.update(str(path.relative_to(ROOT)).encode()); signature.update(path.read_bytes())
    signature.update((sdk + run([compiler, '--version'])).encode())
    fingerprint = signature.hexdigest()
    manifest = OUTPUT / 'build-manifest.json'
    if manifest.is_file():
        previous = json.loads(manifest.read_text())
        if previous.get('signature') == fingerprint and all(
            (OUTPUT / path).is_file() and digest(OUTPUT / path) == sha for path, sha in previous.get('outputs', {}).items()
        ) and previous.get('outputs'):
            print('Native offline ASR is up to date: ' + str(OUTPUT / 'TVASR.xcframework'), flush=True)
            return
    OUTPUT.mkdir(parents=True, exist_ok=True)
    work = OUTPUT / 'prepare-work'
    shutil.rmtree(work, ignore_errors=True); work.mkdir()
    for item in inventory['files']:
        extract(VENDOR / item['path'], work / 'inputs')
    source = work / 'inputs/sherpa-onnx-1.13.4'
    package = work / 'inputs/build-ios-no-tts'
    ort = package / 'ios-onnxruntime/1.27.0/onnxruntime.xcframework/ios-arm64/onnxruntime.framework'
    sherpa, sherpa_meta = archive_metadata(package / 'sherpa-onnx.xcframework/ios-arm64/sherpa-onnx.a', work)
    ortlib, ort_meta = archive_metadata(ort / 'onnxruntime', work)
    objects = work / 'objects'; objects.mkdir()
    cxx = [compiler, '-std=c++17', '-O2', '-DNDEBUG', '-target', 'arm64-apple-ios16.2', '-isysroot', sdk,
           '-I', str(source), '-I', str(ort / 'Headers'), '-I', str(VENDOR),
           '-I', str(work / 'inputs/openfst-1.8.5-2026-04-11/src/include'),
           '-I', str(work / 'inputs/kaldifst-1.8.0'), '-I', str(work / 'inputs/eigen-5.0.1')]
    # Keep the upstream public ABI and all model layouts unchanged. Only each Run's
    # empty options argument changes, with a checked count for this pinned version.
    patches = []
    for name, expected in MODELS.items():
        path = source / 'sherpa-onnx/csrc' / (name + '.cc')
        original = path.read_text()
        changed, count = re.subn(r'->Run\(\s*\{\}', '->Run(TVASRCurrentRunOptions()', original)
        if count != expected:
            raise RuntimeError(f'Unexpected model Run count in {name}: {count}, expected {expected}')
        path.write_text('#include "TVASRRunOptions.h"\n' + changed)
        object_file = objects / (name + '.cc.o')
        run(cxx + ['-c', str(path), '-o', str(object_file)], work / (name + '.log'))
        patches.append({'source': str(path.relative_to(source)), 'runOptionsCallCount': count,
                        'upstreamSha256': hashlib.sha256(original.encode()).hexdigest(), 'patchedSha256': digest(path),
                        'objectSha256': digest(object_file)})
        print('Compiled cancellable iOS model: ' + name, flush=True)
    bridge = objects / 'TVASR.o'
    run(cxx + ['-c', str(VENDOR / 'TVASR.cpp'), '-o', str(bridge)], work / 'bridge.log')
    for name in MODELS:
        run(['ar', '-d', sherpa, name + '.cc.o'])
    combined = work / 'libTVASR.a'
    run(['xcrun', 'libtool', '-static', '-o', combined, sherpa, ortlib, *sorted(objects.glob('*.o'))], work / 'libtool.log')
    if run(['lipo', '-archs', combined]) != 'arm64':
        raise RuntimeError('Combined ASR archive is not arm64')
    # Check the bridge deployment metadata and required library symbols.
    bridge_metadata = run(['xcrun', 'vtool', '-show-build', bridge])
    if not re.search(r'minos\s+16\.2\s*\n', bridge_metadata):
        raise RuntimeError('ASR bridge was not compiled for iOS 16.2')
    symbols = run(['nm', '-gU', combined], work / 'symbols.log')
    required = ['tvasr_create', 'tvasr_transcribe', 'tvasr_cancellation_cancel', 'tvasr_destroy',
                'SherpaOnnxCreateOnlineRecognizer', 'SherpaOnnxDecodeOnlineStream',
                'SherpaOnnxCreateOfflineRecognizer', 'SherpaOnnxDecodeOfflineStream',
                'SherpaOnnxCreateVoiceActivityDetector', 'OrtGetApiBase']
    for symbol in required:
        if not re.search(r'\b[TDS] _' + re.escape(symbol) + r'$', symbols, re.MULTILINE):
            raise RuntimeError('Missing native ASR implementation: ' + symbol)
    if re.search(r'\bT _(?:Java_|JNI_)', symbols):
        raise RuntimeError('Unexpected Java entry point in native ASR')
    framework = work / 'TVASR.xcframework'
    run(['xcodebuild', '-create-xcframework', '-library', combined, '-headers', VENDOR / 'include', '-output', framework], work / 'xcframework.log')
    target = OUTPUT / 'TVASR.xcframework'
    shutil.rmtree(target, ignore_errors=True); shutil.move(framework, target)
    link = VENDOR / 'TVASR.xcframework'
    if not link.is_symlink():
        if link.exists():
            raise RuntimeError('Refusing to replace a real vendor directory: ' + str(link))
        link.symlink_to('../../build/NativeASR/TVASR.xcframework')
    outputs = {str(path.relative_to(OUTPUT)): digest(path) for path in sorted(target.rglob('*')) if path.is_file()}
    manifest.write_text(json.dumps({'signature': fingerprint, 'sherpaVersion': '1.13.4', 'onnxRuntimeVersion': '1.27.0',
                                   'platform': 'IOS', 'architecture': 'arm64', 'minimumOS': '16.2',
                                   'inputs': inventory['files'], 'upstreamArchives': {'sherpa': sherpa_meta, 'onnxruntime': ort_meta},
                                   'patchedModels': patches, 'requiredSymbols': required, 'outputs': outputs,
                                   'runtimeInferenceVerified': False}, indent=2) + '\n')
    print('Prepared iOS 16.2 offline ASR: ' + str(target), flush=True)


if __name__ == '__main__':
    main()
