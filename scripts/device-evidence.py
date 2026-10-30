import argparse
from pathlib import Path

from release import digest, packages, read_json, require, write_json


def record(candidate, platform, device, log, output):
    p = read_json(candidate / "build-provenance.json")
    text = set(log.read_text().splitlines())
    require("PHYSICAL_DEVICE=passed" in text, "physical-device marker missing")
    require("CPU_INFERENCE=passed" in text, "CPU inference missing")
    require(
        any(
            marker in text
            for marker in (
                "WEBGPU_INFERENCE=passed",
                "BUILTIN_PROVIDER_INFERENCE=passed:CoreML",
                "BUILTIN_PROVIDER_INFERENCE=passed:WebGPU",
                "COREML_INFERENCE=passed",
            )
        ),
        "provider inference missing",
    )
    assets = {
        name: digest(candidate / name)
        for name, spec in packages(p["upstream_ort_version"], p["package_revision"]).items()
        if spec["TARGET"].startswith(platform)
        and f"ASSET_SHA256={digest(candidate / name)}" in text
    }
    require(assets, "no candidate asset hash in device log")
    entry = {
        "platform": platform,
        "device": device,
        "physical": True,
        "cpu": "passed",
        "provider": "passed",
        "jni": "passed" if "JAVA_JNI_INFERENCE=passed" in text else "not_run",
        "assets": assets,
    }
    records = read_json(output) if output.exists() else []
    require(all(x["platform"] != platform for x in records), "platform already recorded")
    write_json(output, records + [entry])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path)
    parser.add_argument(
        "--platform", required=True, choices=["android", "ios", "windows-x64", "windows-arm64"]
    )
    parser.add_argument("--device", required=True)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    record(args.candidate, args.platform, args.device, args.log, args.output)
