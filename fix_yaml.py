import sys

with open('.github/workflows/build-release.yml', 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_lines = []
in_heredoc = False
for line in lines:
    if "cat << 'EOF' > \"$APK_ROOT/etc/apk/repositories\"" in line:
        new_lines.append(line)
        in_heredoc = True
    elif in_heredoc:
        if line.strip() == "EOF":
            new_lines.append("            EOF\n")
            in_heredoc = False
        else:
            if not line.startswith("            "):
                new_lines.append("            " + line.lstrip())
            else:
                new_lines.append(line)
    else:
        new_lines.append(line)

with open('.github/workflows/build-release.yml', 'w', encoding='utf-8') as f:
    f.writelines(new_lines)
