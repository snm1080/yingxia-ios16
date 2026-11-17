#!/usr/bin/env python3
"""Check actual linked iOS player components; this is not a runtime decode test."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys

repo = Path(__file__).resolve().parent.parent
app, output = map(Path, sys.argv[1:3])
info = plistlib.loads((app / 'Info.plist').read_bytes())
executable = app / info['CFBundleExecutable']
# ld includes literal string bytes as well as symbol names. Some FFmpeg test
# strings deliberately contain invalid UTF-8; symbol records themselves are ASCII.
linkmap = (output / 'ios-linkmap.txt').read_text(encoding='utf-8', errors='replace')
live = linkmap.split('# Dead Stripped Symbols:')[0]
errors = []

def linked(symbol):
    return bool(re.search(r'(?m)^0x[0-9A-Fa-f]+\s+0x[0-9A-Fa-f]+\s+\[\s*\d+\]\s+_?' + re.escape(symbol) + r'\s*$', live))

required = {
    'H.264/AVC': ['ff_h264_decoder'],
    'H.265/HEVC': ['ff_hevc_decoder'],
    'H.266/VVC': ['ff_vvc_decoder'],
    'VP5': ['ff_vp5_decoder'],
    'VP8': ['ff_vp8_decoder'],
    'VP9': ['ff_vp9_decoder'],
    'AV1': ['ff_libdav1d_decoder', 'ff_av1_decoder'],
    'AVS2': ['ff_libdavs2_decoder'],
    'AVS3': ['ff_libuavs3d_decoder'],
    'AAC': ['ff_aac_decoder'],
    'AC3': ['ff_ac3_decoder'],
    'EAC3': ['ff_eac3_decoder'],
    'DTS': ['ff_dca_decoder'],
    'TrueHD': ['ff_truehd_decoder'],
    'FLAC': ['ff_flac_decoder'],
    'Opus': ['ff_opus_decoder'],
    'AV3A channel beds': ['ff_libtvav3a_decoder'],
}
codecs = {name: [symbol for symbol in alternatives if linked(symbol)]
          for name, alternatives in required.items()}
for name, symbols in codecs.items():
    if not symbols:
        errors.append(f'Missing linked decoder: {name}')
formats = {name: linked(symbol) for name, symbol in {
    'HLS': 'ff_hls_demuxer', 'DASH': 'ff_dash_demuxer', 'FLV': 'ff_flv_demuxer',
    'Matroska/WebM': 'ff_matroska_demuxer', 'MPEG-TS': 'ff_mpegts_demuxer',
    'MP4/MOV': 'ff_mov_demuxer',
    'RTSP': 'ff_rtsp_demuxer',
}.items()}
for name, present in formats.items():
    if not present:
        errors.append(f'Missing linked demuxer: {name}')
protocols = {name: linked(symbol) for name, symbol in {
    'RTMP': 'ff_rtmp_protocol', 'RTMPS': 'ff_rtmps_protocol',
    'UDP': 'ff_udp_protocol', 'RTP': 'ff_rtp_protocol',
}.items()}
for name, present in protocols.items():
    if not present:
        errors.append(f'Missing linked media protocol: {name}')
filters = {name: linked(symbol) for name, symbol in {
    'interlace detection': 'ff_vf_idet', 'deinterlace': 'ff_vf_yadif',
    'video input': 'ff_vsrc_buffer', 'video output': 'ff_vsink_buffer',
}.items()}
for name, present in filters.items():
    if not present:
        errors.append(f'Missing linked playback filter: {name}')
ksplayer = 'KSMEPlayer' in live and 'KSPlaybackEngine' in live
if not ksplayer:
    errors.append('KSPlayer and the active iOS engine are not both linked')
for symbol in ['ff_av3a_parser', 'tv_av3a_decode']:
    if not linked(symbol):
        errors.append(f'Missing AV3A parser/implementation: {symbol}')
avs = {symbol: linked(symbol) for symbol in ['davs2_decoder_open', 'davs2_decoder_send_packet',
                                           'uavs3d_create', 'uavs3d_decode']}
for symbol, present in avs.items():
    if not present:
        errors.append(f'Missing AVS native implementation: {symbol}')
disc = {symbol: linked(symbol) for symbol in ['bd_open_stream', 'bd_read', 'bd_seek', 'udfread_open_input']}
for symbol, present in disc.items():
    if not present:
        errors.append(f'Missing linked disc reader: {symbol}')
dolby_conversion = {symbol: linked(symbol) for symbol in [
    'tv_dolby_converter_create', 'tv_dolby_convert_p7_to_p81',
    'tv_dolby_converter_flush', 'tv_dolby_converter_free',
    'ff_dovi_rpu_parse', 'ff_dovi_get_metadata', 'ff_dovi_rpu_generate',
]}
for symbol, present in dolby_conversion.items():
    if not present:
        errors.append(f'Missing linked P7 to P8.1 converter: {symbol}')
asr_symbols = {symbol: linked(symbol) for symbol in [
    'tvasr_create', 'tvasr_transcribe', 'tvasr_cancellation_cancel', 'tvasr_destroy',
    'SherpaOnnxCreateOnlineRecognizer', 'SherpaOnnxDecodeOnlineStream',
    'SherpaOnnxCreateOfflineRecognizer', 'SherpaOnnxDecodeOfflineStream',
    'SherpaOnnxCreateVoiceActivityDetector', 'OrtGetApiBase',
]}
for symbol, present in asr_symbols.items():
    if not present:
        errors.append(f'Missing linked offline speech implementation: {symbol}')
asr_source = repo / 'App/Resources/local-asr-models.json'
asr_packaged = app / 'local-asr-models.json'
asr_manifest_matches = (asr_source.is_file() and asr_packaged.is_file()
                        and asr_source.read_bytes() == asr_packaged.read_bytes())
if not asr_manifest_matches:
    errors.append('Packaged offline speech model manifest differs from source or is missing')
asr_license = app / 'NativeASR-Licenses.txt'
asr_source_license = repo / 'App/Resources/NativeASR-Licenses.txt'
asr_license_matches = (asr_license.is_file() and asr_source_license.is_file()
                       and asr_license.read_bytes() == asr_source_license.read_bytes())
if not asr_license_matches:
    errors.append('Offline speech dependency license notices are missing or differ from source')
system_speech = 'NSSpeechRecognitionUsageDescription' in info or 'SFSpeechRecognizer' in live
if system_speech:
    errors.append('System Speech recognition remains in the iOS player')
embedded_models = [str(path.relative_to(app)) for path in app.rglob('*') if path.suffix.lower() in {'.onnx', '.ort'}]
if embedded_models:
    errors.append('Downloadable speech model payload was unexpectedly embedded')
music_symbols = {symbol: linked(symbol) for symbol in [
    'tv_script_call_cancellable', 'tv_script_cancellation_create',
    'tv_script_cancellation_cancel', 'tv_script_cancellation_free',
]}
for symbol, present in music_symbols.items():
    if not present:
        errors.append(f'Missing linked cancellable music runtime: {symbol}')
music_assets = {}
for relative in ['lx/lx.js', 'music/prelude.js']:
    source = repo / 'Sources/TVCore/ScriptAssets' / relative
    copies = list(app.rglob('ScriptAssets/' + relative))
    music_assets[relative] = len(copies) == 1 and copies[0].read_bytes() == source.read_bytes()
    if not music_assets[relative]:
        errors.append(f'Packaged music adapter differs from source or is missing: {relative}')
report = {
    'validation_kind': 'linked-binary inspection; no device runtime execution',
    'ksplayer_linked': ksplayer,
    'decoders': codecs, 'demuxers': formats, 'protocols': protocols, 'filters': filters, 'disc_reader': disc,
    'avs_native_implementations': avs,
    'dolby_p7_to_p81': dolby_conversion,
    'offline_speech': {'linked_symbols': asr_symbols, 'model_manifest_matches': asr_manifest_matches,
                       'model_manifest_sha256': hashlib.sha256(asr_source.read_bytes()).hexdigest() if asr_source.is_file() else None,
                       'license_matches': asr_license_matches,
                       'embedded_models': embedded_models, 'system_speech': system_speech},
    'music_sources': {'cancellation_symbols': music_symbols, 'script_assets_match': music_assets},
    'av3a_linked_symbols': sorted(set(re.findall(r'(?m)^0x[^\n]+\s(_?\w*av3a\w*)\s*$', live, re.I))),
    'app_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
    'linkmap_sha256': hashlib.sha256((output / 'ios-linkmap.txt').read_bytes()).hexdigest(),
    'errors': errors,
}
(output / 'player-validation.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
if errors:
    raise SystemExit('iOS player validation failed')
