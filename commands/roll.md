---
description: 오늘의 마스코트를 뽑는다 (하루 한 번)
allowed-tools: Bash
---

상태라인 마스코트를 뽑는다. 하루 한 번만 뽑을 수 있고, 뽑기 전까지는 지금 마스코트가
그대로 유지된다.

플랫폼에 맞는 쪽을 실행하고 출력을 그대로 보여줄 것.

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline.ps1 -Roll`
- macOS / Linux / WSL: `sh ~/.claude/statusline.sh --roll`

"오늘 뽑기는 이미 사용했습니다" 면 그대로 전달하고 내일 다시 뽑을 수 있다고 안내한다.
스크립트가 없으면 `/statusline-install` 을 먼저 실행하라고 알린다.
