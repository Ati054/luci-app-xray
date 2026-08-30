import sys

with open('tests/test_r8_invariants.sh', 'r', encoding='utf-8') as f:
    content = f.read()

# Fix 1: grep for APKINDEX.tar.gz instead of .tar.gz
content = content.replace(
    'grep -q "\\.tar\\.gz"',
    'grep -q "APKINDEX.tar.gz"'
)

# Fix 2: grep for --simulate instead of -simulate (prevent option parsing)
content = content.replace(
    'grep -q "--simulate"',
    'grep -q -- "--simulate"'
)

# Fix 3: grep window for FETCH_RC and UPDATE_RC
content = content.replace(
    'grep -A 5 "fetch"',
    'grep -A 10 "fetch"'
)
content = content.replace(
    'grep -A 5 "update"',
    'grep -A 10 "update"'
)

# Fix 4: the faulty pipe grep -q "|| true" | grep -v "restore_backup"
content = content.replace(
    'grep -q "|| true" "$INSTALLER" | grep -v "restore_backup"',
    'grep "|| true" "$INSTALLER" | grep -q -v "restore_backup"'
)

with open('tests/test_r8_invariants.sh', 'w', encoding='utf-8') as f:
    f.write(content)
