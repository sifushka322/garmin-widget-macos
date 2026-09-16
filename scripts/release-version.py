"""Read the checked-in app version for CI; reject host/widget drift."""
import pathlib
import plistlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
with (root / "Resources/Info.plist").open("rb") as stream:
    host = plistlib.load(stream)
with (root / "Resources/Widgets-Info.plist").open("rb") as stream:
    widget = plistlib.load(stream)
version = host["CFBundleShortVersionString"]
build = host["CFBundleVersion"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
    raise SystemExit("Invalid release version/build")
if any(host[key] != widget[key] for key in ("CFBundleShortVersionString", "CFBundleVersion")):
    raise SystemExit("Host and widget source versions differ")
print(f"version={version}")
print(f"build={build}")
