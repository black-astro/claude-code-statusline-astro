#!/bin/sh
# claude-code-statusline installer for macOS / Linux / WSL / Git Bash.
#
#   ./install.sh                 # from a cloned repo
#   curl -fsSL https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.sh | sh
#
# Copies statusline.sh into ~/.claude/ and merges a statusLine entry into
# ~/.claude/settings.json. Existing settings are preserved and backed up.

set -e

REPO_RAW='https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main'
CLAUDE_DIR="${HOME}/.claude"
TARGET="${CLAUDE_DIR}/statusline.sh"
SETTINGS="${CLAUDE_DIR}/settings.json"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir='.'
SOURCE="${script_dir}/scripts/statusline.sh"

mkdir -p "$CLAUDE_DIR"

if [ -f "$SOURCE" ]; then
    cp "$SOURCE" "$TARGET"
    echo "installed  $TARGET (from $SOURCE)"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_RAW}/scripts/statusline.sh" -o "$TARGET"
    echo "installed  $TARGET (downloaded)"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TARGET" "${REPO_RAW}/scripts/statusline.sh"
    echo "installed  $TARGET (downloaded)"
else
    echo "error: scripts/statusline.sh not found and neither curl nor wget is available" >&2
    exit 1
fi

chmod +x "$TARGET"

CMD="sh \"${TARGET}\""

if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak"
    echo "backup     ${SETTINGS}.bak"
fi

if command -v jq >/dev/null 2>&1; then
    [ -f "$SETTINGS" ] || printf '{}' >"$SETTINGS"
    tmp="${SETTINGS}.tmp.$$"
    jq --arg cmd "$CMD" \
        '.statusLine = {"type":"command","command":$cmd,"refreshInterval":5}' \
        "$SETTINGS" >"$tmp"
    mv "$tmp" "$SETTINGS"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$CMD" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path, encoding='utf-8') as fh:
        text = fh.read().strip()
    if text:
        data = json.loads(text)
data['statusLine'] = {'type': 'command', 'command': cmd, 'refreshInterval': 5}
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write('\n')
PY
elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const [path, cmd] = process.argv.slice(1);
let data = {};
if (fs.existsSync(path)) {
  const text = fs.readFileSync(path, "utf8").trim();
  if (text) data = JSON.parse(text);
}
data.statusLine = { type: "command", command: cmd, refreshInterval: 5 };
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
' "$SETTINGS" "$CMD"
else
    echo ''
    echo "warning: no jq, python3 or node found — settings.json was not modified." >&2
    echo "Add this to ${SETTINGS} yourself:" >&2
    echo '' >&2
    echo '  "statusLine": {' >&2
    echo '    "type": "command",' >&2
    echo "    \"command\": \"${CMD}\"," >&2
    echo '    "refreshInterval": 5' >&2
    echo '  }' >&2
    exit 1
fi

echo "configured ${SETTINGS}"
echo ''
echo 'Done. Restart Claude Code (or open a new session) to see the status line.'
