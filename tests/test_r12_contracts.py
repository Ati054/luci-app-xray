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
    print("=== R12 release, deployment, and CI contracts ===")

    for makefile in ("core/Makefile", "status/Makefile", "geodata/Makefile"):
        content = read(makefile)
        require("PKG_VERSION:=3.7.1" in content, f"{makefile} keeps version 3.7.1")
        require("PKG_RELEASE:=12" in content, f"{makefile} declares release 12")
        if makefile == "core/Makefile":
            require("PKGARCH:=$(ARCH_PACKAGES)" in content,
                    "core/Makefile declares the native target architecture")
        else:
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
    workflow_branches = workflow_document.get(True, {}).get("push", {}).get("branches", [])
    require(workflow_branches == ["codex/r12-profile-metrics"],
            "workflow is restricted to the dedicated R12 branch")
    for package_name in (
        "luci-app-xray_3.7.1-12_x86_64.ipk",
        "luci-app-xray-status_3.7.1-12_all.ipk",
        "luci-app-xray-3.7.1-r12.apk",
        "luci-app-xray-status-3.7.1-r12.apk",
    ):
        require(package_name in workflow, f"workflow pins exact R12 artifact {package_name}")
    require("package_release=12" in workflow,
            "workflow records release 12 in build metadata")
    require("package_architecture=${{ matrix.target_arch }}" in workflow,
            "workflow records the compiled core target architecture")
    require("v26.10.21" in workflow and "Xray-linux-arm64-v8a.zip" in workflow and
            '"$DIST_DIR/xray-core-26.10.21-linux-arm64"' in workflow,
            "artifact pins and carries the verified official Xray 26.10.21 ARM64 binary")
    require("ARM_VERSION_OUTPUT" in workflow and
            "qemu-aarch64-static" in workflow and
            "qemu-aarch64-static \"$RUNNER_TEMP/xray-arm64/xray\" version 2>&1 | head" not in workflow,
            "ARM64 version proof avoids a pipefail/SIGPIPE false failure")
    require('echo "xray_core_version=26.10.21"' in workflow and
            'echo "xray_core_source_asset=Xray-linux-arm64-v8a.zip"' in workflow,
            "artifact metadata records the exact Xray core version and source asset")
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
    bundle_script = read("scripts/build_r12_offline_bundle.sh")
    for root_package in ("coreutils", "coreutils-base64", "coreutils-timeout", "ip-full", "openssl-util", "ss", "uclient-fetch"):
        require(re.search(rf"^\s+{re.escape(root_package)}\s*$", bundle_script, re.MULTILINE) is not None,
                f"offline resolver includes operational root {root_package}")
    for repository in exact_repositories:
        require(repository in bundle_script, f"offline resolver uses exact repository {repository}")
    require("APKINDEX.tar.gz" not in workflow + bundle_script, "resolver never searches Alpine APKINDEX.tar.gz")
    require("apk manifest" not in workflow + bundle_script + read("install_and_smoke_r12.sh"),
            "APK metadata uses apk-tools v3 adbdump rather than file-checksum manifest output")
    require("--no-network" in bundle_script and "OFFLINE-TRANSACTION.log" in bundle_script,
            "bundle builder records a network-disabled transaction")
    require("capture_apk_help" in bundle_script and
            "${help_rc} -eq 0 || ${help_rc} -eq 1" in bundle_script and
            '[[ -s "${output}" ]]' in bundle_script,
            "bundle builder validates apk-tools v3 help output despite status 1")
    require("grep -q -- '--network'" in bundle_script and
            bundle_script.count("--no-network") >= 3,
            "bundle builder maps apk v3 boolean help to fail-closed no-network transactions")
    require("grep -q -- '--usermode' \"${ADD_HELP}\"" in bundle_script and
            "--usermode \\\n    --root \"${SIM_ROOT}\"" in bundle_script and
            "add --initdb --no-cache --no-network" in bundle_script and
            bundle_script.count("--usermode") == 2,
            "bundle builder uses apk usermode only while initializing the isolated database")
    require("strace" in bundle_script and "AF_INET" in bundle_script,
            "offline proof audits network syscalls")
    require("SHA256SUMS-R12.txt" in workflow and "sha256sum -c SHA256SUMS-R12.txt" in workflow,
            "bundle builder verifies complete R12 checksums")
    require("luci-app-xray-3.7.1-r12-openwrt-25.12.5-aarch64_cortex-a53.tar.gz" in workflow and
            "XRAY_RELEASE_SIGNING_KEY_PEM" in workflow and
            "openssl dgst -sha256 -sign" in workflow and
            "release-assets/release.json.sig" in workflow,
            "tag releases publish a signed complete Raspberry update bundle")
    require("xray-sockstats-aarch64" in workflow and
            '"$APK_HOST" --allow-untrusted extract --no-chown' in workflow,
            "artifact carries the exact extracted aarch64 collector for pre-transaction probing")
    require('tar -tzf "$DIST_DIR/$BUNDLE_NAME" > "$BUNDLE_LIST"' in workflow and
            'grep -Fxq \'install_and_smoke_r12.sh\' "$BUNDLE_LIST"' in workflow and
            'tar -tzf "$DIST_DIR/$BUNDLE_NAME" | grep' not in workflow,
            "bundle verification avoids pipefail false failures from tar SIGPIPE")
    require("deploy_r12_to_raspberry.ps1" in workflow,
            "artifact carries the one-command Windows deployment helper")
    bundle_call = workflow.index('bash "$GITHUB_WORKSPACE/scripts/build_r12_offline_bundle.sh"')
    collector_copy = workflow.index('"$DIST_DIR/xray-sockstats-aarch64"')
    require(bundle_call < collector_copy,
            "offline bundle receives an empty output directory before the collector is added")
    require("OFFLINE-PACKAGES-MANIFEST.txt" in bundle_script,
            "bundle builder emits the dependency manifest")
    require("kmod-netlink-diag" in bundle_script and
            '"${PACKAGE_NAME}" != kmod-netlink-diag' in bundle_script and
            "kmod-tcp-bbr" in bundle_script and
            '"${PACKAGE_NAME}" != kmod-tcp-bbr' in bundle_script,
            "bundle includes the exact kernel dependencies required by metrics and reverse BBR")
    manifest_builder = read("scripts/r12_apk_manifest.py")
    require('"kmod-netlink-diag", "kmod-tcp-bbr"' in manifest_builder and
            "is_forbidden_kernel_package" in manifest_builder,
            "dependency manifest permits exactly the two approved runtime kernel modules")
    package_verifier = read("tests/ci/verify_package_contents.sh")
    require("extract --help" not in package_verifier and
            '"${SDK_APK}" --allow-untrusted extract' in package_verifier,
            "APK verification relies on real extraction, not a nonzero help probe")
    setup_ucode = read("tests/ci/setup_ucode.sh")
    require("/opt/ucode-pinned/bin/ucode -v" not in setup_ucode and
            "ucode runtime loaded successfully" in setup_ucode,
            "SDK-selected ucode is verified through a supported evaluation")
    ucode_sweep = read("tests/test_ucode_modules.sh")
    require("import * as module_under_test" in ucode_sweep and
            'compile_source="${module}"' in ucode_sweep and
            "-cdynlink=ubus -o /dev/null" in ucode_sweep,
            "ucode sweep compiles executables directly and modules through imports")
    target_ucode = read("tests/ci/run_target_ucode.sh")
    require("--usermode \\\n    --root \"${ROOT}\"" in target_ucode and
            "add --initdb --no-cache --no-network" in target_ucode and
            target_ucode.count("--usermode") == 1,
            "target ucode proof initializes its non-root apk database in usermode")
    require('--destination "${CORE_PAYLOAD}" "${CORE_APK}"' in target_ucode and
            'cp -a "${CORE_PAYLOAD}/." "${ROOT}/"' in target_ucode,
            "target ucode proof extracts the core payload before layering it onto the apk root")
    require("import * as module_under_test" in target_ucode and
            "-cdynlink=ubus -o /dev/null" in target_ucode and
            "exact target ucode rejected installed module ${target_module}" in target_ucode,
            "target ucode proof imports modules and preserves per-file failure diagnostics")
    require("if ! sudo chroot" in target_ucode and
            "target gen_config.uc execution failed" in target_ucode,
            "target ucode proof reports entrypoint failures before cleanup")
    critical_paths = (
        ".github/workflows/build-release.yml",
        "scripts/build_r12_offline_bundle.sh",
        "install_and_smoke_r12.sh",
        "tests/ci/checksum_lib.sh",
        "tests/ci/fetch_xray.sh",
        "tests/ci/run_target_ucode.sh",
        "tests/ci/verify_package_contents.sh",
        "tests/hardware/profile_mode_smoke.sh",
    )
    for critical_path in critical_paths:
        require("|| true" not in read(critical_path), f"{critical_path} contains no forbidden fail-open continuation")

    installer = read("install_and_smoke_r12.sh")
    require('R12_INSTALL_AND_HARDWARE_SMOKE_OK' in installer, "installer has the exact R12 success marker")
    require('run -test -config' in installer and 'xray test -c' not in installer,
            "installer uses the required Xray validation form")
    for package in ("kmod-nf-tproxy", "kmod-nft-tproxy", "firewall4", "luci-base", "dnsmasq", "ca-bundle"):
        require(package in installer, f"installer checks target prerequisite {package}")
    require("SHA256SUMS-R12.txt" in installer and "sha256sum -c" in installer,
            "installer verifies R12 checksums before mutation")
    require("--no-network" in installer and "--simulate" in installer and "--force-reinstall" in installer,
            "installer simulates and force-reinstalls same-release hotfixes offline")
    require("BLOCKED: POST_TRANSACTION_HARDWARE_FAILURE" in installer,
            "installer emits the exact hard-stop marker after a package transaction failure")
    require("manifest metadata does not match" in installer and "manifest_source_allowed" in installer,
            "installer verifies dependency APK metadata and approved source provenance")
    require("timeout 5" in installer and "call list '{}'" in installer and "</dev/null" in installer,
            "installer bounds explicit-empty-object backend invocation with closed stdin")
    require("/etc/init.d/rpcd restart" in installer and
            "timeout 5 ubus wait_for session" in installer and
            installer.index("/etc/init.d/rpcd restart") > installer.index("apk add --force-reinstall --no-network"),
            "installer reloads rpcd ACL definitions after the offline package transaction")
    require("command -v ss" in installer and "installed traffic metrics dependency kmod-netlink-diag" in installer and
            "/usr/libexec/xray-sockstats" in installer,
            "installer verifies the native and fallback traffic metrics runtime after the offline transaction")
    require("rm -rf /opt/xray/profiles" not in installer,
            "installer never deletes the complete production profile directory")
    require("mktemp -d /opt/" not in installer and "[ -d /opt ] && [ -w /opt ]" in installer,
            "installer performs no temporary diagnostic writes outside /tmp")
    require("COLLECTOR_PROBE_AVAILABLE" in installer and
            "Native TCP_INFO collector preflight passed before backup" in installer and
            installer.index("COLLECTOR_PROBE_AVAILABLE") < installer.index("BACKUP_READY=1"),
            "installer proves pidfd/TCP_INFO compatibility before backup and package mutation")
    require("xray-core-26.10.21-linux-arm64" in installer and
            "Xray 26.10.21 and all stored profiles passed preflight before backup" in installer and
            'mv -f "${XRAY_STAGE_PATH}" "${XRAY_BIN}"' in installer and
            "for required_command in awk find grep jsonfilter modprobe pidof sed sha256sum sort sync wc" in installer and
            installer.count("\nsync\n") >= 2 and
            installer.index("\nsync\n") < installer.index('mv -f "${XRAY_STAGE_PATH}" "${XRAY_BIN}"') and
            installer.index("\nsync\n", installer.index('mv -f "${XRAY_STAGE_PATH}" "${XRAY_BIN}"')) > installer.index('mv -f "${XRAY_STAGE_PATH}" "${XRAY_BIN}"') and
            "build metadata does not pin Xray core 26.10.21" in installer and
            installer.index("all stored profiles passed preflight") < installer.index("BACKUP_READY=1"),
            "installer validates Xray 26.10.21 and durably flushes it before and after the atomic core replacement")
    require("profiles-before.json" in installer and "running-profile-ids.txt" in installer and
            "unsafe running profile ID" in installer and
            installer.index("profiles-before.json") < installer.index("BACKUP_READY=1"),
            "installer captures and validates the exact active-profile set before mutation")
    smoke_call = installer.index('sh "${SCRIPT_DIR}/profile_mode_smoke.sh"')
    data_restore = installer.index("\nrestore_data_backup\n", smoke_call)
    service_restore = installer.index("\nrestore_pretransaction_services\n", data_restore)
    restored_verify = installer.index("\nverify_pretransaction_services_restored\n", service_restore)
    success_marker = installer.index('console "R12_INSTALL_AND_HARDWARE_SMOKE_OK"', restored_verify)
    require(smoke_call < data_restore < service_restore < restored_verify < success_marker and
            "restored running profile count" in installer and
            "has invalid restored PID" in installer,
            "successful install restores data and the exact active-profile state before success")
    restore_body = installer.split("restore_pretransaction_services() {", 1)[1].split("\n}", 1)[0]
    enable_restore = restore_body.index("for service_name in xray_core xray_profiles")
    require(restore_body.index("stop_service_strict xray_core") < enable_restore and
            restore_body.index("stop_service_strict xray_profiles") < enable_restore,
            "service restoration clears package-hook runtime state before applying the snapshot")

    hardware = read("tests/hardware/profile_mode_smoke.sh")
    require("HARDWARE_PROFILE_MODE_SMOKE_OK" in hardware, "hardware smoke has the exact success marker")
    require("jsonfilter" in hardware, "hardware smoke uses target-native structured JSON parsing")
    require("ip -6 rule" in hardware and "list ruleset" in hardware and "dnsmasq" in hardware,
            "hardware smoke compares IPv6, nftables, and dnsmasq state")
    require("native TCP_INFO traffic metrics are unavailable" in hardware and
            "traffic.bytes_available" in hardware and "traffic.uptime_seconds" in hardware and
            "traffic.retrans_available" in hardware and "traffic.retrans_bytes" in hardware and
            "protocol_stack" in hardware,
            "hardware smoke verifies native per-profile metrics, retransmissions, protocol labels, and process uptime")
    require("xray_core.after.uci" in hardware and "enablement/running state was not restored" in hardware,
            "hardware smoke verifies exact UCI and service-state restoration")
    restore_services_body = hardware.split("restore_services() {", 1)[1].split("\n}", 1)[0]
    restored_state_check = hardware.index("for restored_service in xray_core xray_profiles")
    require("FINAL_DISABLED" not in hardware and "leave_services_disabled" not in hardware and
            hardware.rindex("\nrestore_services\n", 0, restored_state_check) < restored_state_check and
            restored_state_check < hardware.rindex('echo "HARDWARE_PROFILE_MODE_SMOKE_OK"'),
            "hardware smoke restores and verifies its saved service state before success")
    require("grep -o '\"id\"" not in hardware, "hardware smoke does not parse formatted JSON with grep")

    backend = read("core/root/usr/libexec/rpcd/xray_profiles")
    require("rand()" not in backend and "make_temp_dir" in backend and "if (mkdir(path, 0700))" in backend,
            "backend uses portable atomic exclusive temporaries")
    require('readfile("/proc/self/stat")' in backend and "pid: 0" not in backend,
            "backend lock records a live owner PID")
    require('access(XRAY_BIN, "x")' in backend, "backend binary_found requires executable access")
    require("requires_geoip" in backend and "requires_geosite" in backend,
            "backend reports per-profile geodata requirements")
    require('"${SS_BIN}" -tinpH' in backend and "get_process_uptime" in backend,
            "backend reads per-process TCP_INFO and uptime without an Xray listener")
    require("SOCKSTATS_BIN" in backend and 'source = "pidfd_tcp_info"' in backend and
            "tcp_info_fields_unavailable" in backend,
            "backend prefers direct socket TCP_INFO and degrades without fabricated zeroes")
    require("protocol_stack: get_profile_stack(filepath)" in backend and
            "stream.network || stream.method" in backend and
            'push(parts, "gRPC")' in backend and 'push(parts, "XHTTP")' in backend,
            "backend derives safe protocol-stack labels from stored profile JSON")
    require("THERMAL_TEMP_PATH" in backend and "VCGENCMD_BIN" in backend and "PROC_STAT_PATH" in backend and
            "undervoltage_now" in backend and "undervoltage_occurred" in backend,
            "backend exposes read-only Raspberry Pi CPU, temperature, and undervoltage health")
    require("get_profile_connection_state" in backend and "WATCHDOG_STATE_DIR" in backend and
            'access(`${prefix}.down_since`, "r")' in backend,
            "backend distinguishes aggregate traffic from endpoint-specific watchdog health")
    require("VERSION_CACHE_PATH" in backend and "get_binary_version" in backend and
            "cached.signature == signature" in backend and "rename(cache_tmp, VERSION_CACHE_PATH)" in backend,
            "backend atomically caches the expensive Xray version probe by binary identity")
    require("rpc_logs" in backend and "LOG_MAX_LINES = 500" in backend and
            'run_process("logread -l 1000 2>/dev/null", 524288)' in backend and
            'storage: "ram"' in backend,
            "backend exposes a bounded read-only snapshot of the volatile logd ring")
    sockstats = read("core/src/xray-sockstats.c")
    require("SYS_pidfd_open" in sockstats and "SYS_pidfd_getfd" in sockstats and
            "getsockopt(duplicate_fd, IPPROTO_TCP, TCP_INFO" in sockstats,
            "native collector reads TCP_INFO from existing process sockets")
    require("info.tcpi_bytes_acked" in sockstats and
            "info.tcpi_bytes_sent" not in sockstats and
            "info.tcpi_bytes_retrans" in sockstats and
            'parse_ss_counter(line, "bytes_acked:")' in backend and
            'parse_ss_counter(line, "bytes_retrans:")' in backend and
            'parse_ss_counter(line, "bytes_sent:")' not in backend and
            "retransBps" in read("core/root/www/luci-static/resources/view/xray/profiles.js"),
            "traffic rates exclude retransmits and expose retransmission diagnostics")
    require(not any(call in sockstats for call in ("bind(", "listen(", "connect(", "send(", "recv(")),
            "native collector cannot open listeners or generate probe traffic")
    require("sha256:" not in backend and "size: size" not in backend,
            "backend polling omits retired profile size and SHA metadata")
    require("assets_found" not in backend, "backend exposes no misleading global assets status")
    require("finally" not in backend and "throw " not in backend and "is_array(" not in backend,
            "backend cleanup uses target-compatible ucode syntax")
    require(".section(" not in backend and 'u.set("xray_core", id, "profile")' in backend,
            "backend creates named UCI sections through the portable cursor API")
    require('u.get("xray_core", id);' not in backend and 'u.get_all("xray_core", id)' in backend,
            "backend reads complete UCI profile sections")
    require('stdin_handle.read(MAX_RPC_INPUT_BYTES + 1)' in backend and "MAX_RPC_INPUT_BYTES = 1048576" in backend,
            "backend reads large stdin payloads through a bounded stream")

    generator_entry = read("core/root/usr/share/xray/gen_config.uc")
    generator_config = read("core/root/usr/share/xray/common/config.mjs")
    require('gen_config(getenv("UCI_CONFIG_DIR"))' in generator_entry and
            "config_dir ? cursor(config_dir) : cursor()" in generator_config,
            "generator preserves production UCI defaults and supports isolated test roots")

    profiles_view = read("core/root/www/luci-static/resources/view/xray/profiles.js")
    require("handleSave: null" in profiles_view and "handleSaveApply: null" in profiles_view and "handleReset: null" in profiles_view,
            "profile page disables generic LuCI controls")
    require("refreshInFlight" in profiles_view, "profile polling prevents overlapping requests")
    require("E('th', { 'class': 'th' }, _('Имя файла JSON'))" not in profiles_view and
            "E('th', { 'class': 'th' }, _('Размер'))" not in profiles_view and
            "E('th', { 'class': 'th' }, _('SHA-256'))" not in profiles_view,
            "profile table retires filename, size, and SHA columns")
    require("traffic.rx_bytes" in profiles_view and "traffic.tx_bytes" in profiles_view and
            "display.rxBps" in profiles_view and "display.txBps" in profiles_view and
            "traffic.rtt_ms" in profiles_view and "traffic.uptime_seconds" in profiles_view,
            "profile table renders live RX, TX, RTT, and uptime metrics")
    require("xray-action-btn" in profiles_view and "xray-traffic-separator" in profiles_view and
            "p.protocol_stack" in profiles_view,
            "profile table uses compact actions, inline counters, and protocol-stack labels")
    require("renderHardwareHealth" in profiles_view and "xray-power-warning" in profiles_view and
            "temperature_millidegrees" in profiles_view and "cpu_total_ticks" in profiles_view,
            "summary card renders CPU load, temperature, and an accessible undervoltage warning")
    require("connectionState === 'connected'" in profiles_view and "label warning" in profiles_view and "◐" in profiles_view,
            "profile status visibly distinguishes reconnecting processes from connected tunnels")

    logs_view = read("core/root/www/luci-static/resources/view/xray/logs.js")
    require("handleSave: null" in logs_view and "callLogs" in logs_view and
            "maximum_limit || 500" in logs_view and "this.paused && !force" in logs_view,
            "log page is read-only, bounded, and supports pausing live polling")
    menu = read("core/root/usr/share/luci/menu.d/luci-app-xray.json")
    require('"admin/services/xray_profiles/logs"' in menu and '"xray/logs"' in menu and
            '"type": "firstchild"' in menu and '"preferred": "profiles"' in menu and
            '"logs"' in read("core/root/usr/share/rpcd/acl.d/luci-app-xray.json"),
            "LuCI menu and ACL expose the read-only log tab inside Xray Reverse")

    update_view = read("core/root/www/luci-static/resources/view/xray/update.js")
    update_helper = read("core/root/usr/libexec/xray-update")
    update_acl = read("core/root/usr/share/rpcd/acl.d/luci-app-xray.json")
    require('"admin/services/xray_profiles/update"' in menu and '"xray/update"' in menu and
            '"/usr/libexec/xray-update status"' in update_acl and
            '"/usr/libexec/xray-update github-start"' in update_acl,
            "LuCI menu and ACL expose the signed updater with exact commands")
    require("openssl dgst -sha256 -verify" in update_helper and
            "TARGET_ARCH=aarch64_cortex-a53" in update_helper and
            "CHECK_TTL=900" in update_helper and
            "validate_remote_release" in update_helper and
            "asset-installer" in update_helper and "asset-success-marker" in update_helper,
            "updater revalidates a fresh signed architecture-specific release and its installer contract")
    require("STATE=/var/run/xray-update" in update_helper and
            "CANDIDATE=/tmp/.xray-update-bundle.tar.gz" in update_helper and
            "/etc/" not in update_helper and "api.github.com" not in update_helper,
            "updater keeps mutable state in RAM and avoids API rate limits or persistent edits")
    require("run('check')" in update_view and "run('github-start')" in update_view and
            "poll.add(refresh, 3)" in update_view and "innerHTML" not in update_view,
            "update view checks, installs, and polls without unsafe HTML injection")

    deploy_script_path = ROOT / "scripts/deploy_r12_to_raspberry.ps1"
    deploy_script_bytes = deploy_script_path.read_bytes()
    require(all(byte < 0x80 for byte in deploy_script_bytes),
            "Windows deployment script is ASCII-safe for Windows PowerShell 5.1")
    deploy_script = deploy_script_bytes.decode("ascii")
    require("[string]$ArtifactDir = $PSScriptRoot" not in deploy_script and
            "$ArtifactDir = Split-Path -Parent $MyInvocation.MyCommand.Path" in deploy_script,
            "Windows deployment script resolves its default artifact directory at runtime")
    require("install -d" not in deploy_script and
            "mkdir -p '$remoteDir'" in deploy_script and
            "chmod 0700 '$remoteDir'" in deploy_script,
            "Windows deployment script stages files with clean OpenWrt BusyBox commands")

    watchdog = read("core/root/usr/libexec/xray-profile-watchdog")
    require("DISCONNECT_GRACE_SECONDS" in watchdog and "CONNECTED_REARM_SECONDS" in watchdog and
            "peer_is_reachable" in watchdog and 'write_state_value "$id" armed 0' in watchdog,
            "watchdog requires a confirmed outage and reachable peer, then disarms before recovery")
    require("get_profile_endpoint" in watchdog and "get_tunnel_socket_snapshot" in watchdog and
            "@.outbounds[@.settings.reverse].settings.address" in watchdog and
            "streamSettings.sockopt.tcpUserTimeout" in watchdog and
            "USER_TIMEOUT_MARGIN_SECONDS" in watchdog and
            'peer_port($5) != target_port' in watchdog and
            'if [ "$connections" -gt 0 ]; then' in watchdog and
            "retransmission timers are never treated as an" in watchdog,
            "watchdog evaluates endpoint-specific sockets without load-induced restarts")
    require('"$INIT_SCRIPT" restart "$id"' in watchdog and "clear_profile_state" in watchdog,
            "watchdog restarts only one isolated profile and clears intent after manual stop")
    profile_init = read("core/root/etc/init.d/xray_profiles")
    profile_runtime = read("core/root/usr/share/xray/profile_runtime.uc")
    require("xray-profile-watchdog" in read("core/Makefile") and
            "profile_watchdog" in profile_init and "restart()" in profile_init and
            'stop_service "$target_id"' in profile_init,
            "package installs and procd supervises the profile watchdog")
    require("tcpcongestion" in profile_runtime and '"bbr"' in profile_runtime and
            "profile_runtime.uc" in read("core/Makefile") and
            "prepare_runtime_profile" in profile_init and
            "tcp_congestion_control" not in profile_init,
            "reverse profiles select BBR in a RAM-only overlay without changing the system default")

    reverse_runtime = "\n".join((
        profile_init,
        read("core/root/usr/libexec/rpcd/xray_profiles"),
        watchdog,
        update_helper,
    ))
    for forbidden_network_owner in (
        "/etc/init.d/firewall", "fw4 ", "nft ", "ip rule", "ip route",
        "/etc/init.d/dnsmasq",
    ):
        require(forbidden_network_owner not in reverse_runtime,
                f"reverse profile and update runtime never owns {forbidden_network_owner.strip()}")
    default_config = read("core/root/etc/config/xray_core")
    require("option reverse_only '1'" in default_config and
            "option transparent_proxy_enable '0'" in default_config,
            "package defaults keep legacy transparent firewall ownership disabled")

    active_release_files = (
        ".github/workflows/build-release.yml",
        "core/Makefile",
        "status/Makefile",
        "geodata/Makefile",
        "install_and_smoke_r12.sh",
        "ROLLBACK-R12.txt",
        "scripts/build_r12_offline_bundle.sh",
        "scripts/deploy_r12_to_raspberry.ps1",
        "scripts/r12_apk_manifest.py",
        "tests/run_tests.sh",
        "tests/test_installer_r12.sh",
        "tests/test_r12_manifest.py",
    )
    stale_patterns = ("R11", "r11", "PKG_RELEASE:=11", "3.7.1-r11", "3.7.1-11", "package_release=11")
    for active_file in active_release_files:
        require(not any(pattern in read(active_file) for pattern in stale_patterns),
                f"{active_file} contains no stale R11 release identity")

    print("All R12 contracts passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
