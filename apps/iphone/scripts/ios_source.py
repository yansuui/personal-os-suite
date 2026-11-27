"""Freeze and validate this app's exact iOS inputs without git push or credentials.

Uses only Python's standard library. Native validation requires macOS + Xcode
and XcodeGen; pack/check do not compile Swift or execute XCTest.
"""
import argparse
import hashlib
import io
import json
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

MANIFEST = "IOS-SOURCE.json"
ROOT = Path(__file__).resolve().parents[3]
FILES = (
    "apps/iphone/project.yml",
    "apps/iphone/scripts/ios_source.py",
    "apps/iphone/scripts/test_ios_source.py",
    "apps/iphone/scripts/validate-minimal-v2.cjs",
    "packages/contracts/MINIMAL-V2-CONTRACT.md",
    "packages/contracts/PHASE-2-GOALS-TASKS.md",
    "docs/P2-A-MACOS-VALIDATION.md",
)
TREES = (
    ("apps/iphone/Config", {".xcconfig"}),
    ("apps/iphone/Sources", {".swift"}),
    ("apps/iphone/Tests", {".swift"}),
    ("apps/iphone/Resources", {".json", ".png", ".jpg", ".jpeg", ".pdf", ".svg"}),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(root, name):
    """Never read through a symlink or a manifest-controlled traversal."""
    if not isinstance(name, str) or "\\" in name:
        raise ValueError("invalid source path")
    parts = name.split("/")
    if not parts or any(part in ("", ".", "..") or ":" in part for part in parts):
        raise ValueError("invalid source path: " + name)
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink() or (hasattr(current, "is_junction") and current.is_junction()):
            raise ValueError("symlink/junction is not a build input: " + name)
    if not current.resolve().is_relative_to(root):
        raise ValueError("resolved path is outside source root: " + name)
    return current


def collect(root):
    root = Path(root).resolve()
    paths = set(FILES)

    def walk(directory, extensions):
        for child in sorted(directory.iterdir()):
            name = child.relative_to(root).as_posix()
            safe_path(root, name)
            if child.is_dir():
                if child.name.startswith("."):
                    raise ValueError("unexpected hidden source directory: " + name)
                walk(child, extensions)
            elif child.is_file():
                # XcodeGen creates this file; it is excluded by project.yml.
                if name == "apps/iphone/Sources/POSApp/Info.plist":
                    continue
                if child.suffix.lower() not in extensions:
                    raise ValueError("unexpected build input: " + name)
                paths.add(name)
            else:
                raise ValueError("unsupported source entry: " + name)

    for name, extensions in TREES:
        walk(safe_path(root, name), extensions)
    return {name: safe_path(root, name).read_bytes() for name in sorted(paths)}


def records(inputs):
    return [{"path": name, "size": len(data), "sha256": digest(data)}
            for name, data in sorted(inputs.items())]


def source_hash(files):
    return digest(json.dumps(files, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def pack(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    if output.exists():
        raise ValueError("output already exists; choose a new path")
    if any(output.is_relative_to(root / name) for name, _ in TREES):
        raise ValueError("archive must be outside build input directories")
    inputs = collect(root)
    files = records(inputs)
    manifest = {"schemaVersion": 1, "createdAt": datetime.now(timezone.utc).isoformat(),
                "sourceHash": source_hash(files), "files": files}
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in inputs.items():
            archive.writestr(name, data)
        archive.writestr(MANIFEST, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    if records(collect(root)) != files:
        raise ValueError("source changed during packing; retry from a stable working tree")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("xb") as target:
        target.write(buffer.getvalue())
    return {"archive": str(output), "sourceHash": manifest["sourceHash"],
            "archiveSha256": digest(buffer.getvalue()), "inputFiles": len(files)}


def check(root):
    root = Path(root).resolve()
    manifest = json.loads(safe_path(root, MANIFEST).read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("invalid source manifest")
    files = manifest.get("files")
    if manifest.get("schemaVersion") != 1 or not isinstance(files, list) or not files:
        raise ValueError("unsupported or empty source manifest")
    names = []
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise ValueError("invalid manifest entry")
        safe_path(root, item["path"])
        names.append(item["path"])
    if names != sorted(set(names)) or source_hash(files) != manifest.get("sourceHash"):
        raise ValueError("manifest is inconsistent")
    actual = records(collect(root))
    if files != actual:
        raise ValueError("source differs from manifest (changed, missing or extra build input)")
    return manifest


def inspect_ipa(ipa):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        plist_name = "Payload/POSApp.app/Info.plist"
        info = plistlib.loads(archive.read(plist_name))
        if info.get("CFBundleIdentifier") != "com.personalos.ios":
            raise ValueError("unexpected app bundle identifier")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
            raise ValueError("invalid app executable")
        binary = archive.read("Payload/POSApp.app/" + executable)
        if len(binary) < 32 or binary[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", binary, 4)[0] != 0x0100000C:
            raise ValueError("expected a device arm64 Mach-O executable")
        for framework in ("POSCore", "POSFeatures"):
            if "Payload/POSApp.app/Frameworks/{0}.framework/{0}".format(framework) not in names:
                raise ValueError("missing embedded framework: " + framework)
        if not info.get("CFBundleShortVersionString") or not info.get("CFBundleVersion"):
            raise ValueError("missing app version")
        return {"bundleId": info["CFBundleIdentifier"],
                "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                "sha256": digest(Path(ipa).read_bytes())}


def validate_macos(root, output, destination):
    if sys.platform != "darwin":
        raise ValueError("native validation requires macOS; no Swift/XCTest result was produced")
    root, output = Path(root).resolve(), Path(output).resolve()
    manifest = check(root)
    for tool in ("xcodegen", "xcodebuild"):
        if shutil.which(tool) is None:
            raise ValueError("required tool is not installed: " + tool)
    if output.exists() or output == root or root.is_relative_to(output):
        raise ValueError("choose a new output directory outside source ancestors")
    if any(output.is_relative_to(root / name) for name, _ in TREES):
        raise ValueError("output must be outside build input directories")
    output.mkdir(parents=True)
    staged = output / "source"
    # Build a private copy: XcodeGen never overwrites the working tree's plist/project.
    inputs = collect(root)
    if records(inputs) != manifest["files"]:
        raise ValueError("source changed before staging")
    for name, data in inputs.items():
        target = staged / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (staged / MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    check(staged)
    project = staged / "apps/iphone"
    receipt = {"sourceHash": manifest["sourceHash"], "status": "FAILED", "steps": []}

    def run(label, command):
        with (output / (label + ".log")).open("w", encoding="utf-8") as log:
            result = subprocess.run(command, cwd=project, stdout=log, stderr=subprocess.STDOUT, check=False)
        receipt["steps"].append({"name": label, "command": command, "exitCode": result.returncode})
        if result.returncode:
            raise ValueError(label + " failed; see " + str(output / (label + ".log")))

    try:
        run("xcode-version", ["xcodebuild", "-version"])
        run("xcodegen-version", ["xcodegen", "--version"])
        run("generate", ["xcodegen", "generate", "--spec", "project.yml"])
        common = ["xcodebuild", "-project", "POSApp.xcodeproj", "-scheme", "POSApp"]
        run("test", common + ["test", "-destination", destination,
            "-derivedDataPath", str(output / "test-derived"), "-resultBundlePath", str(output / "Tests.xcresult")])
        run("release", common + ["build", "-configuration", "Release", "-sdk", "iphoneos",
            "-derivedDataPath", str(output / "release-derived"), "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="])
        check(staged)
        app = output / "release-derived/Build/Products/Release-iphoneos/POSApp.app"
        if not app.is_dir():
            raise ValueError("Release app is missing")
        ipa = output / "POSApp-unsigned.ipa"
        with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for file in sorted(app.rglob("*")):
                if file.is_symlink():
                    raise ValueError("unsupported symlink in app: " + str(file.relative_to(app)))
                if file.is_file():
                    archive.write(file, "Payload/POSApp.app/" + file.relative_to(app).as_posix())
        receipt["ipa"] = inspect_ipa(ipa)
        receipt["status"] = "BUILT_NOT_INSTALLED"
        return receipt
    except Exception as error:
        receipt["error"] = str(error)
        raise
    finally:
        (output / "validation-result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("pack", "check", "macos"):
        command = sub.add_parser(name)
        command.add_argument("--root", type=Path, default=ROOT)
        if name != "check":
            command.add_argument("--output", type=Path, required=True)
        if name == "macos":
            command.add_argument("--destination", required=True, help="xcodebuild iOS Simulator destination")
    args = parser.parse_args()
    try:
        if args.command == "pack":
            result = pack(args.root, args.output)
        elif args.command == "check":
            manifest = check(args.root)
            result = {"sourceHash": manifest["sourceHash"], "inputFiles": len(manifest["files"]),
                      "status": "SOURCE_VERIFIED_ONLY"}
        else:
            result = validate_macos(args.root, args.output, args.destination)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
