import plistlib
import sys
from pathlib import Path


def write_info(template, destination, minimum, sdk):
    value = plistlib.loads(Path(template).read_bytes())
    value["MinimumOSVersion"] = minimum
    value["CFBundleSupportedPlatforms"] = ["iPhoneOS" if sdk == "iphoneos" else "iPhoneSimulator"]
    value["UIDeviceFamily"] = [1, 2]
    Path(destination).write_bytes(plistlib.dumps(value))


if __name__ == "__main__":
    write_info(*sys.argv[1:])
