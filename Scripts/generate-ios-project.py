#!/usr/bin/env python3
"""Generate the iOS project without resolving unrelated Mac-only packages."""
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
generator = os.environ.get("XCODEGEN") or shutil.which("xcodegen")
if not generator:
    local = root / "build/tools/xcodegen/xcodegen/bin/xcodegen"
    if local.is_file():
        generator = str(local)
if not generator:
    raise SystemExit("Install XcodeGen or set XCODEGEN to its executable.")

spec = json.loads(subprocess.check_output([
    generator, "dump", "--spec", str(root / "project.yml"), "--type", "json"
]))
spec["name"] = "Yingxia-iOS"
spec["targets"] = {"TVBox-iOS": spec["targets"]["TVBox-iOS"]}
spec["packages"] = {name: value for name, value in spec["packages"].items()
                    if name in ("TVCore", "Perception")}
spec["options"]["deploymentTarget"] = {"iOS": "16.2"}
spec["settings"]["base"]["IPHONEOS_DEPLOYMENT_TARGET"] = "16.2"
destination = root / "build/ios-project.json"
destination.parent.mkdir(parents=True, exist_ok=True)
serialized = json.dumps(spec, indent=2, sort_keys=True) + "\n"
if not destination.exists() or destination.read_text() != serialized:
    destination.write_text(serialized)
# XcodeGen tracks the spec plus source/resource inventory. Using its cache
# avoids touching an unchanged project yet still adds new files to build phases.
subprocess.run([
    generator, "generate", "--spec", str(destination), "--project-root", str(root),
    "--project", str(root), "--use-cache", "--cache-path", str(root / "build/ios-project.xcodegen-cache")
], check=True)
