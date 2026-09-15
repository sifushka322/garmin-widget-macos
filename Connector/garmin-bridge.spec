# Build a movable directory with the interpreter and all connector dependencies.
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, copy_metadata

datas, binaries, hiddenimports = [], [], []
for package in ("garminconnect", "curl_cffi", "ua_generator", "certifi"):
    package_data, package_binaries, package_imports = collect_all(package)
    datas.extend(package_data)
    binaries.extend(package_binaries)
    hiddenimports.extend(package_imports)

for package in ("garminconnect", "curl_cffi", "requests", "ua-generator"):
    datas.extend(copy_metadata(package))

analysis = Analysis(
    [str(Path(SPECPATH) / "bridge.py")], pathex=[SPECPATH],
    binaries=binaries, datas=datas, hiddenimports=hiddenimports,
    excludes=["tkinter", "pytest", "IPython", "pandas", "matplotlib"],
    noarchive=False,
)
archive = PYZ(analysis.pure)
executable = EXE(
    archive, analysis.scripts, [], exclude_binaries=True,
    name="garmin-bridge", debug=False, bootloader_ignore_signals=False,
    strip=False, upx=False, console=True, argv_emulation=False,
    target_arch=None, codesign_identity=None, entitlements_file=None,
)
collection = COLLECT(
    executable, analysis.binaries, analysis.datas,
    strip=False, upx=False, name="garmin-bridge",
)
