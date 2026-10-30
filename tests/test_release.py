import copy
import hashlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import release


def load_script(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), release.ROOT / "scripts" / (name + ".py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "candidate"
        self.root.mkdir()
        self.policy = b"ORT_TELEMETRY=disabled\n"
        self.commit = "a" * 40
        self.p = {
            "schema_version": 2,
            "release_scope": "all",
            "ort_telemetry": "disabled",
            "package_channel": "stable",
            "packaging_commit": self.commit,
            "github_repository": "ente/ort-packaging",
            "github_build_run_id": 1,
            "github_build_run_attempt": 2,
            "github_workflow_ref": "ente/ort-packaging/.github/workflows/build.yml@refs/heads/main",
            "upstream_ort_version": "1.31.0",
            "upstream_ort_ref": "v1.31.0",
            "upstream_ort_commit": "b" * 40,
            "package_revision": 1,
            "package_label": "r1",
            "release_tag": "ort-1.31.0-r1",
            "build_env_sha256": hashlib.sha256(self.policy).hexdigest(),
            "release_notes": "Fixture",
            "validation": {},
            "build_details": {},
        }
        self.assets = release.packages("1.31.0", 1)
        for name, spec in self.assets.items():
            file = self.root / name
            file.write_bytes(("Synthetic package fixture: " + name).encode())
            value = release.digest(file)
            (self.root / (name + ".sha256")).write_text(value + "\n")
            fields = release.expected_manifest(self.p, spec)
            (self.root / (name + ".manifest.env")).write_text(
                "".join(f"{k}={v}\n" for k, v in fields.items())
            )
            self.p["validation"][name] = {
                "sha256": value,
                "structure": "passed",
                "cpu": "passed",
                "provider": "passed",
                "jni": "passed",
            }
            if spec["TARGET"] != "android-universal":
                self.p["build_details"][spec["TARGET"]] = {
                    "target": spec["TARGET"],
                    "compilers": {"cxx": "fixture"},
                    "patches": [],
                }
        (self.root / "SHA256SUMS").write_text(
            "".join(
                f"{release.digest(self.root / name)}  ./{name}\n" for name in sorted(self.assets)
            )
        )
        self.save()

    def save(self):
        release.write_json(self.root / "build-provenance.json", self.p)

    def verify(self):
        return release.verify(self.root, 1, 2, self.commit, "ente/ort-packaging", self.policy)

    def test_complete_candidate(self):
        self.assertEqual(len(list(self.root.iterdir())), 35)
        self.assertEqual(self.verify()["release_tag"], "ort-1.31.0-r1")

    def test_manifest_fields_are_enforced(self):
        name = next(iter(self.assets)) + ".manifest.env"
        file = self.root / name
        original = file.read_text()
        for field in (
            "TARGET",
            "WEBGPU_LINKAGE",
            "EXECUTION_PROVIDERS",
            "BUILD_CONFIG",
            "ORT_TELEMETRY",
            "PACKAGING_COMMIT",
        ):
            with self.subTest(field=field):
                lines = [
                    f"{field}=incorrect" if line.startswith(field + "=") else line
                    for line in original.splitlines()
                ]
                file.write_text("\n".join(lines) + "\n")
                with self.assertRaises(ValueError):
                    self.verify()
        file.write_text(original)

    def test_duplicate_and_unknown_manifest_keys(self):
        file = self.root / (next(iter(self.assets)) + ".manifest.env")
        original = file.read_text()
        for line in ("TARGET=ios", "UNEXPECTED=value"):
            file.write_text(original + line + "\n")
            with self.assertRaises(ValueError):
                self.verify()

    def test_missing_extra_and_linked_files(self):
        file = self.root / next(iter(self.assets))
        data = file.read_bytes()
        file.unlink()
        with self.assertRaises(ValueError):
            self.verify()
        file.write_bytes(data)
        (self.root / "unexpected").write_text("extra")
        with self.assertRaises(ValueError):
            self.verify()
        (self.root / "unexpected").unlink()
        file.unlink()
        file.symlink_to(self.root / "SHA256SUMS")
        with self.assertRaises(ValueError):
            self.verify()

    def test_content_and_checksum_manifest_tampering(self):
        file = self.root / next(iter(self.assets))
        file.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.verify()
        value = release.digest(file)
        (self.root / (file.name + ".sha256")).write_text(value + "\n")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            self.verify()

    def test_mixed_provenance_and_trial_are_rejected(self):
        original = copy.deepcopy(self.p)
        for key, value in (
            ("schema_version", 1),
            ("github_build_run_attempt", 1),
            ("github_build_run_id", True),
            ("release_scope", "trial"),
            ("packaging_commit", "c" * 40),
            ("github_workflow_ref", "fork/build.yml@refs/heads/main"),
            ("build_env_sha256", "0" * 64),
            ("package_revision", True),
        ):
            with self.subTest(key=key):
                self.p = {**copy.deepcopy(original), key: value}
                self.save()
                with self.assertRaises(ValueError):
                    self.verify()

    def test_provider_and_cpu_requirements(self):
        original = copy.deepcopy(self.p)
        for name, spec in self.assets.items():
            if spec["TARGET"].startswith(("linux", "macos")) or spec["TARGET"] == "ios":
                self.p = copy.deepcopy(original)
                self.p["validation"][name]["provider"] = "not_run"
                self.save()
                with self.assertRaisesRegex(ValueError, "provider"):
                    self.verify()
        self.p = copy.deepcopy(original)
        name = next(n for n in self.assets if "windows-x64" in n)
        self.p["validation"][name]["provider"] = "not_run"
        self.save()
        self.verify()
        self.p["validation"][name]["cpu"] = "not_run"
        self.save()
        with self.assertRaisesRegex(ValueError, "CPU"):
            self.verify()

    def test_duplicate_json_key(self):
        file = self.root / "build-provenance.json"
        file.write_text('{"schema_version": 1, "schema_version": 2}')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            release.read_json(file)

    def test_device_evidence_requires_matching_physical_results(self):
        records = []
        for platform in ("android", "ios"):
            names = [n for n, spec in self.assets.items() if spec["TARGET"].startswith(platform)]
            records.append(
                {
                    "platform": platform,
                    "device": "Fixture device and OS",
                    "physical": True,
                    "cpu": "passed",
                    "provider": "passed",
                    "jni": "passed",
                    "assets": {n: release.digest(self.root / n) for n in names},
                }
            )
        file = self.root.parent / "device.json"
        release.write_json(file, records)
        release.device_evidence(self.root, file)
        for field, value in (
            ("physical", False),
            ("provider", "not_run"),
            ("jni", "not_run"),
            ("assets", {"foreign.zip": "0" * 64}),
        ):
            changed = copy.deepcopy(records)
            changed[0][field] = value
            release.write_json(file, changed)
            with self.assertRaises(ValueError):
                release.device_evidence(self.root, file)
        name = next(n for n in self.assets if "windows-arm64" in n)
        self.p["validation"][name]["provider"] = "not_run"
        self.save()
        release.write_json(file, records)
        with self.assertRaisesRegex(ValueError, "missing device"):
            release.device_evidence(self.root, file)

    def test_validation_markers_are_exact(self):
        asset = self.root / next(iter(self.assets))
        log = self.root.parent / "log.txt"
        log.write_text("NOT_CPU_INFERENCE=passed\nWEBGPU_INFERENCE=skipped:no-gpu-device\n")
        release.record_validation(asset, log)
        self.assertEqual(release.read_json(str(asset) + ".validation.json")["cpu"], "not_run")

    def test_sequential_device_checks_preserve_candidate(self):
        module = load_script("validate-device")
        recorder = load_script("device-evidence")
        evidence = self.root.parent / "evidence.json"
        original = {file.name: file.read_bytes() for file in self.root.iterdir()}

        def download(url, **kwargs):
            return io.BytesIO(b"[]" if "api.github.com" in url else b"fixture model")

        def run(command, **kwargs):
            if command[0] == "bash":
                asset = Path(kwargs["env"]["ORT_PACKAGE_ASSET"])
                self.assertNotEqual(asset.parent, self.root)
                self.assertEqual(asset.read_bytes(), (self.root / asset.name).read_bytes())
                release.record_validation(asset)
                kwargs["stdout"].write(
                    "CPU_INFERENCE=passed\nCOREML_INFERENCE=passed\n"
                    "JAVA_JNI_INFERENCE=passed\nPHYSICAL_DEVICE=passed\n"
                    f"ASSET_SHA256={release.digest(asset)}\n"
                )
            else:
                recorder.record(
                    Path(command[2]), command[4], command[6], Path(command[8]), Path(command[10])
                )

        with (
            patch.dict(os.environ, {"ANDROID_HOME": str(self.root.parent / "sdk")}),
            patch.object(module.subprocess, "check_output", return_value=self.commit + "\n"),
            patch.object(module.subprocess, "run", side_effect=run),
            patch.object(module.urllib.request, "urlopen", side_effect=download),
            patch.object(module, "verify", side_effect=lambda *args: self.verify()),
        ):
            for platform in ("android", "ios"):
                module.validate(
                    self.root,
                    platform,
                    "fixture-id",
                    "Fixture phone",
                    self.root.parent / platform,
                    evidence,
                )
                self.verify()
        self.assertEqual(original, {file.name: file.read_bytes() for file in self.root.iterdir()})
        release.device_evidence(self.root, evidence)

    def test_assembly_round_trip_and_duplicate_assets(self):
        for name, report in self.p["validation"].items():
            release.write_json(self.root / (name + ".validation.json"), report)
        for target, info in self.p["build_details"].items():
            folder = self.root / target
            folder.mkdir()
            release.write_json(folder / "build-info.json", info)
        env = {
            "GITHUB_SHA": self.commit,
            "GITHUB_REPOSITORY": "ente/ort-packaging",
            "GITHUB_RUN_ID": "1",
            "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_WORKFLOW_REF": self.p["github_workflow_ref"],
            "ORT_VERSION": "1.31.0",
            "ORT_REF": "v1.31.0",
            "ORT_COMMIT": self.p["upstream_ort_commit"],
            "PACKAGE_REVISION": "1",
            "PACKAGE_LABEL": "r1",
            "RELEASE_TAG": "ort-1.31.0-r1",
            "BUILD_ENV_SHA256": self.p["build_env_sha256"],
        }
        output = self.root.parent / "assembled"
        with (
            patch.dict(os.environ, env),
            patch.object(release.subprocess, "check_output", return_value=self.policy),
        ):
            release.assemble(self.root, output)
        self.assertEqual(len(list(output.iterdir())), 35)
        release.verify(output, 1, 2, self.commit, "ente/ort-packaging", self.policy)
        name = next(iter(self.assets))
        (self.root / "duplicate").mkdir()
        (self.root / "duplicate" / name).write_bytes(b"duplicate")
        with patch.dict(os.environ, env):
            with self.assertRaisesRegex(ValueError, "duplicate.*artifacts"):
                release.assemble(self.root, self.root.parent / "invalid")

    def test_compiler_and_validation_identity_are_required(self):
        original = copy.deepcopy(self.p)
        for key, value in (("build_details", {}), ("validation", {})):
            self.p = {**copy.deepcopy(original), key: value}
            self.save()
            with self.assertRaises(ValueError):
                self.verify()
        self.p = copy.deepcopy(original)
        self.p["validation"][next(iter(self.assets))]["sha256"] = "0" * 64
        self.save()
        with self.assertRaisesRegex(ValueError, "validation hash"):
            self.verify()

    def test_device_recording_requires_complete_log_and_exact_hash(self):
        module = load_script("device-evidence")
        name = next(name for name in self.assets if "android-arm64-v8a" in name)
        log = self.root.parent / "android.log"
        output = self.root.parent / "evidence.json"
        text = (
            "CPU_INFERENCE=passed\nBUILTIN_PROVIDER_INFERENCE=passed:WebGPU\nJAVA_JNI_INFERENCE=passed\nPHYSICAL_DEVICE=passed\nASSET_SHA256="
            + release.digest(self.root / name)
            + "\n"
        )
        log.write_text(text)
        module.record(self.root, "android", "Fixture phone", log, output)
        self.assertEqual(set(release.read_json(output)[0]["assets"]), {name})
        output.unlink()
        log.write_text(text.replace("PHYSICAL_DEVICE=passed", "NOT_PHYSICAL_DEVICE=passed"))
        with self.assertRaises(ValueError):
            module.record(self.root, "android", "Fixture phone", log, output)


class ToolTests(unittest.TestCase):
    def test_archive_traversal_is_rejected(self):
        module = load_script("setup-tools")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            file = folder / "archive.zip"
            for name in ("../escape", "/escape", "C:/escape", "..\\escape"):
                with self.subTest(name=name):
                    with zipfile.ZipFile(file, "w") as bundle:
                        bundle.writestr(name, "unsafe")
                    with self.assertRaises(ValueError):
                        module.extract(file, folder / "out")

    def test_bad_download_hash_is_rejected(self):
        module = load_script("setup-tools")
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(
                module.urllib.request, "urlopen", return_value=io.BytesIO(b"changed")
            ):
                with self.assertRaisesRegex(ValueError, "SHA512"):
                    module.download(
                        "https://example.invalid/tool", Path(folder) / "tool", "0" * 128
                    )

    def test_known_warning_scope_and_new_warnings(self):
        module = load_script("check-warnings")
        allowed = "C:/build/_deps/dawn-src/src/dawn/native/d3d/UtilsD3D.cpp(423): warning C4715: 'dawn::native::d3d::DXGITextureFormat': not all control paths return a value"
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        source = Path(temporary.name)
        (source / "cmake").mkdir()
        rule = release.read_json(release.ROOT / "config/warnings.json")["windows-arm64"][0]
        (source / "cmake/deps.txt").write_text(rule["source"]["line"] + "\n")
        env = patch.dict(os.environ, {"ORT_SOURCE_DIR": str(source)})
        env.start()
        self.addCleanup(env.stop)
        module.check_warnings("windows-arm64", "1.31.0", allowed)
        module.check_warnings("windows-arm64", "1.32.0", allowed)
        for target, version, line in (
            ("windows-x64", "1.31.0", allowed),
            ("windows-arm64", "1.31.0", "other.cpp(1): warning C4013: undeclared function"),
            ("linux-arm64", "1.31.0", "other.cpp:1:2: warning: actual regression [-Wunused]"),
        ):
            with self.subTest(line=line, target=target, version=version):
                with self.assertRaises(ValueError):
                    module.check_warnings(target, version, line)
        (source / "cmake/deps.txt").write_text("dawn;changed-source;unknown-hash\n")
        with self.assertRaises(ValueError):
            module.check_warnings("windows-arm64", "1.32.0", allowed)

    def test_tool_installation_uses_verified_inputs_and_publishes_paths(self):
        import hashlib

        module = load_script("setup-tools")
        archives = {}
        for name, file in (("cmake", "cmake/bin/cmake"), ("vcpkg", "vcpkg/bootstrap-vcpkg.sh")):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr(file, "fixture")
            archives["https://fixture.invalid/" + name] = buffer.getvalue()
        config = {
            "hosts": {
                "linux-x64": {
                    "cmake": {
                        "url": "https://fixture.invalid/cmake",
                        "sha512": hashlib.sha512(
                            archives["https://fixture.invalid/cmake"]
                        ).hexdigest(),
                    }
                }
            },
            "vcpkg": {
                "url": "https://fixture.invalid/vcpkg",
                "sha512": hashlib.sha512(archives["https://fixture.invalid/vcpkg"]).hexdigest(),
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            release.write_json(root / "config/toolchains.json", config)
            env = {
                "RUNNER_TEMP": str(root),
                "GITHUB_PATH": str(root / "paths"),
                "GITHUB_ENV": str(root / "env"),
            }
            with (
                patch.object(module, "ROOT", root),
                patch.dict(os.environ, env),
                patch.object(
                    module.urllib.request,
                    "urlopen",
                    side_effect=lambda url, timeout: io.BytesIO(archives[url]),
                ),
                patch.object(module.subprocess, "run") as run,
                patch.object(
                    module.subprocess, "check_output", return_value="cmake version fixture\n"
                ),
            ):
                module.install("linux-x64")
            self.assertIn("-disableMetrics", run.call_args.args[0])
            self.assertIn("ort-tools/cmake/bin", (root / "paths").read_text())
            self.assertIn("VCPKG_DISABLE_METRICS=1", (root / "env").read_text())
            self.assertEqual(
                release.read_json(root / "ort-toolchain.json")["inputs"]["cmake"],
                config["hosts"]["linux-x64"]["cmake"],
            )

    def test_powershell_parser_keeps_errors_from_earlier_files(self):
        import shutil
        import subprocess

        if not shutil.which("pwsh"):
            self.skipTest("PowerShell is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(release.ROOT / "scripts/check-powershell.ps1", root / "check.ps1")
            (root / "a-bad.ps1").write_text("if (\n")
            (root / "z-good.ps1").write_text("Write-Output 'valid'\n")
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(root / "check.ps1")], capture_output=True
            )
            self.assertNotEqual(result.returncode, 0)


class SourceTests(unittest.TestCase):
    def test_source_only_reuses_published_version_without_weakening_release_checks(self):
        import subprocess

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "gh").write_text(
                "#!"
                + sys.executable
                + "\nimport json, os, sys\nendpoint = sys.argv[2]\nif endpoint.startswith('repos/microsoft/'):\n print(json.dumps({'tag_name': 'v1.31.0', 'draft': False, 'prerelease': os.environ.get('PRERELEASE') == '1'}))\nelse:\n sys.exit(0)\n"
            )
            (root / "git").write_text(
                "#!/usr/bin/env bash\nprintf '%s\\t%s\\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/v1.31.0\n"
            )
            (root / "gh").chmod(0o755)
            (root / "git").chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(root) + os.pathsep + os.environ["PATH"],
                "GITHUB_REPOSITORY": "ente/ort-packaging",
            }
            command = ["bash", str(release.ROOT / "scripts/resolve-release.sh"), "1.31.0", "1"]
            normal = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(normal.returncode, 0)
            self.assertIn("already exists", normal.stderr)
            source = subprocess.run(
                [*command, "--source-only"], env=env, capture_output=True, text=True
            )
            self.assertEqual(source.returncode, 0, source.stderr)
            self.assertIn("ort_commit=" + "b" * 40, source.stdout)
            rejected = subprocess.run(
                [*command, "--source-only"], env={**env, "PRERELEASE": "1"}, capture_output=True
            )
            self.assertNotEqual(rejected.returncode, 0)

    def test_patch_application_is_idempotent_and_rejects_drift(self):
        import subprocess

        module = load_script("prepare-source")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            file = source / "input.txt"
            file.write_text("original\n")
            subprocess.run(["git", "-C", str(source), "add", "."], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "Fixture",
                ],
                check=True,
            )
            commit = subprocess.check_output(
                ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
            ).strip()
            (root / "config").mkdir()
            (root / "patches").mkdir()
            (root / "patches/fix.patch").write_text(
                "diff --git a/input.txt b/input.txt\n--- a/input.txt\n+++ b/input.txt\n@@ -1 +1 @@\n-original\n+patched\n"
            )
            release.write_json(
                root / "config/patches.json", [{"file": "fix.patch", "platforms": ["linux"]}]
            )
            env = {
                "ORT_SOURCE_DIR": str(source),
                "ORT_COMMIT": commit,
                "BUILD_ROOT": str(root / "build"),
            }
            with patch.object(module, "ROOT", root), patch.dict(os.environ, env):
                module.prepare("linux")
                self.assertEqual(file.read_text(), "patched\n")
                module.prepare("linux")
                self.assertEqual(
                    release.read_json(root / "build/patches.json")[0]["status"], "already_present"
                )
                file.write_text("unexpected drift\n")
                with self.assertRaises(subprocess.CalledProcessError):
                    module.prepare("linux")
                with patch.dict(os.environ, {"ORT_COMMIT": "0" * 40}):
                    with self.assertRaisesRegex(ValueError, "commit mismatch"):
                        module.prepare("linux")

    def test_simulator_selection_rejects_unavailable_devices(self):
        module = load_script("select-ios-simulator")
        with self.assertRaises(ValueError):
            module.select(
                {
                    "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                        {"isAvailable": False, "udid": "bad"}
                    ]
                }
            )
        self.assertEqual(
            module.select(
                {
                    "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                        {"isAvailable": True, "udid": "good"}
                    ]
                }
            ),
            "good",
        )

    def test_ios_device_and_simulator_metadata(self):
        import plistlib

        module = load_script("write-ios-info")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "Info.plist"
            for sdk, expected in (("iphoneos", "iPhoneOS"), ("iphonesimulator", "iPhoneSimulator")):
                module.write_info(release.ROOT / "tests/ios-smoke-Info.plist", output, "16.2", sdk)
                info = plistlib.loads(output.read_bytes())
                self.assertEqual(info["MinimumOSVersion"], "16.2")
                self.assertEqual(info["CFBundleSupportedPlatforms"], [expected])


if __name__ == "__main__":
    unittest.main()
