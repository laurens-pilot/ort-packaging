import hashlib
import os
import re
import sys
from pathlib import Path

from release import ROOT, read_json, require


def check_warnings(target, version, text):
    rules = read_json(ROOT / "config/warnings.json").get(target, [])

    def same_source(rule):
        file = Path(os.environ["ORT_SOURCE_DIR"]) / rule["source"]["file"]
        if not file.is_file():
            return False
        content = file.read_text()
        if "line" in rule["source"]:
            return rule["source"]["line"] in content.splitlines()
        return hashlib.sha256(content.encode()).hexdigest() == rule["source"]["sha256"]

    for raw in text.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", raw).replace("\\", "/")
        match = re.search(r"warning ([A-Z]+\d+): (.*)", line)
        if match and match[1] == "C4244" and (not match[2].strip() or match[2][0].isspace()):
            continue
        if not match and not re.search(
            r":\d+(?::\d+)?: warning:|(?:cc1plus|cc1|clang|gcc|g\+\+|ld|ld.lld|collect2): warning:",
            line,
        ):
            continue
        require(
            any(re.search(rule["pattern"], line) and same_source(rule) for rule in rules),
            f"unreviewed {target} ORT {version} warning: {line}",
        )


if __name__ == "__main__":
    try:
        check_warnings(sys.argv[1], sys.argv[2], Path(sys.argv[3]).read_text(errors="replace"))
    except ValueError as error:
        sys.exit(str(error))
