#!/bin/sh
# claude-code-statusline installer for macOS / Linux / WSL / Git Bash.
#
#   ./install.sh                 # from a cloned repo
#   ./install.sh --no-mascot     # status line only, skip the mascot hooks
#   curl -fsSL https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.sh | sh
#
# Copies statusline.sh (and mascot-hook.sh) into ~/.claude/, then merges a
# statusLine entry and the mascot hooks into ~/.claude/settings.json. Existing
# settings are preserved and backed up.

set -e

REPO_RAW='https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main'
CLAUDE_DIR="${HOME}/.claude"
TARGET="${CLAUDE_DIR}/statusline.sh"
HOOK_TARGET="${CLAUDE_DIR}/mascot-hook.sh"
SETTINGS="${CLAUDE_DIR}/settings.json"

NO_MASCOT=0
for arg in "$@"; do
    case "$arg" in
        --no-mascot) NO_MASCOT=1 ;;
    esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir='.'

mkdir -p "$CLAUDE_DIR"

# Installs one script from the cloned repo, falling back to a download.
install_script() {
    _name="$1"
    _dest="$2"
    _src="${script_dir}/scripts/${_name}"

    if [ -f "$_src" ]; then
        cp "$_src" "$_dest"
        echo "installed  $_dest (from $_src)"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "${REPO_RAW}/scripts/${_name}" -o "$_dest"
        echo "installed  $_dest (downloaded)"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_dest" "${REPO_RAW}/scripts/${_name}"
        echo "installed  $_dest (downloaded)"
    else
        echo "error: scripts/${_name} not found and neither curl nor wget is available" >&2
        exit 1
    fi

    chmod +x "$_dest"
}

install_script 'statusline.sh' "$TARGET"
[ "$NO_MASCOT" -eq 1 ] || install_script 'mascot-hook.sh' "$HOOK_TARGET"

CMD="sh \"${TARGET}\""
HOOK="sh \"${HOOK_TARGET}\""

if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak"
    echo "backup     ${SETTINGS}.bak"
fi

if command -v jq >/dev/null 2>&1; then
    [ -f "$SETTINGS" ] || printf '{}' >"$SETTINGS"
    tmp="${SETTINGS}.tmp.$$"
    # put_hook drops any earlier copy of our hook so re-running never stacks
    # duplicates, and leaves every hook belonging to anything else untouched.
    jq --arg cmd "$CMD" --arg hook "$HOOK" --argjson mascot "$((1 - NO_MASCOT))" '
        def put_hook($ev; $state):
            .hooks = (.hooks // {})
            | .hooks[$ev] = (
                ((.hooks[$ev] // [])
                 | map(select([(.hooks // [])[].command // ""]
                              | map(test("mascot-hook")) | any | not)))
                + [{"hooks": [{"type": "command", "command": ($hook + " " + $state)}]}]
              );
        .statusLine = {"type": "command", "command": $cmd, "refreshInterval": 5}
        | if $mascot == 1 then
              put_hook("UserPromptSubmit"; "working")
              | put_hook("Stop"; "done")
              | put_hook("StopFailure"; "error")
          else . end
    ' "$SETTINGS" >"$tmp"
    mv "$tmp" "$SETTINGS"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$CMD" "$HOOK" "$NO_MASCOT" <<'PY'
import json, os, sys

path, cmd, hook, no_mascot = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == '1'

data = {}
if os.path.exists(path):
    with open(path, encoding='utf-8') as fh:
        text = fh.read().strip()
    if text:
        data = json.loads(text)

data['statusLine'] = {'type': 'command', 'command': cmd, 'refreshInterval': 5}

def put_hook(hooks, event, state):
    """Replace our own entry, keep everyone else's."""
    kept = [
        group for group in hooks.get(event, [])
        if not any('mascot-hook' in (h.get('command') or '')
                   for h in group.get('hooks', []))
    ]
    kept.append({'hooks': [{'type': 'command', 'command': '%s %s' % (hook, state)}]})
    hooks[event] = kept

if not no_mascot:
    hooks = data.setdefault('hooks', {})
    put_hook(hooks, 'UserPromptSubmit', 'working')
    put_hook(hooks, 'Stop', 'done')
    put_hook(hooks, 'StopFailure', 'error')

with open(path, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write('\n')
PY
elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const [path, cmd, hook, noMascot] = process.argv.slice(1);
let data = {};
if (fs.existsSync(path)) {
  const text = fs.readFileSync(path, "utf8").trim();
  if (text) data = JSON.parse(text);
}
data.statusLine = { type: "command", command: cmd, refreshInterval: 5 };

// Replace our own entry, keep everyone else s.
function putHook(hooks, event, state) {
  const kept = (hooks[event] || []).filter(
    (g) => !(g.hooks || []).some((h) => (h.command || "").includes("mascot-hook"))
  );
  kept.push({ hooks: [{ type: "command", command: hook + " " + state }] });
  hooks[event] = kept;
}

if (noMascot !== "1") {
  data.hooks = data.hooks || {};
  putHook(data.hooks, "UserPromptSubmit", "working");
  putHook(data.hooks, "Stop", "done");
  putHook(data.hooks, "StopFailure", "error");
}
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
' "$SETTINGS" "$CMD" "$HOOK" "$NO_MASCOT"
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
