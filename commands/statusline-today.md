---
description: 지금 쓰고 있는 마스코트를 보여준다
allowed-tools: Bash
---

지금 쓰고 있는 상태라인 마스코트와 오늘 뽑기가 남았는지 확인한다.

플랫폼에 맞는 쪽을 실행하고, 출력을 그대로 사용자에게 보여줄 것.

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline.ps1 -Today`
- macOS / Linux / WSL: `sh ~/.claude/statusline.sh --today`

"아직 뽑은 마스코트가 없습니다" 가 나오면 `/statusline-roll` 로 뽑으라고 안내한다.
스크립트가 없으면 `/statusline-install` 을 먼저 실행하라고 알린다.
