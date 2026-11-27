import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NAME = re.compile(r"(?:store-(?:en|zh-Hans|zh-Hant|ja)-(?:01-home|02-volume|03-temperature|04-speed|05-share)|paid-01-paywall)(?![a-zA-Z0-9])")
LANGS = ("en", "zh-Hans", "zh-Hant", "ja")
SCENES = ("01-home", "02-volume", "03-temperature", "04-speed", "05-share")
EXPECTED = {f"store-{language}-{shot}" for language in LANGS for shot in SCENES} | {"paid-01-paywall"}


def normalize(source, output, allow_partial=False):
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    selected = {}
    for test in manifest:
        for attachment in test.get("attachments", []):
            suggested = attachment.get("suggestedHumanReadableName", "")
            name = NAME.search(suggested)
            if not name:
                continue
            filename = Path(attachment["exportedFileName"])
            path = (source / filename).resolve()
            if not path.is_relative_to(source.resolve()) or not path.is_file():
                raise ValueError(f"Invalid attachment path: {filename}")
            with path.open("rb") as image:
                if image.read(8) != b"\x89PNG\r\n\x1a\n":
                    raise ValueError(f"Not a PNG: {filename}")
            key = name.group()
            if key in selected:
                raise ValueError(f"Duplicate named screenshot: {key}")
            selected[key] = path
    missing = EXPECTED - selected.keys()
    if (missing and not allow_partial) or not selected:
        raise ValueError("Missing named screenshots: " + ", ".join(sorted(missing)))
    output.mkdir(parents=True, exist_ok=True)
    for key, path in selected.items():
        shutil.copyfile(path, output / f"{key}.png")
    print(f"Exported {len(selected)} named PNG screenshots to {output}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--manifest-only", action="store_true")
    parser.add_argument("--allow-partial", action="store_true")
    args = parser.parse_args()
    if args.manifest_only:
        normalize(args.result, args.output, args.allow_partial)
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as folder:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.result),
                        "--output-path", folder], check=True)
        normalize(Path(folder), args.output, args.allow_partial)


if __name__ == "__main__":
    main()
