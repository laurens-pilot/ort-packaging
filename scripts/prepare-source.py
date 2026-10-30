import os
import subprocess
import sys
from pathlib import Path

from release import ROOT, digest, read_json, require, write_json


def prepare(platform):
    source = Path(os.environ["ORT_SOURCE_DIR"])
    commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    require(commit == os.environ["ORT_COMMIT"], "upstream source commit mismatch")
    require(
        platform in {"all", "android", "ios", "linux", "macos", "windows"},
        "unknown source platform",
    )
    inventory = read_json(ROOT / "config/patches.json")
    names = [rule["file"] for rule in inventory]
    require(
        len(names) == len(set(names))
        and set(names) == {file.name for file in (ROOT / "patches").glob("*.patch")},
        "patch inventory mismatch",
    )
    records = []
    for rule in inventory:
        patch = ROOT / "patches" / rule["file"]
        status = "not_applicable"
        if platform in rule["platforms"] or platform == "all":
            condition = rule.get("contains")
            needed = (
                not condition
                or (source / condition[0]).is_file()
                and condition[1] in (source / condition[0]).read_text()
            )
            if needed:
                command = ["git", "-C", str(source), "apply"]
                reverse = subprocess.run(
                    [*command, "--reverse", "--check", str(patch)], capture_output=True
                )
                if reverse.returncode == 0:
                    status = "already_present"
                else:
                    subprocess.run([*command, "--check", str(patch)], check=True)
                    subprocess.run([*command, str(patch)], check=True)
                    status = "applied"
        records.append({"file": rule["file"], "sha256": digest(patch), "status": status})
    output = Path(os.environ["BUILD_ROOT"])
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "patches.json", records)


if __name__ == "__main__":
    prepare(sys.argv[1])
