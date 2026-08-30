#!/usr/bin/env python3
"""Create and verify the canonical R9 dependency manifest from real APK files."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys


def parse_metadata(apk_bin: pathlib.Path, apk_file: pathlib.Path) -> dict[str, str]:
    result = subprocess.run(
        [str(apk_bin), "adbdump", "--format", "json", str(apk_file)],
        check=True,
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    document = json.loads(result.stdout)
    info = document.get("info") if isinstance(document, dict) else None
    if not isinstance(info, dict):
        raise ValueError(f"{apk_file.name}: adbdump JSON has no package info object")

    dependencies = info.get("depends", [])
    if isinstance(dependencies, list):
        dependencies_text = " ".join(str(value) for value in dependencies)
    elif isinstance(dependencies, str):
        dependencies_text = dependencies
    else:
        raise ValueError(f"{apk_file.name}: invalid depends metadata type")

    values = {
        "name": str(info.get("name", "")).strip(),
        "version": str(info.get("version", "")).strip(),
        "arch": str(info.get("arch", "")).strip(),
        "depends": " ".join(dependencies_text.split()),
    }
    missing = [field for field in ("name", "version", "arch") if not values[field]]
    if missing:
        raise ValueError(f"{apk_file.name}: missing APK metadata fields {missing}")
    return values


def split_version(value: str) -> tuple[str, str]:
    match = re.fullmatch(r"(.+)-r([0-9]+)", value)
    if match:
        return match.group(1), f"r{match.group(2)}"
    match = re.fullmatch(r"(.+)-([0-9]+)", value)
    if match:
        return match.group(1), match.group(2)
    return value, ""


def load_sources(url_file: pathlib.Path) -> dict[str, str]:
    sources: dict[str, str] = {}
    for raw_line in url_file.read_text(encoding="utf-8").splitlines():
        url = raw_line.strip()
        if not url or url.startswith("#"):
            continue
        filename = url.rsplit("/", 1)[-1]
        if not filename.endswith(".apk"):
            continue
        repository = url.rsplit("/", 1)[0] + "/packages.adb"
        previous = sources.setdefault(filename, repository)
        if previous != repository:
            raise ValueError(f"ambiguous source repositories for {filename}: {previous}, {repository}")
    return sources


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk-bin", required=True, type=pathlib.Path)
    parser.add_argument("--apk-dir", type=pathlib.Path)
    parser.add_argument("--urls", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--inspect", type=pathlib.Path)
    parser.add_argument("--field", choices=("name", "version", "arch", "depends"))
    args = parser.parse_args()

    if args.inspect:
        if not args.field:
            raise ValueError("--inspect requires --field")
        print(parse_metadata(args.apk_bin, args.inspect)[args.field])
        return 0
    if not args.apk_dir or not args.urls or not args.output:
        raise ValueError("manifest mode requires --apk-dir, --urls, and --output")

    sources = load_sources(args.urls)
    apk_files = sorted(args.apk_dir.glob("*.apk"), key=lambda path: path.name)
    if not apk_files:
        raise ValueError("dependency directory contains no APK files")

    rows: list[str] = []
    package_names: set[str] = set()
    for apk_file in apk_files:
        if apk_file.stat().st_size <= 0:
            raise ValueError(f"zero-byte APK: {apk_file.name}")
        metadata = parse_metadata(args.apk_bin, apk_file)
        if metadata["name"] in package_names:
            raise ValueError(f"duplicate package in dependency closure: {metadata['name']}")
        package_names.add(metadata["name"])
        if metadata["name"].startswith("kmod-") or metadata["name"] == "kernel":
            raise ValueError(f"kernel package must not enter the userland artifact: {metadata['name']}")
        if metadata["arch"] not in {"aarch64_cortex-a53", "aarch64", "all", "noarch"}:
            raise ValueError(f"unexpected architecture {metadata['arch']} in {apk_file.name}")
        if apk_file.name not in sources:
            raise ValueError(f"no fetch provenance URL recorded for {apk_file.name}")

        version, release = split_version(metadata["version"])
        digest = hashlib.sha256(apk_file.read_bytes()).hexdigest()
        rows.append(
            ";".join(
                [
                    apk_file.name,
                    metadata["name"],
                    version,
                    release,
                    metadata["arch"],
                    str(apk_file.stat().st_size),
                    digest,
                    metadata["depends"],
                    sources[apk_file.name],
                ]
            )
        )

    header = "filename;package;version;release;architecture;bytes;sha256;direct_dependencies;source_repository"
    args.output.write_text(header + "\n" + "\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    print(f"Wrote {len(rows)} dependency records to {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
