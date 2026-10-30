import argparse
import json
import os
import shutil
import subprocess
import urllib.request
from pathlib import Path

from release import ROOT, digest, read_json, require, verify


def validate(candidate, platform, device, description, work, evidence):
    p = read_json(candidate / "build-provenance.json")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(
        commit == p["packaging_commit"],
        "check out the candidate's packaging commit before device validation",
    )
    verify(
        candidate,
        p["github_build_run_id"],
        p["github_build_run_attempt"],
        commit,
        p["github_repository"],
    )
    work.mkdir(parents=True, exist_ok=True)
    source = work / "onnxruntime"
    headers = source / "include/onnxruntime/core/session"
    headers.mkdir(parents=True, exist_ok=True)
    revision = p["upstream_ort_commit"]
    url = f"https://api.github.com/repos/microsoft/onnxruntime/contents/include/onnxruntime/core/session?ref={revision}"
    with urllib.request.urlopen(url, timeout=120) as response:
        files = json.load(response)
    inputs = [
        (f"include/onnxruntime/core/session/{item['name']}", headers / item["name"])
        for item in files
        if item["name"].endswith(".h")
    ]
    model = source / "onnxruntime/test/testdata/mul_1.onnx"
    model.parent.mkdir(parents=True, exist_ok=True)
    inputs.append(("onnxruntime/test/testdata/mul_1.onnx", model))
    for relative, destination in inputs:
        with urllib.request.urlopen(
            f"https://raw.githubusercontent.com/microsoft/onnxruntime/{revision}/{relative}",
            timeout=120,
        ) as response:
            destination.write_bytes(response.read())
    policy = dict(
        line.split("=", 1)
        for line in (ROOT / "build.env").read_text().splitlines()
        if line and not line.startswith("#")
    )
    env = {
        **os.environ,
        **policy,
        "ORT_SOURCE_DIR": str(source),
        "BUILD_ROOT": str(work / "build"),
        "DIST_ROOT": str(work / "dist"),
        "ORT_REF": p["upstream_ort_ref"],
        "ORT_VERSION": p["upstream_ort_version"],
        "ORT_COMMIT": revision,
        "PACKAGE_REVISION": str(p["package_revision"]),
    }
    Path(env["BUILD_ROOT"]).mkdir(exist_ok=True)
    if platform == "android":
        asset = (
            candidate
            / f"onnxruntime-webgpu-android-{p['upstream_ort_version']}-{p['package_label']}.aar"
        )
        env["ANDROID_SERIAL"] = device
        env.setdefault(
            "ANDROID_NDK_HOME",
            str(Path(env["ANDROID_HOME"]) / "ndk" / policy["ANDROID_NDK_VERSION"]),
        )
        command = ["bash", str(ROOT / "scripts/test-android-runtime.sh"), "arm64-v8a", "webgpu"]
    elif platform == "ios":
        asset = (
            candidate
            / f"onnxruntime-coreml-ios-{p['upstream_ort_version']}-{p['package_label']}.zip"
        )
        env["IOS_DEVICE_ID"] = device
        command = ["bash", str(ROOT / "scripts/test-ios-runtime.sh")]
    else:
        asset = (
            candidate
            / f"onnxruntime-webgpu-{platform}-{p['upstream_ort_version']}-{p['package_label']}.zip"
        )
        folder = Path(env["DIST_ROOT"]) / platform
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(asset, folder / asset.name)
        require(digest(asset) == digest(folder / asset.name), "staged package hash mismatch")
        env["REQUIRE_WEBGPU"] = "1"
        env["CMAKE_GENERATOR"] = read_json(ROOT / "config/toolchains.json")["hosts"][platform][
            "generator"
        ]
        command = [
            "pwsh",
            "-NoProfile",
            "-File",
            str(ROOT / "scripts/test-windows-runtime.ps1"),
            platform,
        ]
    env["ORT_PACKAGE_ASSET"] = str(asset)
    log = work / f"{platform}.log"
    with log.open("w") as output:
        subprocess.run(
            command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=True
        )
    subprocess.run(
        [
            os.sys.executable,
            str(ROOT / "scripts/device-evidence.py"),
            str(candidate),
            "--platform",
            platform,
            "--device",
            description,
            "--log",
            str(log),
            "--output",
            str(evidence),
        ],
        check=True,
    )
    print(f"Device acceptance recorded in {evidence}; log: {log}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path)
    parser.add_argument(
        "--platform", required=True, choices=["android", "ios", "windows-x64", "windows-arm64"]
    )
    parser.add_argument("--device", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    validate(
        args.candidate.resolve(),
        args.platform,
        args.device,
        args.description,
        args.work_dir.resolve(),
        args.evidence.resolve(),
    )
