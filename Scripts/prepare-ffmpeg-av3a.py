#!/usr/bin/env python3
"""Apply the maintained AV3A integration to the pinned FFmpeg 8.1.3 source."""
from pathlib import Path
import argparse
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
args = parser.parse_args()
source = args.source.resolve()
patch = ROOT / "Vendor/AV3A/ffmpeg/ffmpeg-8.1.3-av3a.patch"
if not (source / "configure").is_file():
    raise SystemExit(f"FFmpeg source is missing: {source}")
command = ["patch", "--batch", "-p1", "-i", str(patch)]
probe = subprocess.run(command + ["--forward", "--dry-run"], cwd=source,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
if probe.returncode == 0:
    subprocess.run(command + ["--forward"], cwd=source, check=True)
else:
    applied = subprocess.run(command + ["--reverse", "--dry-run"], cwd=source,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if applied.returncode:
        raise SystemExit("AV3A patch conflicts with the prepared FFmpeg source:\n" + probe.stdout)
for filename in ["libtvav3a.c", "av3a_parser.c"]:
    shutil.copyfile(ROOT / "Vendor/AV3A/ffmpeg" / filename, source / "libavcodec" / filename)
print(f"FFmpeg AV3A integration ready: {source}")
