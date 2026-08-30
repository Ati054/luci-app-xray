# R9 defect-to-test matrix

This matrix is the acceptance contract for the R9 recovery. A row is complete
only when the strongest locally available proof passes; target-only proofs stay
explicitly identified as such.

| ID | Reproduced defect / release risk | Required proof |
| --- | --- | --- |
| A | Installed init/rpcd/ucode/template files lost executable modes | Verify source Git modes, package install directives, extracted IPK/APK payload modes, and post-install mode checks. |
| B | OpenWrt 25.12.5 ucode rejected installed module syntax | Parse every installed `.uc`/`.mjs` with the SDK target ucode and execute `gen_config.uc` with no stderr. |
| C | Empty legacy reverse set emitted an ineffective routing rule | Generate the empty/default config and accept it with Xray 26.7.28 `run -test -config`. |
| D | Explicit `{}` caused the rpcd backend to read stdin and block | Bound explicit-argument calls with a target-available timeout; separately prove stdin JSON works only when the CLI argument is absent. |
| E | `rand()` is unavailable and temporary names could collide | Prohibit `rand()`, use exclusive 0600 creation, run concurrent validations/imports, and prove cleanup on success and failure. |
| F | Placeholder REALITY public keys were rejected by Xray 26.7.28 | Validate RAW + REALITY + Vision and XHTTP + REALITY TEST-NET fixtures with the exact Xray release; reject the invalid inbound fixture. |
| G | Offline artifact omitted transitive userland dependencies | Resolve `coreutils`, `coreutils-base64`, and `ip-full` recursively from the exact OpenWrt 25.12.5 `packages.adb` repositories, verify closure and manifest metadata, and install all APKs in a network-disabled isolated root. |
| H | LuCI contradicted backend binary/assets status | Exercise the view state renderer against backend-shaped results, including exact binary path/version and non-overlapping refreshes. |
| I | Global geodata warning blocked profiles that did not use geodata | Prove the profile page has no global geodata card and reports only per-profile `geoip:`/`geosite:` requirements. |
| J | Generic LuCI Apply/Save/Reset controls appeared on the RPC page | Prove the JSON Profiles view explicitly disables all three generic handlers. |
| K | Resolver, packaging, checksum, installer, or acceptance paths could continue after failure | Unit-test fail-closed behavior and reject `|| true` in critical paths except recorded cleanup. |
| L | Artifact could contain empty or unchecked inputs | Reject zero-byte files and prove `SHA256SUMS-R9.txt` covers every installer-consumed file before `sha256sum -c`. |
| M | Offline install was not a complete transaction proof | Install dependencies plus core/status into a fresh isolated APK root with networking disabled, capture output, and prove no remote repository was contacted. |
| N | Installer could mutate an unsupported/unsafe target or overclaim rollback | Test exact OS/arch/Xray/kernel prerequisites, backups/state capture, offline simulation/install, mode/runtime checks, conservative rollback language, and final stopped/disabled state. |
| O | Hardware smoke used fragile JSON parsing and incomplete state restoration | Use target-native structured parsing, distinct PID/isolation/restart proofs, IPv4/IPv6/nftables/dnsmasq before/after comparisons, scoped cleanup, and service/UCI restoration. |
| P | Release identity or artifact markers drifted | Verify all three package releases are 9, canonical package names, installer/smoke names, and exact final success markers. |
