---
title: R5 Acceptance Specifications & Invariants
activation: always_on
---

# R5 Acceptance & Adversarial Test Specifications

This document defines the 26 adversarial test areas required for the `luci-app-xray` R5 release. It is designed to prevent false positives by strictly defining negative controls for every test.

## 1. Xray nonzero exit status rejection
- **Risk**: Process fails, but system assumes success based on invocation.
- **False Positive Prevention**: The test might pass (fail to start) due to an invalid JSON profile instead of the binary's exit code.
- **Negative Control**: Use a perfectly valid JSON profile but mock the `xray_bin` to `exit 1`. The rejection MUST specifically cite the nonzero exit status from procd/ubus.

## 2. Valid zero-exit Xray acceptance
- **Risk**: Process validation fails or hangs.
- **False Positive Prevention**: The test might pass because of a hardcoded fallback or failure to actually execute.
- **Negative Control**: Mock `xray_bin` to immediately `exit 0`. The system must recognize this as a clean, successful validation run.

## 3. Missing Xray binary rejection
- **Risk**: Fails to gracefully handle uninstalled Xray core.
- **False Positive Prevention**: Might fail due to invalid paths rather than binary detection.
- **Negative Control**: Provide a valid profile but set `xray_bin=/tmp/does_not_exist`. System must output a clean "executable not found" or equivalent handled error, not a stack trace.

## 4. Target-version `lstat` symlink rejection using valid JSON
- **Risk**: Using `stat` instead of `lstat` follows symlinks, allowing arbitrary file read/write (privilege escalation).
- **False Positive Prevention**: Test passes (rejects file) because the target JSON is invalid or missing a field, rather than due to the symlink check.
- **Negative Control**: Create a symlink that points to a **100% perfectly valid** profile JSON. The system MUST reject it explicitly because `lstat().isSymbolicLink()` is true.

## 5. Target symlink contents unchanged
- **Risk**: Writing to a symlink overwrites the target before rejecting it.
- **False Positive Prevention**: File remains unchanged because the write failed for unrelated permissions.
- **Negative Control**: Record the target file's `mtime` and `sha256sum`. Attempt to overwrite it via the symlink. Verify the target's `mtime` and hash remain strictly identical.

## 6. Secret temp file is `0600` before first content write
- **Risk**: Creating a temp file with `0644` and later `chmod`ing it leaves a race condition where secrets are readable.
- **False Positive Prevention**: Inspecting permissions only *after* the operation completes.
- **Negative Control**: Ensure file creation uses `open(path, O_CREAT, 0600)`. Use a test hook to inspect the file mode immediately after creation, *before* `write()` is called.

## 7. Orphan regular file rejection
- **Risk**: Extraneous files in the profile directory crash the parser or executor.
- **False Positive Prevention**: Test passes because the file lacks `.json`.
- **Negative Control**: Place an invalid text file named `orphan.txt` in the profiles directory. The parser must ignore it and successfully process adjacent valid `.json` files.

## 8. Concurrent mutation exclusion
- **Risk**: Race conditions corrupt profile data.
- **False Positive Prevention**: A lock failure occurs due to missing `.lock.d` permissions.
- **Negative Control**: Launch two overlapping RPC writes to the same profile simultaneously. Exactly one must succeed, and the other must cleanly fail with a lock acquisition error.

## 9. Stale lock recovery
- **Risk**: A crashed process leaves a lock forever, bricking the UI.
- **False Positive Prevention**: Lock was already deleted by a background cleanup job.
- **Negative Control**: Manually create `.lock.d/profile.lock` belonging to a dead PID or with an old timestamp. A new write request MUST succeed and transparently reap the stale lock.

## 10. Start A leaves B PID unchanged
- **Risk**: Starting a new instance restarts all instances.
- **False Positive Prevention**: Instance B was already stopped.
- **Negative Control**: Start B and record its PID. Start A. Re-check B's PID and verify it is identical.

## 11. Stop A leaves B PID unchanged
- **Risk**: Stopping an instance stops or restarts others.
- **Negative Control**: Start A and B. Record B's PID. Stop A. Verify B's PID is identical.

