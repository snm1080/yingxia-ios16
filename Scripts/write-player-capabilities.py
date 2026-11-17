#!/usr/bin/env python3
"""Record the actual iOS FFmpeg configuration and required decoder symbols."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', type=Path, required=True)
parser.add_argument('--license-config', type=Path, required=True)
parser.add_argument('--archive', type=Path, required=True)
args = parser.parse_args()
config = args.config.resolve()
archive = args.archive.resolve()
flags = {key: int(value) for key, value in re.findall(r'#define CONFIG_(\w+) ([01])', config.read_text())}
license_flags = {key: int(value) for key, value in re.findall(r'#define CONFIG_(\w+) ([01])', args.license_config.read_text())}
symbols = set(subprocess.check_output(['nm', '-gU', str(archive)], text=True,
                                     stderr=subprocess.DEVNULL).split())
required = {name: '_ff_' + name + '_decoder' for name in [
    'h264', 'hevc', 'vvc', 'vp5', 'vp6', 'vp6a', 'vp6f', 'vp8', 'vp9', 'libdav1d',
    'libtvav3a', 'aac', 'ac3', 'eac3', 'dca', 'truehd', 'ass', 'pgssub',
    'libdavs2', 'libuavs3d',
]}
checks = {name: {'symbol': symbol, 'present': symbol in symbols} for name, symbol in required.items()}
missing = [name for name, value in checks.items() if not value['present']]
native_avs = ['davs2_decoder_open', 'davs2_decoder_send_packet', 'uavs3d_create', 'uavs3d_decode']
for symbol in native_avs:
    if '_' + symbol not in symbols:
        missing.append(symbol)
for feature in ['DASH_DEMUXER', 'AV3A_PARSER', 'HTTPS_PROTOCOL', 'HLS_DEMUXER', 'LIBDAVS2_DECODER', 'LIBUAVS3D_DECODER']:
    if flags.get(feature) != 1:
        missing.append(feature)
for feature in ['GPL', 'NONFREE']:
    if license_flags.get(feature) != 1:
        missing.append('license flag ' + feature)
if missing:
    raise SystemExit('Required native player features absent: ' + ', '.join(missing))
manifest = {
    'ffmpeg_version': '8.1.3',
    'ffmpeg_commit': '1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7',
    'architecture': 'arm64', 'platform': 'iOS', 'minimum_os': '16.2',
    'archive': str(archive.relative_to(ROOT)),
    'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
    'config_sha256': hashlib.sha256(config.read_bytes()).hexdigest(),
    'ksplayer_commit': 'be7f60d3b94a0941c643fe8699113cfce4f08e83',
    'required_decoder_symbols': checks,
    'avs_native_symbols': native_avs,
    'avs_source_inventory_sha256': hashlib.sha256((ROOT / 'Vendor/AVSNative/SOURCE-INVENTORY.json').read_bytes()).hexdigest(),
    'avs_limitations': [
        'AVS2/AVS3 use native software decoders built with 8/10-bit support.',
        'Compilation does not establish device performance, complete profile coverage or HDR metadata fidelity.',
    ],
    'av3a_limitations': [
        'Native reference decoder supports channel beds; object/HOA rendering is rejected.',
        'Compilation and package checks do not establish real-device runtime behavior.',
    ],
    'license_configuration': {
        'nonfree': bool(license_flags['NONFREE']), 'gpl': bool(license_flags['GPL']),
        'note': 'davs2 GPL-2.0-or-later, uavs3d BSD-3-Clause; KSPlayer and bridge source GPL-3.0; AV3A reference redistribution permissions require separate review.',
    },
}
for group in ['decoder', 'demuxer', 'protocol', 'parser', 'filter']:
    suffix = '_' + group.upper()
    manifest['enabled_' + group + 's'] = sorted(name[:-len(suffix)].lower()
        for name, value in flags.items() if value and name.endswith(suffix))
output = ROOT / 'build/FFmpeg/player-capabilities.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Native player capabilities checked: {output}')
