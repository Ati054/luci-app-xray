import sys

with open('install_and_smoke_r8.sh', 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace(
    "/etc/init.d/xray_core stop 2>/dev/null || true",
    "if /etc/init.d/xray_core status >/dev/null 2>&1; then /etc/init.d/xray_core stop 2>/dev/null || :; fi"
)
content = content.replace(
    "/etc/init.d/xray_profiles stop 2>/dev/null || true",
    "if /etc/init.d/xray_profiles status >/dev/null 2>&1; then /etc/init.d/xray_profiles stop 2>/dev/null || :; fi"
)
content = content.replace(
    "/etc/init.d/xray_core disable 2>/dev/null || true",
    "/etc/init.d/xray_core disable 2>/dev/null || :"
)
content = content.replace(
    "/etc/init.d/xray_profiles disable 2>/dev/null || true",
    "/etc/init.d/xray_profiles disable 2>/dev/null || :"
)
content = content.replace(
    "CORE_INST=$(apk info -e luci-app-xray | head -n1 || true)",
    "CORE_INST=$(apk info -e luci-app-xray | head -n1 || :)"
)
content = content.replace(
    "INST_VER=$(apk info -d \"$CORE_INST\" | grep -v 'luci-app-xray description:' | head -n1 || true)",
    "INST_VER=$(apk info -d \"$CORE_INST\" | grep -v 'luci-app-xray description:' | head -n1 || :)"
)
content = content.replace(
    "UCODE_BIN=$(which ucode || true)",
    "UCODE_BIN=$(which ucode || :)"
)
content = content.replace("|| true", "|| :")

with open('install_and_smoke_r8.sh', 'w', encoding='utf-8') as f:
    f.write(content)
