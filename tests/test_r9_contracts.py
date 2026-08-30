#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    raise AssertionError(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)
    print(f"PASS: {message}")


def main() -> int:
    print("=== R9 release, deployment, and CI contracts ===")

    for makefile in ("core/Makefile", "status/Makefile", "geodata/Makefile"):
        content = read(makefile)
        require("PKG_VERSION:=3.7.1" in content, f"{makefile} keeps version 3.7.1")
        require("PKG_RELEASE:=9" in content, f"{makefile} declares release 9")
        require("PKGARCH:=all" in content, f"{makefile} declares architecture all")

    tracked = subprocess.check_output(
        ["git", "ls-files"], cwd=ROOT, text=True, encoding="utf-8"
    ).splitlines()
    forbidden_names = {
        "check_artifacts.py", "check_jobs.py", "check_runs.py", "fix_yaml.py",
        "jobs.json", "run.json", "logs.zip", "ci_status.txt", "get_ci_failure.py",
        "get_job_logs.py", "poll_ci.py", "run_page.html",
    }
    require(not any(pathlib.PurePosixPath(p).name in forbidden_names or p.startswith("scratch/") for p in tracked),
            "no contaminated diagnostic artifacts are tracked")
    workspace_files = [path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*")
                       if path.is_file() and ".git" not in path.parts]
    require(not any(pathlib.PurePosixPath(p).name in forbidden_names or p.startswith("scratch/") for p in workspace_files),
            "no contaminated diagnostic artifacts exist in the recovery worktree")

    workflow_path = ROOT / ".github/workflows/build-release.yml"
    workflow_bytes = workflow_path.read_bytes()
    require(b"\r\n" not in workflow_bytes and not workflow_bytes.startswith(b"\xef\xbb\xbf"),
            "workflow is UTF-8 without BOM and LF-only")
    workflow = workflow_bytes.decode("utf-8")
    workflow_document = yaml.safe_load(workflow)
    print("PASS: workflow YAML parses")
    job_env_values = (
        str(value)
        for job in workflow_document.get("jobs", {}).values()
        for value in job.get("env", {}).values()
    )
    require(all("${{ runner." not in value for value in job_env_values),
            "job-level workflow env avoids the unavailable runner context")

    exact_repositories = [
        "https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages/packages.adb",
        "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb",
        "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci/packages.adb",
        "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages/packages.adb",
        "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing/packages.adb",
        "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony/packages.adb",
        "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/video/packages.adb",
    ]
    bundle_script = read("scripts/build_r9_offline_bundle.sh")
    for root_package in ("coreutils", "coreutils-base64", "coreutils-timeout", "ip-full"):
        require(re.search(rf"^\s+{re.escape(root_package)}\s*$", bundle_script, re.MULTILINE) is not None,
                f"offline resolver includes operational root {root_package}")
    for repository in exact_repositories:
        require(repository in bundle_script, f"offline resolver uses exact repository {repository}")
    require("APKINDEX.tar.gz" not in workflow + bundle_script, "resolver never searches Alpine APKINDEX.tar.gz")
    require("apk manifest" not in workflow + bundle_script + read("install_and_smoke_r9.sh"),
            "APK metadata uses apk-tools v3 adbdump rather than file-checksum manifest output")
    require("--no-network" in bundle_script and "OFFLINE-TRANSACTION.log" in bundle_script,
            "bundle builder records a network-disabled transaction")
    require("strace" in bundle_script and "AF_INET" in bundle_script,
            "offline proof audits network syscalls")
    require("SHA256SUMS-R9.txt" in workflow and "sha256sum -c SHA256SUMS-R9.txt" in workflow,
            "bundle builder verifies complete R9 checksums")
    require("OFFLINE-PACKAGES-MANIFEST.txt" in bundle_script,
            "bundle builder emits the dependency manifest")
    critical_paths = (
        ".github/workflows/build-release.yml",
        "scripts/build_r9_offline_bundle.sh",
        "install_and_smoke_r9.sh",
        "tests/ci/checksum_lib.sh",
        "tests/ci/fetch_xray.sh",
        "tests/ci/run_target_ucode.sh",
        "tests/ci/verify_package_contents.sh",
        "tests/hardware/profile_mode_smoke.sh",
    )
    for critical_path in critical_paths:
        require("|| true" not in read(critical_path), f"{critical_path} contains no forbidden fail-open continuation")

    installer = read("install_and_smoke_r9.sh")
    require('R9_INSTALL_AND_HARDWARE_SMOKE_OK' in installer, "installer has the exact R9 success marker")
    require('run -test -config' in installer and 'xray test -c' not in installer,
            "installer uses the required Xray validation form")
    for package in ("kmod-nf-tproxy", "kmod-nft-tproxy", "firewall4", "luci-base", "dnsmasq", "ca-bundle"):
        require(package in installer, f"installer checks target prerequisite {package}")
    require("SHA256SUMS-R9.txt" in installer and "sha256sum -c" in installer,
            "installer verifies R9 checksums before mutation")
    require("--no-network" in installer and "--simulate" in installer,
            "installer simulates and installs offline")
    require("manifest metadata does not match" in installer and "manifest_source_allowed" in installer,
            "installer verifies dependency APK metadata and approved source provenance")
    require("timeout 5" in installer and "call list '{}'" in installer and "</dev/null" in installer,
            "installer bounds explicit-empty-object backend invocation with closed stdin")
    require("rm -rf /opt/xray/profiles" not in installer,
            "installer never deletes the complete production profile directory")

    hardware = read("tests/hardware/profile_mode_smoke.sh")
    require("HARDWARE_PROFILE_MODE_SMOKE_OK" in hardware, "hardware smoke has the exact success marker")
    require("jsonfilter" in hardware, "hardware smoke uses target-native structured JSON parsing")
    require("ip -6 rule" in hardware and "list ruleset" in hardware and "dnsmasq" in hardware,
            "hardware smoke compares IPv6, nftables, and dnsmasq state")
    require("xray_core.after.uci" in hardware and "enablement/running state was not restored" in hardware,
            "hardware smoke verifies exact UCI and service-state restoration")
    require("grep -o '\"id\"" not in hardware, "hardware smoke does not parse formatted JSON with grep")

    backend = read("core/root/usr/libexec/rpcd/xray_profiles")
    require("rand()" not in backend and "mkdtemp" in backend, "backend uses exclusive target-supported temporaries")
    require('readfile("/proc/self/stat")' in backend and "pid: 0" not in backend,
            "backend lock records a live owner PID")
    require('access(XRAY_BIN, "x")' in backend, "backend binary_found requires executable access")
    require("requires_geoip" in backend and "requires_geosite" in backend,
            "backend reports per-profile geodata requirements")
    require("assets_found" not in backend, "backend exposes no misleading global assets status")

    profiles_view = read("core/root/www/luci-static/resources/view/xray/profiles.js")
    require("handleSave: null" in profiles_view and "handleSaveApply: null" in profiles_view and "handleReset: null" in profiles_view,
            "profile page disables generic LuCI controls")
    require("refreshInFlight" in profiles_view, "profile polling prevents overlapping requests")

    print("All R9 contracts passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
