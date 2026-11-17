#!/usr/bin/env python3
"""Build the pinned native AV3A reference decoder for iOS 16.2 arm64 only."""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/AV3A"

def run(args: list[str]) -> str:
    result = subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    return result.stdout.strip()

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / "build/AV3A/iphoneos")
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    inventory = json.loads((VENDOR / "SOURCE-INVENTORY.json").read_text())
    for item in inventory["files"]:
        actual = hashlib.sha256((VENDOR / item["path"]).read_bytes()).hexdigest()
        if actual != item["sha256"]:
            raise SystemExit(f"Pinned AV3A source changed: {item['path']}")
    cc = run(["xcrun", "--sdk", "iphoneos", "--find", "clang"])
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
    # The reference debug writer is unused by the decoder and can write arbitrary
    # host paths. Keep its pinned source for provenance, omit its object.
    sources = [p for p in sorted((VENDOR / "reference").rglob("*.c"))
               if p.name != "avs3_debug.c"] + [VENDOR / "tvav3a.c"]
    fingerprint = hashlib.sha256()
    for path in sorted(VENDOR.rglob("*")):
        if path.is_file():
            fingerprint.update(str(path.relative_to(VENDOR)).encode())
            fingerprint.update(path.read_bytes())
    fingerprint.update(Path(__file__).read_bytes())
    fingerprint.update((sdk + run([cc, "--version"])).encode())
    signature = fingerprint.hexdigest()
    manifest = prefix / "build-manifest.json"
    if manifest.is_file() and (prefix / "lib/libtvav3a.a").is_file():
        saved = json.loads(manifest.read_text())
        actual = hashlib.sha256((prefix / "lib/libtvav3a.a").read_bytes()).hexdigest()
        if saved.get("signature") == signature and saved.get("library_sha256") == actual:
            print(f"AV3A iOS arm64 is up to date: {prefix}")
            return
    work = ROOT / "build/AV3A/objects-ios16.2-arm64"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    # Keep the upstream implausible-latent clamp, removing its process-global
    # log state and its desktop HOME/Library/Logs file writes on iOS.
    upstream_clamp = VENDOR / "reference/common/mdct_dequant_decode.c"
    prepared_clamp = work / "mdct_dequant_decode.c"
    clamp_text = upstream_clamp.read_text()
    clamp_start = clamp_text.index("static void Avs3LogClampedLatent(")
    clamp_end = clamp_text.index("/* ---- end clamp ---- */", clamp_start)
    clamp_text = clamp_text[:clamp_start] + """static void Avs3ClampImplausibleLatents(int32_t *latent, int16_t size)
{
    for (int16_t i = 0; i < size; i++) {
        if (latent[i] > AVS3_LATENT_CLAMP_ABS || latent[i] < -AVS3_LATENT_CLAMP_ABS)
            latent[i] = 0;
    }
}
""" + clamp_text[clamp_end:]
    prepared_clamp.write_text(clamp_text)
    sources = [prepared_clamp if p == upstream_clamp else p for p in sources]
    includes = ["-I" + str(VENDOR / folder) for folder in
                ["include", "reference/common", "reference/decoder"]]
    flags = ["-target", "arm64-apple-ios16.2", "-isysroot", sdk, "-O3", "-DNDEBUG",
             "-DSUPPORT_NEON", "-std=gnu11", "-fPIC", "-fno-common",
             "-Wno-macro-redefined", "-Wno-incompatible-pointer-types",
             "-Wno-pointer-sign"] + includes
    def compile_one(source: Path) -> Path:
        out = work / (source.stem + ".o")
        try:
            output = run([cc] + flags + ["-c", str(source), "-o", str(out)])
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(f"{source}:\n{exc.stdout}") from exc
        (work / (source.stem + ".log")).write_text(output + "\n")
        return out
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(os.cpu_count() or 2, 8)) as pool:
        objects = list(pool.map(compile_one, sources))
    partial = prefix.with_name(prefix.name + ".partial")
    shutil.rmtree(partial, ignore_errors=True)
    (partial / "lib/pkgconfig").mkdir(parents=True)
    (partial / "include").mkdir()
    archive = partial / "lib/libtvav3a.a"
    run(["xcrun", "--sdk", "iphoneos", "libtool", "-static", "-no_warning_for_no_symbols",
         "-o", str(archive)] + [str(obj) for obj in objects])
    architectures = run(["lipo", "-archs", str(archive)])
    if architectures != "arm64":
        raise SystemExit(f"Unexpected AV3A architectures: {architectures}")
    shutil.copyfile(VENDOR / "include/tvav3a.h", partial / "include/tvav3a.h")
    (partial / "lib/pkgconfig/tvav3a.pc").write_text(
        f"prefix={prefix}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\n\n"
        "Name: tvav3a\nDescription: Local AVS3A reference decoder adapter\n"
        "Version: 3.3.1\nLibs: -L${libdir} -ltvav3a\nCflags: -I${includedir}\n")
    (partial / "build-manifest.json").write_text(json.dumps({
        "signature": signature, "repository": inventory["repository"],
        "commit": inventory["commit"], "target": "arm64-apple-ios16.2",
        "source_files": len(sources), "model": "embedded model.h (79930 bytes)",
        "decoder": "AVS3A_RMv3.3.1", "channel_beds_only": True,
        "object_renderer": False, "redistribution_cleared": False,
        "library_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "device_runtime_verified": False,
    }, indent=2) + "\n")
    shutil.rmtree(prefix, ignore_errors=True)
    partial.rename(prefix)
    print(f"AV3A built: {prefix} ({len(sources)} C sources; arm64 iOS 16.2)")

if __name__ == "__main__":
    main()
