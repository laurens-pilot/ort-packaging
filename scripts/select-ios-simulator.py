import json
import sys


def select(devices):
    for runtime, candidates in devices.items():
        if ".iOS-" in runtime:
            for device in candidates:
                if device.get("isAvailable"):
                    return device["udid"]
    raise ValueError("no available iOS Simulator")


if __name__ == "__main__":
    print(select(json.load(sys.stdin)["devices"]))
