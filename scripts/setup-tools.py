import hashlib
import http.client
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path


def download(url, destination):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                destination.write_bytes(response.read())
            return
        except (OSError, http.client.HTTPException):
            if attempt == 2:
                raise
            time.sleep(2**attempt)


def install(host):
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / "config/toolchains.json").read_text())
    spec = config["hosts"][host]
    tools = Path(os.environ["RUNNER_TEMP"]) / "ort-tools"
    tools.mkdir()
    for name, package in (("cmake", spec["cmake"]), ("vcpkg", config["vcpkg"])):
        with tempfile.TemporaryDirectory(dir=tools) as folder:
            folder = Path(folder)
            archive = folder / "archive"
            download(package["url"], archive)
            if hashlib.sha512(archive.read_bytes()).hexdigest() != package["sha512"]:
                raise ValueError(f"SHA512 mismatch: {package['url']}")
            unpacked = folder / "unpacked"
            if zipfile.is_zipfile(archive):
                with zipfile.ZipFile(archive) as bundle:
                    bundle.extractall(unpacked)
            else:
                with tarfile.open(archive) as bundle:
                    bundle.extractall(unpacked, filter="data")
            roots = list(unpacked.iterdir())
            if len(roots) != 1 or not roots[0].is_dir():
                raise ValueError(f"Expected one archive root: {package['url']}")
            shutil.move(str(roots[0]), tools / name)
    cmake_bin = tools / "cmake" / ("CMake.app/Contents/bin" if host == "macos-universal" else "bin")
    os.environ["PATH"] = str(cmake_bin) + os.pathsep + os.environ["PATH"]
    bootstrap = (
        tools / "vcpkg" / ("bootstrap-vcpkg.bat" if os.name == "nt" else "bootstrap-vcpkg.sh")
    )
    command = ["cmd.exe", "/c"] if os.name == "nt" else ["bash"]
    subprocess.run([*command, str(bootstrap), "-disableMetrics"], check=True)
    with Path(os.environ["GITHUB_PATH"]).open("a") as output:
        output.write(str(cmake_bin) + "\n")
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write(f"VCPKG_INSTALLATION_ROOT={tools / 'vcpkg'}\nVCPKG_DISABLE_METRICS=1\n")
        if "generator" in spec:
            output.write(f"CMAKE_GENERATOR={spec['generator']}\n")


if __name__ == "__main__":
    install(sys.argv[1])
