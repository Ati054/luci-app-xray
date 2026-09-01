#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import tempfile
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("r10_apk_manifest", ROOT / "scripts/r10_apk_manifest.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")


def main() -> int:
    require(MODULE.split_version("1.2.3-r10") == ("1.2.3", "r10"), "APK r-release splits canonically")
    require(MODULE.split_version("2026.08-2") == ("2026.08", "2"), "numeric package release splits canonically")

    completed = subprocess.CompletedProcess(args=[], returncode=0,
        stdout='{"info":{"name":"demo","version":"1.0-r2","arch":"all","depends":["libc","zlib"]}}',
        stderr="")
    with mock.patch.object(MODULE.subprocess, "run", return_value=completed) as run:
        parsed = MODULE.parse_metadata(pathlib.Path("/sdk/apk"), pathlib.Path("demo.apk"))
    require(parsed == {"name": "demo", "version": "1.0-r2", "arch": "all", "depends": "libc zlib"},
            "adbdump JSON parser preserves required metadata and direct dependencies")
    run.assert_called_once()
    require(run.call_args.args[0][1:4] == ["adbdump", "--format", "json"],
            "metadata inspection invokes the actual apk-tools v3 adbdump interface")

    missing = subprocess.CompletedProcess(args=[], returncode=0,
        stdout='{"info":{"name":"demo","version":"1.0-r2"}}', stderr="")
    with mock.patch.object(MODULE.subprocess, "run", return_value=missing):
        try:
            MODULE.parse_metadata(pathlib.Path("/sdk/apk"), pathlib.Path("demo.apk"))
        except ValueError:
            pass
        else:
            raise AssertionError("manifest parser accepted missing architecture")
    print("PASS: incomplete APK metadata fails closed")

    with tempfile.TemporaryDirectory() as temp_dir:
        urls = pathlib.Path(temp_dir) / "urls.txt"
        urls.write_text(
            "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/demo.apk\n",
            encoding="utf-8",
        )
        sources = MODULE.load_sources(urls)
        require(sources["demo.apk"].endswith("/base/packages.adb"),
                "fetch provenance maps APK to its exact packages.adb repository")

        urls.write_text(
            "https://one.invalid/repo/demo.apk\nhttps://two.invalid/repo/demo.apk\n",
            encoding="utf-8",
        )
        try:
            MODULE.load_sources(urls)
        except ValueError:
            pass
        else:
            raise AssertionError("ambiguous APK provenance was accepted")
        print("PASS: ambiguous APK provenance fails closed")

    print("All R10 APK manifest unit tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