## 12. Restart A leaves B PID unchanged
- **Risk**: Restarting an instance bounces the entire service.
- **Negative Control**: Start A and B. Record B's PID. Restart A. Verify B's PID is identical.

## 13. Stop confirms target absence
- **Risk**: Stop command is sent, but process lingers (zombie or delayed exit).
- **False Positive Prevention**: Stop returns true instantly without checking state.
- **Negative Control**: Issue stop. The system must poll `ubus call service list` and verify `instances.profile_A.running == false` before returning success.

## 14. Delayed exit becomes failed
- **Risk**: An instance crashes after 2 seconds, but system initially reported it as running.
- **False Positive Prevention**: Process fails instantly due to missing binary.
- **Negative Control**: Mock a binary that sleeps for 2 seconds then `exit 1`. The manager must wait for procd to detect the crash and report it as `failed`, not `running`.

## 15. Autostart starts only selected valid profiles
- **Risk**: Autostart ignores `enabled` flags or crashes on the first invalid profile.
- **Negative Control**: Provide one enabled valid profile, one disabled valid profile, and one enabled invalid profile. Only the first MUST start.

## 16. Reload preserves unchanged and manually started PIDs
- **Risk**: `reload_service` is just an alias for `restart`.
- **False Positive Prevention**: Instances restart so quickly they appear preserved, but PIDs changed.
- **Negative Control**: Record PIDs. Trigger a reload. Verify the unchanged profile's PID matches exactly.

## 17. Invalid profile does not block a valid profile
- **Risk**: A single malformed JSON file breaks the entire service enumeration.
- **Negative Control**: Place an invalid JSON file in the directory. A valid JSON file next to it must still load, enumerate in RPC, and start correctly.

## 18. No table-251 rule is created
- **Risk**: Transparent proxy rules leak into reverse-only mode.
- **Negative Control**: Verify `ip rule list` and `nft list ruleset` contain absolutely no references to Xray transparent proxy rules (table 251 / fwmark).

## 19. No Xray nftables artifact is created
- **Risk**: Extraneous firewall templates are rendered.
- **Negative Control**: Assert that `/var/etc/xray/nftables.conf` (or equivalent) is NOT created during reverse-only mode.

## 20. No dnsmasq Xray file is created
- **Risk**: DNS interception configs leak into reverse-only mode.
- **Negative Control**: Assert that `/var/etc/dnsmasq.d/xray.conf` is NOT created.

## 21. Actual package root resolves every import
- **Risk**: Tests pass by resolving modules from the developer's git tree (`core/root/...`).
- **False Positive Prevention**: Missing module errors are masked by local workspace layout.
- **Negative Control**: Copy the built artifacts to an isolated directory (e.g., `/tmp/isolated_root`) with no git workspace access, and execute imports there.

## 22. Final APK/IPK file list contains every runtime module
- **Risk**: Missing files in the final package.
- **Negative Control**: Use `tar tf` or `opkg files` to assert that `rpcd/xray_profiles`, `init.d`, and LuCI views are explicitly present in the compiled archive.

## 23. Extracted smoke artifact resolves every fixture
- **Risk**: CI smoke test script looks for `../../fixtures`, breaking when downloaded as a loose zip.
- **Negative Control**: Extract the CI artifact into a fresh `/tmp` folder and run it. It must resolve all fixtures internally without relying on the repo.

## 24. RPC and logs contain none of the fixture secrets
- **Risk**: Private keys or UUIDs are dumped into system logs or RPC responses.
- **Negative Control**: Run a full lifecycle test with a known test UUID/Key. Grep `logread` and the raw RPC output; the secrets MUST NOT match.

## 25. LuCI exposes all required actions and truthful states
- **Risk**: The UI shows "Running" when the instance has failed.
- **Negative Control**: Corrupt a running instance so it fails. The `ubus` state will reflect failure; LuCI MUST render this failure and not cache the "Running" state.

## 26. ACL permits only required methods and no arbitrary exec
- **Risk**: RPCD ACL is too broad, allowing `*`.
- **Negative Control**: Attempt to call an unlisted method like `exec` via `ubus call xray_profiles exec '{"cmd":"rm -rf /"}'`. It MUST be rejected with `Permission denied`.
