import sys

with open('.github/workflows/build-release.yml', 'r', encoding='utf-8') as f:
    content = f.read()

target = """          if [ "${{ matrix.id }}" = "25.12.5" ]; then
            # Download aarch64_cortex-a53 dependencies for offline deployment using apk solver
            APK_HOST="$SDK_HOME/staging_dir/host/bin/apk"
            mkdir -p /tmp/offline_apks
            
            # Create a basic apk configuration
            mkdir -p /tmp/offline_apks/etc/apk
            echo "aarch64_cortex-a53" > /tmp/offline_apks/etc/apk/arch
            
            "$APK_HOST" update \\
              --root /tmp/offline_apks \\
              --allow-untrusted \\
              --arch aarch64_cortex-a53 \\
              -X "https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony" > "${{ github.workspace }}/apk_log.txt" 2>&1 || true

            "$APK_HOST" fetch -R \\
              --root /tmp/offline_apks \\
              --allow-untrusted \\
              --arch aarch64_cortex-a53 \\
              -X "https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing" \\
              -X "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony" \\
              coreutils coreutils-base64 ip-full >> "${{ github.workspace }}/apk_log.txt" 2>&1 || true
              
            # Verify no empty files
            shopt -s nullglob
            for f in /tmp/offline_apks/*.apk; do
              if [ ! -s "$f" ]; then
                echo "::error::Downloaded APK $f is zero-byte"
                echo "Failed but continuing for log exfiltration"
              fi
              # Verify package architecture using apk tools
              PKG_ARCH="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^A:' | cut -d: -f2)"
              if [ "$PKG_ARCH" != "aarch64_cortex-a53" ] && [ "$PKG_ARCH" != "aarch64" ] && [ "$PKG_ARCH" != "all" ]; then
                echo "::error::Invalid architecture $PKG_ARCH in $f"
                echo "Failed but continuing for log exfiltration"
              fi
              # Verify it's a valid apk format (tar.gz usually, apk-tools handles it)
              if ! "$APK_HOST" manifest "$f" >/dev/null; then
                echo "::error::Invalid APK file: $f"
                echo "Failed but continuing for log exfiltration"
              fi
            done
            
            cp /tmp/offline_apks/*.apk "${{ github.workspace }}/" 2>/dev/null || true
            
            # Generate manifest
            rm -f "${{ github.workspace }}/OFFLINE-PACKAGES-MANIFEST.txt"
            for f in "${{ github.workspace }}"/*.apk; do
              case "$f" in
                *luci-app-xray*)
                  ;;
                *)
                  PKG_NAME="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^P:' | cut -d: -f2)"
                  PKG_VER="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^V:' | cut -d: -f2)"
                  PKG_ARCH="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^A:' | cut -d: -f2)"
                  PKG_DEPS="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^D:' | cut -d: -f2)"
                  PKG_SIZE="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
                  PKG_SHA="$(sha256sum "$f" | awk '{print $1}')"
                  BASENAME="$(basename "$f")"
                  echo "$BASENAME;$PKG_NAME;$PKG_VER;;$PKG_ARCH;$PKG_SIZE;$PKG_SHA;official;$PKG_DEPS" >> "${{ github.workspace }}/OFFLINE-PACKAGES-MANIFEST.txt"
                  ;;
              esac
            done
          fi"""

