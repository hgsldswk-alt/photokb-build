"""Export named XCTest attachments via xcresulttool into the store pipeline."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SHOT = re.compile(r"(?:store-(?:en|zh-Hans|zh-Hant)-\d\d-[a-z0-9-]+|paid-01-paywall)(?=[_.\s]|$)")
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-home", "02-result", "03-copy", "04-batch", "05-rule-card")
EXPECTED = {f"store-{lang}-{scene}" for lang in LANGUAGES for scene in SCENES} | {"paid-01-paywall"}


def export_manifest(source: Path, destination: Path) -> set[str]:
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    files = {}
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            match = SHOT.search(name)
            if not match:
                continue
            shot = match.group()
            if shot not in EXPECTED:
                continue
            if shot in files:
                raise ValueError(f"Duplicate XCTest attachment: {shot}")
            file = source / attachment["exportedFileName"]
            with file.open("rb") as stream:
                if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                    raise ValueError(f"Expected PNG in attachment: {shot}")
            files[shot] = file
    if missing := EXPECTED - files.keys():
        raise ValueError("Missing XCTest attachments: " + ", ".join(sorted(missing)))
    destination.mkdir(parents=True, exist_ok=True)
    for name, file in files.items():
        shutil.copy2(file, destination / (name + ".png"))
    return set(files)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: export_shots.py <flow.xcresult> <output-directory>")
    with tempfile.TemporaryDirectory() as folder:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", sys.argv[1],
                        "--output-path", folder], check=True)
        names = export_manifest(Path(folder), Path(sys.argv[2]))
    print(f"Exported {len(names)} named screenshots")
