import os
import subprocess
import sys
from pathlib import Path

from release import require


def preflight(host):
    source = Path(os.environ["ORT_SOURCE_DIR"])
    require(
        subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        == os.environ["ORT_COMMIT"],
        "source commit mismatch",
    )
    build = Path(os.environ["RUNNER_TEMP"]) / "compiler-check"
    configure = [
        "cmake",
        "-S",
        "tests",
        "-B",
        str(build),
        "-DORT_INCLUDE_DIR=" + str(source / "include/onnxruntime/core/session"),
    ]
    if host.startswith("windows-"):
        configure += [
            "-G",
            os.environ["CMAKE_GENERATOR"],
            "-A",
            "ARM64" if host.endswith("arm64") else "x64",
        ]
    subprocess.run(configure, check=True)
    subprocess.run(
        ["cmake", "--build", str(build), "--config", "Release", "--parallel"], check=True
    )
    subprocess.run(
        ["ctest", "--test-dir", str(build), "-C", "Release", "--output-on-failure"], check=True
    )
    if host == "macos-universal":
        subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], check=True)
        subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], check=True)


if __name__ == "__main__":
    preflight(sys.argv[1])
