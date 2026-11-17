"""Verify the current iOS archive, then replace the latest IPA delivery."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--revalidate-tools', action='store_true',
                    help='Resume an already source-verified archive after a package-validator-only fix.')
args = parser.parse_args()
out = args.output.resolve()
config = json.loads((out / 'build-command.json').read_text())
repo = Path(__file__).resolve().parent.parent
assert Path(config['cwd']).resolve() == repo, 'Build belongs to a different source directory'
archive_result = json.loads((out / 'archive-result.json').read_text())
assert archive_result['exit_code'] == 0, archive_result
assert '** ARCHIVE SUCCEEDED **' in (out / 'archive.log').read_text()

from source_snapshot import source_paths
paths = source_paths(repo)
after = {
    p: hashlib.sha256((repo / p).read_bytes()).hexdigest()
    for p in sorted(set(paths)) if p and (repo / p).is_file()
}
before = json.loads((out / 'source-sha256-before.json').read_text())
changed = [p for p in sorted(before.keys() | after.keys()) if before.get(p) != after.get(p)]
tool_updates = []
if args.revalidate_tools:
    # Keep the completed archive's original before/after evidence intact. Only
    # these non-embedded checking tools can change; application/runtime/native
    # inputs must still match the successful compile exactly.
    compiled_snapshot = json.loads((out / 'source-sha256-after.json').read_text())
    assert compiled_snapshot == before, 'Archive has no unchanged-source checkpoint'
    assert json.loads((out / 'source-changes-during-build.json').read_text()) == []
    allowed = {'Scripts/validate-ios-player.py', 'Scripts/package-ios-ipa.py'}
    assert set(changed) <= allowed, f'Non-validation source changed: {changed}'
    prior_validation = json.loads((out / 'ipa-validation.json').read_text())
    assert not prior_validation['errors'], 'Archive was not package-validated before tool repair'
    for name in changed:
        assert (repo / name).stat().st_mtime > (out / 'archive-result.json').stat().st_mtime, name
        tool_updates.append({'path': name, 'archive_sha256': before.get(name), 'current_sha256': after.get(name)})
    (out / 'packaging-source-sha256.json').write_text(json.dumps(after, ensure_ascii=False, indent=2) + '\n')
    changed = []
else:
    (out / 'source-sha256-after.json').write_text(json.dumps(after, ensure_ascii=False, indent=2) + '\n')
    (out / 'source-changes-during-build.json').write_text(json.dumps(changed, ensure_ascii=False, indent=2) + '\n')
    assert not changed, f'Source changed during build: {changed}'
native_before = json.loads((out / 'native-sha256-before.json').read_text())
native_changed = [name for name, digest in native_before.items()
                  if not (repo / name).is_file()
                  or hashlib.sha256((repo / name).read_bytes()).hexdigest() != digest]
assert not native_changed, f'Native dependencies changed during build: {native_changed}'

archive = out / 'Yingxia-local-iOS16.2.xcarchive'
apps = list((archive / 'Products/Applications').glob('*.app'))
assert len(apps) == 1, apps
app = apps[0]
if args.revalidate_tools:
    archived_info = plistlib.loads((app / 'Info.plist').read_bytes())
    archived_executable = app / archived_info['CFBundleExecutable']
    assert hashlib.sha256(archived_executable.read_bytes()).hexdigest() == prior_validation['app_sha256'], 'Archived application changed after validation'
with (out / 'ipa-validation-summary.log').open('w') as log:
    subprocess.run([sys.executable, str(repo / 'Scripts/validate-ios-ipa.py'), str(app), str(out)],
                   cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True)
validation = json.loads((out / 'ipa-validation.json').read_text())
assert not validation['errors'], validation['errors']
subprocess.run([sys.executable, str(repo / 'Scripts/validate-ios-player.py'), str(app), str(out)],
               cwd=repo, check=True)
player_validation = json.loads((out / 'player-validation.json').read_text())
assert not player_validation['errors'], player_validation['errors']
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert str(info['CFBundleVersion']) == str(config['build_number']), info['CFBundleVersion']
assert info['MinimumOSVersion'] == '16.2', info['MinimumOSVersion']
signing = subprocess.run(['codesign', '-dv', str(app)], text=True, capture_output=True)
(out / 'codesign-check.log').write_text(signing.stdout + signing.stderr)
assert signing.returncode != 0 and 'not signed at all' in signing.stderr, signing.stderr

runtime_checks = {}
runtime_files = [(repo / 'Runtime/PythonHost/host.py', app / 'PythonHost/host.py')]
runtime_files += [
    (src, app / 'PythonHost/base' / src.relative_to(repo / 'Runtime/PythonHost/base'))
    for src in sorted((repo / 'Runtime/PythonHost/base').rglob('*.py')) if src.is_file()
]
runtime_files.append((repo / 'App/Resources/local-html-home-sdk.js', app / 'local-html-home-sdk.js'))
runtime_files += [
    (src, app / 'NodeHost' / src.relative_to(repo / 'Runtime/NodeHost'))
    for src in sorted((repo / 'Runtime/NodeHost').rglob('*')) if src.is_file()
]
for src, dest in runtime_files:
    runtime_checks[str(src.relative_to(repo))] = (
        dest.is_file() and hashlib.sha256(src.read_bytes()).digest() == hashlib.sha256(dest.read_bytes()).digest()
    )
assert all(runtime_checks.values()), runtime_checks

stage = out / 'ipa-staging'
payload = stage / 'Payload'
payload.mkdir(parents=True, exist_ok=False)
shutil.copytree(app, payload / app.name, symlinks=True)
build_label = str(info['CFBundleVersion']).zfill(2)
ipa = out / f"Yingxia-{info['CFBundleShortVersionString']}-build{build_label}-iOS16.2-NoJava-unsigned.ipa"
assert not ipa.exists(), ipa
subprocess.run(['ditto', '-c', '-k', '--norsrc', '--keepParent', 'Payload', str(ipa)], cwd=stage, check=True)
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None
    assert all(name.startswith('Payload/') for name in z.namelist())
    assert plistlib.loads(z.read(f'Payload/{app.name}/Info.plist')) == info
    packaged_app_sha256 = hashlib.sha256(z.read(f"Payload/{app.name}/{info['CFBundleExecutable']}")).hexdigest()
    assert packaged_app_sha256 == validation['app_sha256']

report = {
    'ipa': str(ipa), 'bytes': ipa.stat().st_size,
    'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
    'zip_integrity': 'passed', 'app': str(app), 'signed': False,
    'version': info['CFBundleShortVersionString'], 'build': str(info['CFBundleVersion']),
    'minimum_ios': info['MinimumOSVersion'], 'device_families': info['UIDeviceFamily'],
    'source_file_count': len(after), 'source_changes_during_build': changed,
    'current_runtime_source': runtime_checks,
    'all_native_count': validation['all_native_count'],
    'framework_count': validation['framework_count'],
    'validation_errors': validation['errors'],
    'player_validation': player_validation,
    'native_source_changes_during_build': native_changed,
    'post_archive_validation_tool_updates': tool_updates,
}
(out / 'ipa-delivery.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
(out / 'SHA256SUMS.txt').write_text(report['sha256'] + '  ' + ipa.name + '\n')

# Publish only after the replacement IPA has passed every package check.
artifacts = repo / 'artifacts'
artifacts.mkdir(exist_ok=True)
pending = artifacts / '.latest-pending'
previous = artifacts / '.latest-previous'
latest = artifacts / 'latest'
assert not pending.exists() and not previous.exists(), 'An interrupted publication needs inspection'
pending.mkdir()
for name in [ipa.name, 'SHA256SUMS.txt', 'ipa-validation.json', 'source-sha256-after.json',
             'archive.log', 'archive-result.json', 'build-command.json', 'player-validation.json',
             'native-sha256-before.json', 'ios-linkmap.txt']:
    shutil.copy2(out / name, pending / name)
if args.revalidate_tools:
    shutil.copy2(out / 'packaging-source-sha256.json', pending / 'packaging-source-sha256.json')
report['ipa'] = str(latest / ipa.name)
(pending / 'ipa-delivery.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
if latest.exists():
    latest.rename(previous)
try:
    pending.rename(latest)
except BaseException:
    if previous.exists():
        previous.rename(latest)
    raise
if previous.exists():
    shutil.rmtree(previous)
print(json.dumps(report, ensure_ascii=False, indent=2))
