---
description: Install the cross-platform status line into your Claude Code user settings
allowed-tools: Read, Write, Edit, Bash
---

Install the `claude-code-statusline` status line for the current user.

Do this yourself with tools — do not just print instructions.

1. Determine the platform.
   - Windows: use `${CLAUDE_PLUGIN_ROOT}/scripts/statusline.ps1`
   - macOS / Linux / WSL: use `${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh`

2. Copy that script to the user's `~/.claude/` directory, keeping the same
   filename. Create `~/.claude/` first if it does not exist. On Unix, `chmod +x`
   the copied file.

3. Read `~/.claude/settings.json` if it exists. Preserve every existing key —
   only add or replace the `statusLine` key. If the file does not exist, create
   it with `{}` as the starting point. Back up the original to
   `~/.claude/settings.json.bak` before writing.

   The value to set, with `<HOME>` replaced by the real home directory and all
   Windows path separators written as `/`:

   Windows:
   ```json
   "statusLine": {
     "type": "command",
     "command": "powershell -NoProfile -ExecutionPolicy Bypass -File <HOME>/.claude/statusline.ps1",
     "refreshInterval": 5
   }
   ```

   macOS / Linux:
   ```json
   "statusLine": {
     "type": "command",
     "command": "sh \"<HOME>/.claude/statusline.sh\"",
     "refreshInterval": 5
   }
   ```

   Write the file as UTF-8 **without** a BOM — a BOM makes the settings file
   unparseable.

4. Verify by piping a mock payload into the installed script and confirming it
   prints exactly one line:

   ```json
   {"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":63}}}
   ```

5. Report the installed path, the `statusLine` block that was written, and the
   test output. Tell the user to restart Claude Code or open a new session.
