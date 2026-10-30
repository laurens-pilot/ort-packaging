import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from release import ROOT, read_json, require, write_json


def download(url, destination, expected):
    for attempt in range(3):
        try:
            with (
                urllib.request.urlopen(url, timeout=120) as response,
                destination.open("wb") as output,
            ):
                shutil.copyfileobj(response, output)
            break
        except (OSError, urllib.error.URLError):
            if attempt == 2:
                raise
            time.sleep(2**attempt)
    require(
        hashlib.sha512(destination.read_bytes()).hexdigest() == expected, f"SHA512 mismatch: {url}"
    )


def extract(archive, output):
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as bundle:
            for entry in bundle.infolist():
                require(
                    not re.match(r"^[A-Za-z]:", entry.filename)
                    and not entry.filename.startswith(("/", "\\"))
                    and ".." not in Path(entry.filename.replace("\\", "/")).parts,
                    "unsafe ZIP entry",
                )
            bundle.extractall(output)
            for entry in bundle.infolist():
                mode = entry.external_attr >> 16
                if mode and not entry.is_dir():
                    (output / entry.filename).chmod(mode & 0o777)
    else:
        with tarfile.open(archive) as bundle:
            bundle.extractall(output, filter="data")
    roots = list(output.iterdir())
    require(len(roots) == 1 and roots[0].is_dir(), "expected one archive root")
    return roots[0]


def install(host):
    config = read_json(ROOT / "config/toolchains.json")
    spec = config["hosts"][host]
    tools = Path(os.environ["RUNNER_TEMP"]) / "ort-tools"
    tools.mkdir(exist_ok=True)
    installed = {}
    for name, package in (("cmake", spec["cmake"]), ("vcpkg", config["vcpkg"])):
        destination = tools / name
        require(not destination.exists(), f"tool directory already exists: {destination}")
        with tempfile.TemporaryDirectory(dir=os.environ["RUNNER_TEMP"]) as folder:
            folder = Path(folder)
            archive = folder / "archive"
            download(package["url"], archive, package["sha512"])
            unpacked = folder / "unpacked"
            unpacked.mkdir()
            shutil.move(str(extract(archive, unpacked)), destination)
        installed[name] = destination
    cmake_bin = installed["cmake"] / (
        "CMake.app/Contents/bin" if host == "macos-universal" else "bin"
    )
    os.environ["PATH"] = str(cmake_bin) + os.pathsep + os.environ["PATH"]
    if os.name == "nt":
        subprocess.run(
            ["cmd.exe", "/c", str(installed["vcpkg"] / "bootstrap-vcpkg.bat"), "-disableMetrics"],
            check=True,
        )
    else:
        subprocess.run(
            ["bash", str(installed["vcpkg"] / "bootstrap-vcpkg.sh"), "-disableMetrics"], check=True
        )
    with Path(os.environ["GITHUB_PATH"]).open("a") as output:
        output.write(str(cmake_bin) + "\n")
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write(f"VCPKG_INSTALLATION_ROOT={installed['vcpkg']}\nVCPKG_DISABLE_METRICS=1\n")
        if "generator" in spec:
            output.write(f"CMAKE_GENERATOR={spec['generator']}\n")
    version = subprocess.check_output(
        [str(cmake_bin / ("cmake.exe" if os.name == "nt" else "cmake")), "--version"], text=True
    ).splitlines()[0]
    write_json(
        Path(os.environ["RUNNER_TEMP"]) / "ort-toolchain.json",
        {
            "host": host,
            "cmake": version,
            "inputs": {"cmake": spec["cmake"], "vcpkg": config["vcpkg"]},
            "runner_image": os.environ.get("ImageVersion", "unknown"),
        },
    )


if __name__ == "__main__":
    install(sys.argv[1])
