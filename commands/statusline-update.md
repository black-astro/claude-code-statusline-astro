---
description: 상태라인을 최신 버전으로 업데이트한다
allowed-tools: Bash, Read, Write, Edit
---

설치된 상태라인을 최신 버전으로 올린다. 직접 실행할 것 — 안내문만 출력하지 말 것.

1. 현재 버전을 확인한다.
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline.ps1 -Version`
   - macOS / Linux: `sh ~/.claude/statusline.sh --version`

2. 플러그인으로 설치된 경우라면 `${CLAUDE_PLUGIN_ROOT}/scripts/` 의 스크립트를
   `~/.claude/` 로 복사한다. 그렇지 않으면 저장소에서 내려받는다.

   ```
   https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/scripts/statusline.ps1
   https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/scripts/statusline.sh
   https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/scripts/mascot-hook.ps1
   https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/scripts/mascot-hook.sh
   ```

3. `settings.json` 은 건드리지 않는다. 스크립트 파일만 교체한다.
   `~/.claude/statusline-cache/.gacha-key` 도 절대 지우지 않는다 — 지우면 마스코트가
   새로 정해진다.

4. 새 버전을 다시 확인해 출력하고, 바뀐 버전 번호를 사용자에게 보고한다.
