"""Collect redistribution notices from the build environment, never user data."""
from importlib import metadata
from pathlib import Path
import sys
import sysconfig

PACKAGES = (
    "garminconnect", "curl_cffi", "requests", "ua-generator", "certifi", "cffi",
    "pycparser", "charset-normalizer", "idna", "urllib3", "pyinstaller",
    "packaging", "setuptools", "altgraph", "macholib", "pyinstaller-hooks-contrib",
)


def main(destination: str) -> None:
    sections = ["Garmin Desk connector — third-party software notices\n",
                "Built with Python " + sys.version + "\n"]
    for package in PACKAGES:
        dist = metadata.distribution(package)
        sections.append(f"\n{'=' * 72}\n{dist.metadata['Name']} {dist.version}\n")
        sections.append("Project: " + (dist.metadata.get("Home-page") or "https://pypi.org/project/" + package) + "\n")
        for item in dist.files or []:
            if any(word in item.name.upper() for word in ("LICENSE", "COPYING", "NOTICE")):
                source = dist.locate_file(item)
                if source.is_file():
                    sections.append(f"\n{item.name}\n{source.read_text(errors='replace')}\n")
    python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
    if python_license.is_file():
        sections.append("\nPython runtime license\n" + python_license.read_text())
    else:
        sections.append("\nPython runtime license: https://docs.python.org/3/license.html\n")
    Path(destination).write_text("".join(sections), encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1])
