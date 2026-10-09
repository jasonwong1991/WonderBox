#!/usr/bin/env python3
"""Bind the packaged app to the actual signed helper before signing the app itself.

This is an ownership declaration for macOS, not the socket authentication policy.
The daemon still validates the authorizing UID and the client's exact signing requirement.
"""
import pathlib
import plistlib
import subprocess
import sys


def designated_requirement(output: str) -> str:
    # codesign prefixes an implicit (not explicitly embedded) DR with '# ', including ad-hoc
    # universal binaries whose default requirement is an OR of per-architecture code hashes.
    lines = [line[2:] if line.startswith("# ") else line for line in output.splitlines()]
    requirements = [line.removeprefix("designated => ") for line in lines if line.startswith("designated => ")]
    if len(requirements) != 1 or not requirements[0].strip():
        raise RuntimeError("Missing helper signing requirement")
    return requirements[0]


def configure(app: pathlib.Path) -> None:
    helper = app / "Contents/Helpers/WonderFanHelper"
    identifier = "com.wondercraft.WonderBox.FanHelper"
    result = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(helper)], check=True,
                            capture_output=True, text=True)
    requirement = designated_requirement(result.stdout + "\n" + result.stderr)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, str(helper)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "-R", f'=identifier "{identifier}"', str(helper)], check=True)
    info = app / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["SMPrivilegedExecutables"] = {identifier: requirement}
    info.write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_XML, sort_keys=False))


if __name__ == "__main__":
    configure(pathlib.Path(sys.argv[1]))