replacement = """          if [ "${{ matrix.id }}" = "25.12.5" ]; then
            APK_HOST="$SDK_HOME/staging_dir/host/bin/apk"
            [ -x "$APK_HOST" ] || { echo "::error::SDK host apk executable not found: $APK_HOST"; exit 1; }

            APK_ROOT=/tmp/openwrt-apk-root
            APK_OUTPUT=/tmp/offline-apks
            
            mkdir -p "$APK_ROOT/etc/apk" "$APK_ROOT/etc/apk/repositories.d" "$APK_ROOT/etc/apk/keys" "$APK_ROOT/lib/apk/db" "$APK_ROOT/var/cache/apk"
            mkdir -p "$APK_OUTPUT"
            touch "$APK_ROOT/etc/apk/world"
            echo "aarch64_cortex-a53" > "$APK_ROOT/etc/apk/arch"
            
            cat << 'EOF' > "$APK_ROOT/etc/apk/repositories"
https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/video/packages.adb
EOF

            set +e
            "$APK_HOST" update \\
              --root "$APK_ROOT" \\
              --allow-untrusted \\
              --arch aarch64_cortex-a53 > "${{ github.workspace }}/apk_log.txt" 2>&1
            UPDATE_RC=$?

            "$APK_HOST" fetch -R \\
              --root "$APK_ROOT" \\
              --allow-untrusted \\
              --arch aarch64_cortex-a53 \\
              --output "$APK_OUTPUT" \\
              coreutils coreutils-base64 ip-full >> "${{ github.workspace }}/apk_log.txt" 2>&1
            FETCH_RC=$?
            set -e

            if [ "$UPDATE_RC" -ne 0 ] || [ "$FETCH_RC" -ne 0 ]; then
                echo "::error::Offline dependency resolution failed"
                exit 1
            fi
            
            # Verify downloaded files
            shopt -s nullglob
            APKS=("$APK_OUTPUT"/*.apk)
            if [ "${#APKS[@]}" -eq 0 ]; then
              echo "::error::No APKs downloaded"
              exit 1
            fi
            
            for f in "${APKS[@]}"; do
              if [ ! -s "$f" ]; then
                echo "::error::Downloaded APK $f is zero-byte"
                exit 1
              fi
              # Check valid APK and read manifest
              if ! "$APK_HOST" manifest "$f" >/dev/null 2>&1; then
                echo "::error::Invalid APK file or metadata cannot be read: $f"
                exit 1
              fi
              
              PKG_NAME="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^P:' | cut -d: -f2)"
              if [ -z "$PKG_NAME" ]; then
                echo "::error::Package name is unexpected/empty in $f"
                exit 1
              fi
              
              PKG_ARCH="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^A:' | cut -d: -f2)"
              if [ "$PKG_ARCH" != "aarch64_cortex-a53" ] && [ "$PKG_ARCH" != "aarch64" ] && [ "$PKG_ARCH" != "all" ]; then
                echo "::error::Invalid architecture $PKG_ARCH in $f"
                exit 1
              fi
            done
            
            cp "$APK_OUTPUT"/*.apk "${{ github.workspace }}/" 
            
            # Generate manifest
            rm -f "${{ github.workspace }}/OFFLINE-PACKAGES-MANIFEST.txt"
            for f in "${{ github.workspace }}"/*.apk; do
              case "$f" in
                *luci-app-xray*)
                  ;;
                *)
                  PKG_NAME="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^P:' | cut -d: -f2)"
                  PKG_VER="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^V:' | cut -d: -f2)"
                  PKG_REL="unknown"
                  if echo "$PKG_VER" | grep -q '-'; then
                    PKG_REL="$(echo "$PKG_VER" | awk -F'-' '{print $NF}')"
                    PKG_VER="$(echo "$PKG_VER" | sed -E 's/-[^-]+$//')"
                  fi
                  PKG_ARCH="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^A:' | cut -d: -f2)"
                  PKG_DEPS="$("$APK_HOST" manifest "$f" 2>/dev/null | grep '^D:' | cut -d: -f2)"
                  PKG_SIZE="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
                  PKG_SHA="$(sha256sum "$f" | awk '{print $1}')"
                  BASENAME="$(basename "$f")"
                  echo "$BASENAME;$PKG_NAME;$PKG_VER;$PKG_REL;$PKG_ARCH;$PKG_SIZE;$PKG_SHA;official;$PKG_DEPS" >> "${{ github.workspace }}/OFFLINE-PACKAGES-MANIFEST.txt"
                  ;;
              esac
            done
            
            # 8. OFFLINE TRANSACTION PROOF
            SIM_ROOT=/tmp/sim-root
            mkdir -p "$SIM_ROOT/etc/apk" "$SIM_ROOT/etc/apk/repositories.d" "$SIM_ROOT/etc/apk/keys" "$SIM_ROOT/lib/apk/db" "$SIM_ROOT/var/cache/apk"
            touch "$SIM_ROOT/etc/apk/world"
            echo "aarch64_cortex-a53" > "$SIM_ROOT/etc/apk/arch"
            
            set +e
            "$APK_HOST" add \\
              --root "$SIM_ROOT" \\
              --allow-untrusted \\
              --arch aarch64_cortex-a53 \\
              --no-network \\
              --simulate \\
              "${{ github.workspace }}"/*.apk > "${{ github.workspace }}/apk_sim_log.txt" 2>&1
            SIM_RC=$?
            set -e
            
            echo "=== OFFLINE SIMULATION LOG ==="
            cat "${{ github.workspace }}/apk_sim_log.txt"
            
            if [ "$SIM_RC" -ne 0 ]; then
                echo "::error::Offline simulation failed! Dependencies are missing."
                exit 1
            fi
            
          fi"""

if target in content:
    content = content.replace(target, replacement)
    with open('.github/workflows/build-release.yml', 'w', encoding='utf-8') as f:
        f.write(content)
    print('Replaced successfully')
else:
    print('Target not found')
