import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / "build.env").write_text("ORT_TELEMETRY=disabled\n")
        self.env = {
            **os.environ,
            "GITHUB_REPOSITORY": "ente/ort-packaging",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        for command in (
            ["git", "init", "-q"],
            ["git", "add", "build.env"],
            ["git", "commit", "-qm", "fixture"],
        ):
            subprocess.run(command, cwd=self.work, env=self.env, check=True)
        self.commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.work, text=True
        ).strip()
        self.candidate = self.work / "candidate"
        self.candidate.mkdir()
        self.provenance = {
            "github_repository": "ente/ort-packaging",
            "github_build_run_id": 1,
            "github_build_run_attempt": 1,
            "github_workflow_ref": "ente/ort-packaging/.github/workflows/build.yml@refs/heads/main",
            "packaging_commit": self.commit,
            "release_scope": "all",
            "ort_telemetry": "disabled",
            "package_channel": "stable",
            "release_notes": "Fixture",
            "upstream_ort_version": "1.31.0",
            "upstream_ort_ref": "v1.31.0",
            "upstream_ort_commit": "b" * 40,
            "build_env_sha256": hashlib.sha256((self.work / "build.env").read_bytes()).hexdigest(),
            "package_revision": 1,
            "package_label": "r1",
            "release_tag": "ort-1.31.0-r1",
        }
        sums = []
        for target in (
            "ios",
            "macos-arm64",
            "macos-x64",
            "android",
            "android-arm64-v8a",
            "android-armeabi-v7a",
            "android-x86_64",
            "linux-arm64",
            "linux-x64",
            "windows-arm64",
            "windows-x64",
        ):
            apple = target.startswith(("ios", "macos"))
            android = target.startswith("android")
            family = "coreml" if apple else "webgpu"
            extension = (
                "aar" if android else "zip" if target.startswith(("ios", "windows")) else "tar.gz"
            )
            name = f"onnxruntime-{family}-{target}-1.31.0-r1.{extension}"
            (self.candidate / name).write_bytes(name.encode())
            digest = hashlib.sha256(name.encode()).hexdigest()
            (self.candidate / (name + ".sha256")).write_text(digest + "\n")
            manifest = {
                "ORT_REF": "v1.31.0",
                "ORT_VERSION": "1.31.0",
                "ORT_COMMIT": "b" * 40,
                "PACKAGING_COMMIT": self.commit,
                "ORT_TELEMETRY": "disabled",
                "PACKAGE_CHANNEL": "stable",
                "PACKAGE_REVISION": "1",
                "PACKAGE_LABEL": "r1",
                "ORT_CORE_INCLUDED": "1",
                "TARGET": "android-universal" if target == "android" else target,
                "WEBGPU_LINKAGE": "disabled"
                if apple
                else "built-in"
                if android
                else "plugin-shared",
                "EXECUTION_PROVIDERS": "CoreML,CPU"
                if apple
                else "WebGPU,XNNPACK,CPU"
                if android
                else "WebGPU,CPU",
                "BUILD_CONFIG": "Release",
            }
            (self.candidate / (name + ".manifest.env")).write_text(
                "".join(f"{k}={v}\n" for k, v in manifest.items())
            )
            sums.append(f"{digest}  ./{name}\n")
        (self.candidate / "SHA256SUMS").write_text(
            "".join(sorted(sums, key=lambda line: line.split()[1]))
        )
        (self.candidate / "build-provenance.json").write_text(json.dumps(self.provenance))

    def verify(self, success):
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/verify-release-candidate.sh"),
                str(self.candidate),
                "1",
                "1",
                self.commit,
            ],
            cwd=self.work,
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_valid_candidate_and_manifest_tampering(self):
        self.verify(True)
        for file in self.candidate.glob("*.manifest.env"):
            original = file.read_text()
            for field in ("TARGET", "WEBGPU_LINKAGE", "EXECUTION_PROVIDERS", "BUILD_CONFIG"):
                file.write_text(
                    "\n".join(
                        f"{field}=wrong" if line.startswith(field + "=") else line
                        for line in original.splitlines()
                    )
                    + "\n"
                )
                self.verify(False)
            file.write_text(original + "TARGET=duplicate\n")
            self.verify(False)
            file.write_text(original)

    def test_checksum_extra_file_and_trial_provenance(self):
        asset = next(self.candidate.glob("*.aar"))
        original = asset.read_bytes()
        asset.write_bytes(b"tampered")
        self.verify(False)
        asset.write_bytes(original)
        (self.candidate / "extra").mkdir()
        self.verify(False)
        (self.candidate / "extra").rmdir()
        self.provenance["github_workflow_ref"] = (
            "ente/ort-packaging/.github/workflows/build.yml@refs/heads/trial"
        )
        (self.candidate / "build-provenance.json").write_text(json.dumps(self.provenance))
        self.verify(False)


class ToolTests(unittest.TestCase):
    def test_verified_install_and_hash_rejection(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            (root / "config").mkdir()
            shutil.copyfile(ROOT / "scripts/setup-tools.py", root / "scripts/setup-tools.py")
            spec = importlib.util.spec_from_file_location(
                "setup_tools", root / "scripts/setup-tools.py"
            )
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr("fixture/bin/cmake", "fixture")
                archive.writestr("fixture/bootstrap-vcpkg.sh", "fixture")
            data = buffer.getvalue()
            package = {
                "url": "https://fixture.invalid/archive",
                "sha512": hashlib.sha512(data).hexdigest(),
            }
            config = {
                "hosts": {
                    "windows-arm64": {"cmake": package, "generator": "Visual Studio 18 2026"}
                },
                "vcpkg": package,
            }
            config_file = root / "config/toolchains.json"
            config_file.write_text(json.dumps(config))
            with (
                patch.dict(
                    os.environ,
                    {
                        "RUNNER_TEMP": folder,
                        "GITHUB_PATH": str(root / "path"),
                        "GITHUB_ENV": str(root / "env"),
                    },
                ),
                patch.object(
                    module.urllib.request, "urlopen", side_effect=lambda *a, **k: io.BytesIO(data)
                ),
                patch.object(module.subprocess, "run") as bootstrap,
            ):
                module.install("windows-arm64")
                self.assertTrue((root / "ort-tools/cmake/bin/cmake").is_file())
                self.assertIn("CMAKE_GENERATOR=Visual Studio 18 2026", (root / "env").read_text())
                self.assertEqual(bootstrap.call_args.args[0][-1], "-disableMetrics")
                shutil.rmtree(root / "ort-tools")
                bootstrap.reset_mock()
                config["vcpkg"]["sha512"] = "0" * 128
                config_file.write_text(json.dumps(config))
                with self.assertRaisesRegex(ValueError, "SHA512 mismatch"):
                    module.install("windows-arm64")
                bootstrap.assert_not_called()
