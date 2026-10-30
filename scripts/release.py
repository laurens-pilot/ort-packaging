import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
SHA = r"[0-9a-f]{40}"
FIELDS = {
    "ORT_REF",
    "ORT_VERSION",
    "ORT_TELEMETRY",
    "ORT_COMMIT",
    "PACKAGING_COMMIT",
    "PACKAGE_CHANNEL",
    "PACKAGE_REVISION",
    "PACKAGE_LABEL",
    "TARGET",
    "ORT_CORE_INCLUDED",
    "WEBGPU_LINKAGE",
    "EXECUTION_PROVIDERS",
    "BUILD_CONFIG",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(file):
    with Path(file).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(file):
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(Path(file).read_text(), object_pairs_hook=unique)


def write_json(file, value):
    Path(file).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def packages(version, revision):
    require(re.fullmatch(VERSION, version), "invalid ORT version")
    require(type(revision) is int and revision > 0, "invalid package revision")
    result = {}
    for target, spec in read_json(ROOT / "config/packages.json").items():
        provider, extension = spec["family"], spec["extension"]
        linkage, providers = spec["webgpu_linkage"], spec["execution_providers"]
        asset_target = "android" if target == "android-universal" else target
        name = f"onnxruntime-{provider}-{asset_target}-{version}-r{revision}.{extension}"
        result[name] = {
            "TARGET": target,
            "WEBGPU_LINKAGE": linkage,
            "EXECUTION_PROVIDERS": providers,
            "BUILD_CONFIG": "Release",
        }
    return result


def read_manifest(file):
    result = {}
    for line in Path(file).read_text().splitlines():
        require("=" in line, f"invalid manifest line in {file}")
        key, value = line.split("=", 1)
        require(key in FIELDS and key not in result, f"unknown or duplicate manifest field: {key}")
        result[key] = value
    require(set(result) == FIELDS, f"incomplete manifest: {file}")
    return result


def expected_manifest(p, spec):
    return {
        "ORT_REF": p["upstream_ort_ref"],
        "ORT_VERSION": p["upstream_ort_version"],
        "ORT_COMMIT": p["upstream_ort_commit"],
        "PACKAGING_COMMIT": p["packaging_commit"],
        "ORT_TELEMETRY": "disabled",
        "PACKAGE_CHANNEL": "stable",
        "PACKAGE_REVISION": str(p["package_revision"]),
        "PACKAGE_LABEL": p["package_label"],
        "ORT_CORE_INCLUDED": "1",
        **spec,
    }


def verify(candidate, run_id, attempt, commit, repository, build_env=None):
    candidate = Path(candidate)
    p = read_json(candidate / "build-provenance.json")
    version, revision = p["upstream_ort_version"], p["package_revision"]
    assets = packages(version, revision)
    require(re.fullmatch(SHA, commit), "invalid packaging commit")
    require(run_id > 0 and attempt > 0, "invalid run identity")
    expected = {
        "schema_version": 2,
        "release_scope": "all",
        "ort_telemetry": "disabled",
        "package_channel": "stable",
        "packaging_commit": commit,
        "github_repository": repository,
        "github_build_run_id": run_id,
        "github_build_run_attempt": attempt,
        "github_workflow_ref": f"{repository}/.github/workflows/build.yml@refs/heads/main",
        "upstream_ort_ref": f"v{version}",
        "package_label": f"r{revision}",
        "release_tag": f"ort-{version}-r{revision}",
    }
    for key, value in expected.items():
        require(
            p.get(key) == value and type(p.get(key)) is type(value), f"provenance mismatch: {key}"
        )
    require(re.fullmatch(SHA, p["upstream_ort_commit"]), "invalid upstream commit")
    require(
        isinstance(p["release_notes"], str) and p["release_notes"].strip(), "missing release notes"
    )
    if build_env is None:
        build_env = subprocess.check_output(["git", "show", f"{commit}:build.env"], cwd=ROOT)
    require(hashlib.sha256(build_env).hexdigest() == p["build_env_sha256"], "build.env mismatch")
    expected_files = {"build-provenance.json", "SHA256SUMS"}
    sums = []
    for name, spec in assets.items():
        expected_files.update((name, name + ".sha256", name + ".manifest.env"))
        file = candidate / name
        require(file.is_file() and not file.is_symlink(), f"missing or linked package: {name}")
        actual = digest(file)
        require(
            (candidate / (name + ".sha256")).read_text() == actual + "\n",
            f"checksum mismatch: {name}",
        )
        require(
            read_manifest(candidate / (name + ".manifest.env")) == expected_manifest(p, spec),
            f"manifest mismatch: {name}",
        )
        sums.append(f"{actual}  ./{name}\n")
    require(
        set(x.name for x in candidate.iterdir()) == expected_files, "unexpected candidate files"
    )
    require(
        all(x.is_file() and not x.is_symlink() for x in candidate.iterdir()),
        "invalid candidate entry",
    )
    require(
        (candidate / "SHA256SUMS").read_text()
        == "".join(sorted(sums, key=lambda x: x.split("  ")[1])),
        "SHA256SUMS mismatch",
    )
    require(set(p["validation"]) == set(assets), "incomplete package validation")
    for name, report in p["validation"].items():
        require(report["sha256"] == digest(candidate / name), f"validation hash mismatch: {name}")
        require(report["structure"] == "passed", f"unverified package structure: {name}")
        require(report["cpu"] in ("passed", "not_run"), f"invalid CPU result: {name}")
        require(report["provider"] in ("passed", "not_run"), f"invalid provider result: {name}")
        target = assets[name]["TARGET"]
        if target == "android-x86_64":
            require(report["jni"] == "passed", "Android JNI inference missing")
        if target not in ("android-arm64-v8a", "android-armeabi-v7a", "android-universal"):
            require(report["cpu"] == "passed", f"CPU inference missing: {target}")
        if target.startswith(("linux-", "macos-")) or target == "ios":
            require(report["provider"] == "passed", f"provider inference missing: {target}")
    expected_targets = {spec["TARGET"] for spec in assets.values()} - {"android-universal"}
    require(set(p["build_details"]) == expected_targets, "incomplete build details")
    for target, info in p["build_details"].items():
        require(
            info["target"] == target and isinstance(info["compilers"], dict) and info["compilers"],
            f"missing compiler identity: {target}",
        )
        require(isinstance(info["patches"], list), f"missing patch inventory: {target}")
    return p


def record_validation(asset, log=None):
    text = set(Path(log).read_text().splitlines()) if log else set()
    report = {
        "sha256": digest(asset),
        "structure": "passed",
        "cpu": "passed" if "CPU_INFERENCE=passed" in text else "not_run",
        "provider": "passed"
        if any(
            x in text
            for x in (
                "WEBGPU_INFERENCE=passed",
                "BUILTIN_PROVIDER_INFERENCE=passed:CoreML",
                "BUILTIN_PROVIDER_INFERENCE=passed:WebGPU",
                "COREML_INFERENCE=passed",
            )
        )
        else "not_run",
        "jni": "passed" if "JAVA_JNI_INFERENCE=passed" in text else "not_run",
    }
    write_json(str(asset) + ".validation.json", report)


def assemble(artifacts, output):
    p = {
        "schema_version": 2,
        "release_scope": "all",
        "ort_telemetry": "disabled",
        "package_channel": "stable",
        "packaging_commit": os.environ["GITHUB_SHA"],
        "github_repository": os.environ["GITHUB_REPOSITORY"],
        "github_build_run_id": int(os.environ["GITHUB_RUN_ID"]),
        "github_build_run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "github_workflow_ref": os.environ["GITHUB_WORKFLOW_REF"],
        "upstream_ort_version": os.environ["ORT_VERSION"],
        "upstream_ort_ref": os.environ["ORT_REF"],
        "upstream_ort_commit": os.environ["ORT_COMMIT"],
        "package_revision": int(os.environ["PACKAGE_REVISION"]),
        "package_label": os.environ["PACKAGE_LABEL"],
        "release_tag": os.environ["RELEASE_TAG"],
        "build_env_sha256": os.environ["BUILD_ENV_SHA256"],
        "validation": {},
        "build_details": {},
        "release_notes": "Custom ONNX Runtime packages with telemetry compiled out. See build-provenance.json for source identities, toolchains and per-package CPU/provider validation. Native GPU/device acceptance is required separately before publication.",
    }
    output = Path(output)
    output.mkdir()
    expected_assets = packages(p["upstream_ort_version"], p["package_revision"])
    binaries = [
        file.name
        for file in Path(artifacts).rglob("*")
        if file.is_file() and file.name.endswith((".aar", ".zip", ".tar.gz"))
    ]
    require(
        sorted(binaries) == sorted(expected_assets), "missing, duplicate or unexpected artifacts"
    )
    for name in expected_assets:
        matches = list(Path(artifacts).rglob(name))
        require(len(matches) == 1, f"missing or duplicate artifact: {name}")
        file = matches[0]
        for suffix in ("", ".sha256", ".manifest.env"):
            shutil.copyfile(str(file) + suffix, output / (name + suffix))
        p["validation"][name] = read_json(str(file) + ".validation.json")
    for file in Path(artifacts).rglob("build-info.json"):
        info = read_json(file)
        require(info["target"] not in p["build_details"], "duplicate build details")
        p["build_details"][info["target"]] = info
    labels = {
        "ios": "ios (simulator)",
        "android-x86_64": "android-x86_64 (emulator)",
        "linux-x64": "linux-x64 (software Vulkan)",
        "linux-arm64": "linux-arm64 (software Vulkan)",
    }
    rows = ["| Package | CI CPU | CI provider | CI Java/JNI |", "| --- | --- | --- | --- |"]
    for name, spec in expected_assets.items():
        report = p["validation"][name]
        label = labels.get(spec["TARGET"], spec["TARGET"])
        rows.append(f"| {label} | {report['cpu']} | {report['provider']} | {report['jni']} |")
    p["release_notes"] += (
        "\n\n"
        + "\n".join(rows)
        + "\n\nPhysical-device acceptance is recorded by the publication workflow against these exact archive hashes."
    )
    write_json(output / "build-provenance.json", p)
    names = sorted(packages(p["upstream_ort_version"], p["package_revision"]))
    (output / "SHA256SUMS").write_text(
        "".join(f"{digest(output / name)}  ./{name}\n" for name in names)
    )
    verify(
        output,
        p["github_build_run_id"],
        p["github_build_run_attempt"],
        p["packaging_commit"],
        p["github_repository"],
    )


def device_evidence(candidate, evidence):
    p = read_json(Path(candidate) / "build-provenance.json")
    assets = packages(p["upstream_ort_version"], p["package_revision"])
    required = {"android", "ios"}
    for name, report in p["validation"].items():
        if assets[name]["TARGET"].startswith("windows-") and report["provider"] != "passed":
            required.add(assets[name]["TARGET"])
    records = read_json(evidence)
    require(isinstance(records, list), "device evidence must be an array")
    seen = set()
    for record in records:
        platform = record["platform"]
        require(
            platform in {"android", "ios", "windows-x64", "windows-arm64"} and platform not in seen,
            "unexpected or duplicate device platform",
        )
        require(
            record["physical"] is True
            and record["cpu"] == "passed"
            and record["provider"] == "passed",
            "physical CPU/provider acceptance missing",
        )
        require(
            isinstance(record["device"], str) and record["device"].strip(),
            "device description missing",
        )
        expected = {
            name: digest(Path(candidate) / name)
            for name, spec in assets.items()
            if spec["TARGET"].startswith(platform)
        }
        require(
            record["assets"]
            and all(expected.get(name) == value for name, value in record["assets"].items()),
            f"device evidence hashes do not match candidate: {platform}",
        )
        if platform == "android":
            require(
                any(
                    "android-arm64-v8a-" in name
                    or "onnxruntime-webgpu-android-" + p["upstream_ort_version"] in name
                    for name in record["assets"]
                ),
                "Android acceptance must exercise ARM64 or universal AAR",
            )
        if platform == "android":
            require(record["jni"] == "passed", "Android JNI acceptance missing")
        seen.add(platform)
    require(required <= seen, f"missing device acceptance: {sorted(required - seen)}")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("verify")
    check.add_argument("candidate", type=Path)
    check.add_argument("run_id", type=int)
    check.add_argument("attempt", type=int)
    check.add_argument("commit")
    collect = commands.add_parser("assemble")
    collect.add_argument("artifacts", type=Path)
    collect.add_argument("output", type=Path)
    record = commands.add_parser("record")
    record.add_argument("asset", type=Path)
    record.add_argument("--log", type=Path)
    devices = commands.add_parser("verify-devices")
    devices.add_argument("candidate", type=Path)
    devices.add_argument("evidence", type=Path)
    args = parser.parse_args()
    if args.command == "verify":
        p = verify(
            args.candidate, args.run_id, args.attempt, args.commit, os.environ["GITHUB_REPOSITORY"]
        )
        for key, value in {
            "release_tag": p["release_tag"],
            "ort_ref": p["upstream_ort_ref"],
            "ort_version": p["upstream_ort_version"],
            "ort_commit": p["upstream_ort_commit"],
            "package_revision": p["package_revision"],
            "package_label": p["package_label"],
            "packaging_commit": p["packaging_commit"],
        }.items():
            print(f"{key}={value}")
    elif args.command == "assemble":
        assemble(args.artifacts, args.output)
    elif args.command == "record":
        record_validation(args.asset, args.log)
    else:
        device_evidence(args.candidate, args.evidence)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
