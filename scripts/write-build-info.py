import os
import platform
import re
import subprocess
import sys
from pathlib import Path

from release import ROOT, read_json, write_json


def build_info(target):
    build = Path(os.environ["BUILD_ROOT"])
    compilers = {}
    for file in build.rglob("CMakeCXXCompiler.cmake"):
        text = file.read_text(errors="replace")
        values = dict(re.findall(r'set\((CMAKE_CXX_COMPILER(?:_ID|_VERSION)?) "([^"]*)"\)', text))
        if values:
            compilers[str(file.relative_to(build))] = values
    info = {
        "target": target,
        "system": platform.platform(),
        "runner_image": os.environ.get("ImageVersion", "unknown"),
        "compilers": compilers,
        "patches": read_json(build / "patches.json"),
        "policy": (ROOT / "build.env").read_text(),
    }
    toolchain = Path(os.environ["RUNNER_TEMP"]) / "ort-toolchain.json"
    if toolchain.is_file():
        info["toolchain"] = read_json(toolchain)
    if sys.platform == "darwin":
        info["xcode"] = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
        info["sdk"] = subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip()
    write_json(Path(os.environ["DIST_ROOT"]) / target / "build-info.json", info)


if __name__ == "__main__":
    build_info(sys.argv[1])
